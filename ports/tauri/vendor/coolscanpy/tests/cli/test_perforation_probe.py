"""Hardware-free tests for the LS-5000 perforation-table probe."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import SimpleNamespace

import pytest

from coolscanpy.cli import perforation_probe


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


def test_two_step_read_uses_control_80_and_decodes_records(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=5)
    usb_util = _FakeUsbUtil()
    ep_out = object()
    ep_in = object()
    payloads = [
        bytes.fromhex("008e00000010"),
        bytes.fromhex("008e0000001000040010812200200533"),
    ]
    calls: list[dict] = []
    monkeypatch.setattr(
        perforation_probe,
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
        assert (out, incoming) == (ep_out, ep_in)
        assert data_timeout_ms == 30_000
        assert deadline_monotonic is None
        calls.append(entry)
        return _result(payloads.pop(0))

    monkeypatch.setattr(perforation_probe, "_perform_transaction", perform)

    table = perforation_probe.read_perforation_table()

    assert table == perforation_probe.PerforationTable(
        declared_length=16,
        records=(
            perforation_probe.PerforationRecord(16, True, 1, 34),
            perforation_probe.PerforationRecord(32, False, 5, 51),
        ),
    )
    assert [call["cdb"] for call in calls] == [
        "28008e00000000000680",
        "28008e00000000001080",
    ]
    assert [call["request_len"] for call in calls] == [6, 16]
    assert [call["request_parts"] for call in calls] == [[6], [16]]
    assert usb_util.released == [(device, 5)]
    assert usb_util.disposed == [device]


def test_formatted_table_is_stable() -> None:
    table = perforation_probe.PerforationTable(
        declared_length=12,
        records=(perforation_probe.PerforationRecord(7, False, 3, 9),),
    )

    assert perforation_probe.format_perforation_table(table) == (
        "perforation_table_bytes: 12\n"
        "perforation_records: 1\n"
        "index perforation count_switched pattern pulse\n"
        "1 7 false 3 9\n"
    )


def test_check_condition_is_reported_as_expected_unavailable_data(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=6)
    usb_util = _FakeUsbUtil()
    monkeypatch.setattr(
        perforation_probe,
        "_connect_device",
        lambda: (device, interface, object(), object(), usb_util),
    )
    check_condition = bytes.fromhex("02052c0000000000")
    monkeypatch.setattr(
        perforation_probe,
        "_perform_transaction",
        lambda *_args, **_kwargs: _result(
            b"",
            phase=0x01,
            status=check_condition,
        ),
    )

    assert perforation_probe.main([]) == 3
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == (
        "CHECK CONDITION: 8Eh length header returned CHECK CONDITION sense "
        "052c00; thumbnail perforation data is not available\n"
    )
    assert usb_util.released == [(device, 6)]
    assert usb_util.disposed == [device]


def test_prethumbnail_empty_length_is_cleanly_unavailable(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    device = object()
    interface = SimpleNamespace(bInterfaceNumber=1)
    usb_util = _FakeUsbUtil()
    monkeypatch.setattr(
        perforation_probe,
        "_connect_device",
        lambda: (device, interface, object(), object(), usb_util),
    )
    monkeypatch.setattr(
        perforation_probe,
        "_perform_transaction",
        lambda *_args, **_kwargs: _result(bytes.fromhex("008e00000004")),
    )

    assert perforation_probe.main([]) == 3
    captured = capsys.readouterr()
    assert "no completed thumbnail perforation table" in captured.err
    assert usb_util.released == [(device, 1)]


@pytest.mark.parametrize(
    "payload",
    (
        bytes.fromhex("008f0000000c000400000000"),
        bytes.fromhex("008e00000010000400000000"),
        bytes.fromhex("008e0000000d00040000000000"),
    ),
)
def test_malformed_tables_fail_closed(payload: bytes) -> None:
    with pytest.raises(perforation_probe.PerforationProbeError):
        perforation_probe._decode_table(payload, expected_length=len(payload))
