"""Hardware-free tests for the guarded LS-5000 wedge-recovery CLI."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import SimpleNamespace

import pytest

from coolscanpy.cli import wedge_recovery


def _result(*, phase: int, status: bytes = bytes(8)):
    return SimpleNamespace(
        phase=phase,
        payload=b"",
        status=status,
        sense=status[1:4].hex(),
    )


@dataclass
class _FakeUsbUtil:
    released: list[tuple[object, int]] = field(default_factory=list)
    disposed: list[object] = field(default_factory=list)

    def release_interface(self, device: object, number: int) -> None:
        self.released.append((device, number))

    def dispose_resources(self, device: object) -> None:
        self.disposed.append(device)


def test_default_is_dry_run_and_never_opens_device(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(
        wedge_recovery,
        "_connect_device",
        lambda **_kwargs: pytest.fail("dry run opened the scanner"),
    )

    assert wedge_recovery.main([]) == 0
    captured = capsys.readouterr()
    assert captured.err == ""
    assert captured.out.startswith("DRY RUN: no commands sent\n")
    assert "SET PARAMETER CDB: e0008100000000000d00" in captured.out
    assert "SET PARAMETER CDB: e0008000000000000d00" in captured.out
    assert captured.out.count("EXECUTE CDB: c10000000000") == 2


def test_execute_no_confirmation_sends_nothing(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr("builtins.input", lambda _prompt: "no")
    monkeypatch.setattr(
        wedge_recovery,
        "_connect_device",
        lambda **_kwargs: pytest.fail("cancelled execution opened the scanner"),
    )

    assert (
        wedge_recovery.main(
            ["--execute", "--operation", "return-to-origin"]
        )
        == 1
    )
    captured = capsys.readouterr()
    assert "Cancelled; no commands sent.\n" in captured.out
    assert "Initialize (80h)" not in captured.out


@pytest.mark.parametrize(
    ("key", "set_cdb"),
    (
        ("return-to-origin", "e0008100000000000d00"),
        ("initialize", "e0008000000000000d00"),
    ),
)
def test_confirmed_execution_sends_one_set_and_execute_sequence(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    key: str,
    set_cdb: str,
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=3)
    usb_util = _FakeUsbUtil()
    calls: list[dict] = []
    monkeypatch.setattr("builtins.input", lambda _prompt: "yes")
    monkeypatch.setattr(
        wedge_recovery,
        "_connect_device",
        lambda: (device, interface, object(), object(), usb_util),
    )

    def perform(
        _ep_out: object,
        _ep_in: object,
        entry: dict,
        *,
        data_timeout_ms: int,
        deadline_monotonic: float | None = None,
    ):
        assert data_timeout_ms == 30_000
        assert deadline_monotonic is None
        calls.append(entry)
        return _result(phase=0x02 if len(calls) == 1 else 0x01)

    monkeypatch.setattr(wedge_recovery, "_perform_transaction", perform)

    assert wedge_recovery.main(["--execute", "--operation", key]) == 0
    captured = capsys.readouterr()
    assert captured.err == ""
    assert [call["cdb"] for call in calls] == [set_cdb, "c10000000000"]
    assert calls[0]["data_out"] == "00" * 13
    assert "data_out" not in calls[1]
    assert usb_util.released == [(device, 3)]
    assert usb_util.disposed == [device]


def test_refused_set_never_sends_execute_and_releases_usb(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=8)
    usb_util = _FakeUsbUtil()
    calls: list[dict] = []
    monkeypatch.setattr("builtins.input", lambda _prompt: "yes")
    monkeypatch.setattr(
        wedge_recovery,
        "_connect_device",
        lambda: (device, interface, object(), object(), usb_util),
    )
    refused = bytes.fromhex("0205240000000000")

    def perform(_out: object, _in: object, entry: dict, **_kwargs):
        calls.append(entry)
        return _result(phase=0x01, status=refused)

    monkeypatch.setattr(wedge_recovery, "_perform_transaction", perform)

    assert wedge_recovery.main(["--execute", "--operation", "initialize"]) == 2
    captured = capsys.readouterr()
    assert "refused with sense 052400" in captured.err
    assert len(calls) == 1
    assert usb_util.released == [(device, 8)]
    assert usb_util.disposed == [device]
