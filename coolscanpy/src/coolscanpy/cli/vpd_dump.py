#!/usr/bin/env python3
"""Read and print the LS-5000 INQUIRY VPD pages over raw USB.

This command is deliberately motion-free. It sends only standard INQUIRY and
INQUIRY with EVPD set; it never sends SCAN, SET WINDOW, READ, or an eject or
positioning command.

Contract grounding: the standard ``12 00 00 00 24 80`` CDB, data-in phase
``03h``, successful Nikon status envelope, and the EVPD form
``12 01 <page> 00 <allocation> 80`` come from
``protocol/ls5000_single_pass/data/replay-first-rgbi4-plan.jsonl``. Records
5--16 and 25--30 in that capture also establish the four-byte EVPD header,
the page-length byte at offset three, and the two-step read: allocation four
first, then allocation four plus the returned page length. The five-second
data timeout and the USB claim/release lifecycle match
``transport.adapter_status``. The 16-byte rows, headings, uppercase hex, and
printable-ASCII column match the recorded ``nkscan dump`` output in
``digital-ice-2026/shortstrip-lab/live-attempts/20260810-nkscan-probe-real-5000/dump.out``.

``nkscan dump`` instead uses one fixed-allocation read for each page. The
difference is deliberate: this command reproduces the observed Nikon Scan
dialect and exposes stale-tail buffer behavior differently. Responses are
bounded by the length learned from the first header, so an overlong stale
tail is not attributed to the page; an otherwise valid short body is printed
at its actual length.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from typing import Sequence

from coolscanpy._logging import get_logger
from coolscanpy.transport.adapter_status import _connect_device, _perform_transaction

logger = get_logger(__name__)

_STANDARD_INQUIRY_CDB = "120000002480"
_STANDARD_INQUIRY_LENGTH = 0x24
_EVPD_HEADER_LENGTH = 0x04
_INQUIRY_DATA_PHASE = 0x03
_GOOD_SENSE = "000000"
_DEFAULT_TIMEOUT_MS = 5_000
_HEXDUMP_ROW_BYTES = 16
_HEXDUMP_HEX_WIDTH = _HEXDUMP_ROW_BYTES * 3 - 1
_MAX_INQUIRY_ALLOCATION = 0xFF


class VpdDumpError(RuntimeError):
    """The scanner refused or returned an invalid INQUIRY transaction."""


@dataclass(frozen=True)
class VpdDump:
    """Validated payloads collected during one claimed USB session."""

    standard_inquiry: bytes
    pages: tuple[tuple[int, bytes], ...]
    device_location: str


def _inquiry_cdb(*, page_code: int, allocation: int) -> str:
    if not 0 <= page_code <= 0xFF:
        raise ValueError("VPD page code must fit in one byte")
    if not 1 <= allocation <= _MAX_INQUIRY_ALLOCATION:
        raise VpdDumpError(
            f"INQUIRY allocation {allocation} does not fit the captured CDB"
        )
    return bytes((0x12, 0x01, page_code, 0x00, allocation, 0x80)).hex()


def _validated_inquiry_payload(result: object, *, label: str) -> bytes:
    """Return data only from a complete, successful Nikon INQUIRY reply."""

    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise VpdDumpError(f"{label} result has no integer protocol phase")

    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes):
        raise VpdDumpError(f"{label} result has no bytes payload")

    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise VpdDumpError(f"{label} result must have an 8-byte status")

    sense = getattr(result, "sense", None)
    status_sense = status[1:4].hex()
    if not isinstance(sense, str) or sense != status_sense:
        raise VpdDumpError(f"{label} result sense does not match its 8-byte status")
    if status[5:] != bytes(3):
        raise VpdDumpError(f"{label} result has a malformed Nikon status envelope")
    if phase != _INQUIRY_DATA_PHASE or sense != _GOOD_SENSE or status[0] != 0x00:
        raise VpdDumpError(f"{label} refused with sense {sense}")
    return payload


def _perform_inquiry(
    ep_out: object,
    ep_in: object,
    *,
    cdb: str,
    allocation: int,
    sequence: str,
) -> bytes:
    try:
        result = _perform_transaction(
            ep_out,
            ep_in,
            {
                "seq": sequence,
                "name": "INQUIRY",
                "cdb": cdb,
                "request_len": allocation,
                "request_parts": [allocation],
            },
            data_timeout_ms=_DEFAULT_TIMEOUT_MS,
        )
    except Exception as error:
        raise VpdDumpError(f"{sequence} transaction failed: {error}") from error
    return _validated_inquiry_payload(result, label=sequence)


def _validate_vpd_header(payload: bytes, *, page_code: int, label: str) -> None:
    if len(payload) < _EVPD_HEADER_LENGTH:
        raise VpdDumpError(
            f"{label} returned {len(payload)} bytes, fewer than the four-byte header"
        )
    if payload[0] != 0x06 or payload[1] != page_code or payload[2] != 0x00:
        raise VpdDumpError(
            f"{label} returned an unexpected VPD header {payload[:4].hex()}"
        )


def _fetch_vpd_page(ep_out: object, ep_in: object, page_code: int) -> bytes:
    """Fetch one VPD page with the captured four-byte-header handshake."""

    page_label = f"page {page_code:02X}h"
    header = _perform_inquiry(
        ep_out,
        ep_in,
        cdb=_inquiry_cdb(page_code=page_code, allocation=_EVPD_HEADER_LENGTH),
        allocation=_EVPD_HEADER_LENGTH,
        sequence=f"{page_label} header",
    )
    _validate_vpd_header(header, page_code=page_code, label=f"{page_label} header")

    page_total = _EVPD_HEADER_LENGTH + header[3]
    if page_total > _MAX_INQUIRY_ALLOCATION:
        raise VpdDumpError(
            f"{page_label} declares {page_total} bytes, beyond the captured CDB limit"
        )
    payload = _perform_inquiry(
        ep_out,
        ep_in,
        cdb=_inquiry_cdb(page_code=page_code, allocation=page_total),
        allocation=page_total,
        sequence=page_label,
    )
    _validate_vpd_header(payload, page_code=page_code, label=page_label)
    return payload[:page_total]


def _parse_page_list(payload: bytes) -> tuple[int, ...]:
    """Return advertised nonzero page codes, bounded by page 00h's length."""

    _validate_vpd_header(payload, page_code=0x00, label="page 00h")
    advertised = payload[4 : 4 + payload[3]]
    return tuple(page_code for page_code in advertised if page_code != 0x00)


def _device_location(device: object) -> str:
    bus = getattr(device, "bus", None)
    raw_ports = getattr(device, "port_numbers", None)
    if type(bus) is int and raw_ports:
        ports = tuple(raw_ports)
        if ports and all(type(port) is int and port >= 0 for port in ports):
            return f"usb:{bus:03d}-" + ".".join(str(port) for port in ports)

    address = getattr(device, "address", None)
    if type(bus) is int and type(address) is int:
        return f"usb:{bus:03d}:{address:03d}"
    return "usb:unknown"


def collect_vpd_dump(*, device_id: str | None = None) -> VpdDump:
    """Claim one LS-5000, collect standard INQUIRY and its advertised VPD."""

    try:
        if device_id is None:
            device, interface, ep_out, ep_in, usb_util = _connect_device()
        else:
            device, interface, ep_out, ep_in, usb_util = _connect_device(
                device_id=device_id
            )
    except Exception as error:
        raise VpdDumpError(f"could not open the scanner: {error}") from error

    try:
        standard = _perform_inquiry(
            ep_out,
            ep_in,
            cdb=_STANDARD_INQUIRY_CDB,
            allocation=_STANDARD_INQUIRY_LENGTH,
            sequence="standard INQUIRY",
        )
        if len(standard) != _STANDARD_INQUIRY_LENGTH:
            raise VpdDumpError(
                f"standard INQUIRY returned {len(standard)} bytes, "
                f"expected {_STANDARD_INQUIRY_LENGTH}"
            )

        page_zero = _fetch_vpd_page(ep_out, ep_in, 0x00)
        page_codes = _parse_page_list(page_zero)
        pages = tuple(
            (page_code, _fetch_vpd_page(ep_out, ep_in, page_code))
            for page_code in page_codes
        )
        return VpdDump(
            standard_inquiry=standard,
            pages=pages,
            device_location=_device_location(device),
        )
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception as error:
            logger.debug(f"VPD dump could not release interface: {error}")
        try:
            usb_util.dispose_resources(device)
        except Exception as error:
            logger.debug(f"VPD dump could not dispose resources: {error}")


def _hexdump(payload: bytes) -> str:
    rows: list[str] = []
    for offset in range(0, len(payload), _HEXDUMP_ROW_BYTES):
        chunk = payload[offset : offset + _HEXDUMP_ROW_BYTES]
        octets = " ".join(f"{value:02X}" for value in chunk)
        printable = "".join(
            chr(value) if 0x20 <= value <= 0x7E else "." for value in chunk
        )
        rows.append(f"  {offset:04X}  {octets:<{_HEXDUMP_HEX_WIDTH}}  {printable}")
    return "\n".join(rows)


def format_vpd_dump(dump: VpdDump) -> str:
    """Format a dump for direct comparison with the nkscan reference."""

    standard = dump.standard_inquiry
    vendor = standard[8:16].decode("ascii", errors="replace").strip()
    product = standard[16:32].decode("ascii", errors="replace").strip()
    identity = f"{vendor} {product}".strip()
    page_codes = tuple(page_code for page_code, _payload in dump.pages)
    page_summary = " ".join(f"{page_code:02X}h" for page_code in page_codes)

    lines = [
        f"{identity:<20} {dump.device_location}",
        "",
        "== standard INQUIRY ==",
        _hexdump(standard),
        "",
        f"  {len(page_codes)} pages:" + (f" {page_summary}" if page_summary else ""),
    ]
    for page_code, payload in dump.pages:
        lines.extend(
            (
                "",
                f"== page {page_code:02X}h ==",
                _hexdump(payload),
            )
        )
    return "\n".join(lines) + "\n"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--device",
        help="exact local USB device ID; default is fresh LS-5000 discovery",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        dump = collect_vpd_dump(device_id=args.device)
    except VpdDumpError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    print(format_vpd_dump(dump), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
