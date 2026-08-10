"""Hardware-free tests for the LS-5000 VPD dump command."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import SimpleNamespace

import pytest

from coolscanpy.cli import vpd_dump


# Captured by replay-first-rgbi4-plan.jsonl records 1, 5--6, 13--16.
_STANDARD_INQUIRY = bytes.fromhex(
    "068002021f0000004e696b6f6e2020204c532d35303030204544202020202020312e3033"
)
_PAGE_ZERO = bytes.fromhex("0600001300014041475051606162c1d1e1e3f0f8e2fbfc")
_PAGE_F0 = bytes.fromhex(
    "06f0003103400000000000001e6709c4"
    "177001001241000000000000024a0258"
    "0258010006470000000000001e68012c"
    "04b0010005"
)
_PAGE_F8 = bytes.fromhex("06f8000d63055002510260046101620100")


def _result(payload: bytes, *, phase: int = 0x03, status: bytes = bytes(8)):
    return SimpleNamespace(
        phase=phase,
        payload=payload,
        status=status,
        sense=status[1:4].hex(),
    )


def _script_transactions(
    monkeypatch: pytest.MonkeyPatch,
    payloads: list[bytes],
) -> list[dict[str, object]]:
    remaining = list(payloads)
    calls: list[dict[str, object]] = []

    def perform(
        ep_out: object,
        ep_in: object,
        entry: dict,
        *,
        data_timeout_ms: int,
        deadline_monotonic: float | None = None,
    ):
        calls.append(
            {
                "ep_out": ep_out,
                "ep_in": ep_in,
                "entry": entry,
                "data_timeout_ms": data_timeout_ms,
                "deadline_monotonic": deadline_monotonic,
            }
        )
        assert remaining
        return _result(remaining.pop(0))

    monkeypatch.setattr(vpd_dump, "_perform_transaction", perform)
    return calls


def test_page_list_parse_uses_declared_length_and_ignores_page_zero() -> None:
    stale_tail = bytes.fromhex("deadbeef")

    assert vpd_dump._parse_page_list(_PAGE_ZERO + stale_tail) == (
        0x01,
        0x40,
        0x41,
        0x47,
        0x50,
        0x51,
        0x60,
        0x61,
        0x62,
        0xC1,
        0xD1,
        0xE1,
        0xE3,
        0xF0,
        0xF8,
        0xE2,
        0xFB,
        0xFC,
    )


def test_vpd_page_uses_header_then_exact_captured_length(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = _script_transactions(
        monkeypatch,
        [bytes.fromhex("06f00031"), _PAGE_F0],
    )

    payload = vpd_dump._fetch_vpd_page(object(), object(), 0xF0)

    assert payload == _PAGE_F0
    assert [call["entry"]["cdb"] for call in calls] == [
        "1201f0000480",
        "1201f0003580",
    ]
    assert [call["entry"]["request_len"] for call in calls] == [4, 53]
    assert [call["entry"]["request_parts"] for call in calls] == [[4], [53]]
    assert [call["data_timeout_ms"] for call in calls] == [5_000, 5_000]


@pytest.mark.parametrize(
    ("returned", "expected"),
    (
        (_PAGE_F8[:12], _PAGE_F8[:12]),
        (_PAGE_F8 + bytes.fromhex("c1d1e1e3f0"), _PAGE_F8),
    ),
)
def test_vpd_page_tolerates_short_body_and_trims_stale_tail(
    monkeypatch: pytest.MonkeyPatch,
    returned: bytes,
    expected: bytes,
) -> None:
    _script_transactions(
        monkeypatch,
        [bytes.fromhex("06f8000d"), returned],
    )

    assert vpd_dump._fetch_vpd_page(object(), object(), 0xF8) == expected


def test_hexdump_matches_nkscan_row_format() -> None:
    assert vpd_dump._hexdump(_STANDARD_INQUIRY) == (
        "  0000  06 80 02 02 1F 00 00 00 4E 69 6B 6F 6E 20 20 20  "
        "........Nikon   \n"
        "  0010  4C 53 2D 35 30 30 30 20 45 44 20 20 20 20 20 20  "
        "LS-5000 ED      \n"
        "  0020  31 2E 30 33                                      1.03"
    )


def test_formatted_dump_uses_reference_sections_and_page_summary() -> None:
    dump = vpd_dump.VpdDump(
        standard_inquiry=_STANDARD_INQUIRY,
        pages=((0xF8, _PAGE_F8),),
        device_location="usb:001-2",
    )

    output = vpd_dump.format_vpd_dump(dump)

    assert output.startswith(
        "Nikon LS-5000 ED     usb:001-2\n\n== standard INQUIRY ==\n"
    )
    assert "\n  1 pages: F8h\n\n== page F8h ==\n" in output
    assert output.endswith(
        "  0010  00                                               .\n"
    )


@dataclass
class _FakeUsbUtil:
    released: list[tuple[object, int]] = field(default_factory=list)
    disposed: list[object] = field(default_factory=list)

    def release_interface(self, device: object, number: int) -> None:
        self.released.append((device, number))

    def dispose_resources(self, device: object) -> None:
        self.disposed.append(device)


def test_standard_inquiry_refusal_exits_nonzero_and_releases_usb(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    device = SimpleNamespace(bus=1, address=7, port_numbers=(2,))
    interface = SimpleNamespace(bInterfaceNumber=3)
    usb_util = _FakeUsbUtil()
    selections: list[str] = []

    def connect(*, device_id: str):
        selections.append(device_id)
        return device, interface, object(), object(), usb_util

    monkeypatch.setattr(
        vpd_dump,
        "_connect_device",
        connect,
    )

    refused_status = bytes.fromhex("0205200000000000")
    monkeypatch.setattr(
        vpd_dump,
        "_perform_transaction",
        lambda *_args, **_kwargs: _result(
            b"",
            phase=0x01,
            status=refused_status,
        ),
    )

    assert vpd_dump.main(["--device", "coolscan3:usb:libusb:001:007"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "REFUSED: standard INQUIRY refused with sense 052000\n"
    assert selections == ["coolscan3:usb:libusb:001:007"]
    assert usb_util.released == [(device, 3)]
    assert usb_util.disposed == [device]
