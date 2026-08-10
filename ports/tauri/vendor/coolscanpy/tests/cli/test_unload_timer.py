"""Hardware-free tests for the LS-5000 unload-timer probe."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import SimpleNamespace

import pytest

from coolscanpy.cli import unload_timer


def _result(payload: bytes, *, phase: int = 0x03, status: bytes = bytes(8)):
    return SimpleNamespace(
        phase=phase,
        payload=payload,
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


def test_read_uses_exact_b4_cdb_and_decodes_seconds_and_enable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=4)
    usb_util = _FakeUsbUtil()
    ep_out = object()
    ep_in = object()
    calls: list[tuple[object, object, dict, int]] = []

    monkeypatch.setattr(
        unload_timer,
        "_connect_device",
        lambda: (device, interface, ep_out, ep_in, usb_util),
    )

    def perform(
        out: object,
        incoming: object,
        entry: dict,
        *,
        data_timeout_ms: int,
        deadline_monotonic: float | None = None,
    ):
        assert deadline_monotonic is None
        calls.append((out, incoming, entry, data_timeout_ms))
        return _result(bytes.fromhex("000000025800000001"))

    monkeypatch.setattr(unload_timer, "_perform_transaction", perform)

    assert unload_timer.read_unload_timer() == unload_timer.UnloadTimer(
        seconds=600,
        enabled=True,
    )
    assert calls == [
        (
            ep_out,
            ep_in,
            {
                "seq": "unload-timer",
                "name": "GET_PARAMETER:B4",
                "cdb": "e100b400000000000900",
                "request_len": 9,
                "request_parts": [9],
            },
            5_000,
        )
    ]
    assert usb_util.released == [(device, 4)]
    assert usb_util.disposed == [device]


def test_timer_off_is_reported_without_sending_set(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=2)
    usb_util = _FakeUsbUtil()
    monkeypatch.setattr(
        unload_timer,
        "_connect_device",
        lambda: (device, interface, object(), object(), usb_util),
    )
    monkeypatch.setattr(
        unload_timer,
        "_perform_transaction",
        lambda *_args, **_kwargs: _result(
            bytes.fromhex("0000000e1000000000")
        ),
    )

    assert unload_timer.main([]) == 0
    captured = capsys.readouterr()
    assert captured.out == (
        "unload_timer_seconds: 3600\n"
        "unload_timer_enabled: false\n"
    )
    assert captured.err == ""


@pytest.mark.parametrize(
    "payload",
    (
        bytes.fromhex("000000000100000002"),
        bytes.fromhex("000000003b00000001"),
        bytes.fromhex("0000000000000000"),
    ),
)
def test_invalid_b4_values_fail_closed(payload: bytes) -> None:
    with pytest.raises(unload_timer.UnloadTimerError):
        unload_timer._decode_unload_timer(payload)


def test_check_condition_exits_nonzero_and_releases_usb(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=7)
    usb_util = _FakeUsbUtil()
    monkeypatch.setattr(
        unload_timer,
        "_connect_device",
        lambda: (device, interface, object(), object(), usb_util),
    )
    refused = bytes.fromhex("0205240000000000")
    monkeypatch.setattr(
        unload_timer,
        "_perform_transaction",
        lambda *_args, **_kwargs: _result(b"", phase=0x01, status=refused),
    )

    assert unload_timer.main([]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "refused with sense 052400" in captured.err
    assert usb_util.released == [(device, 7)]
    assert usb_util.disposed == [device]
