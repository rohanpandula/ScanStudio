#!/usr/bin/env python3
"""Read the LS-5000's current thumbnail perforation table.

Table 2-11-1 defines the READ(28h) CDB (``LS5kIFSpec.md:7557-7632``),
Table 2-11-2 assigns read-only data type 8Eh to perforation information
(``:7691-7691`` and ``:7850-7855``), and section 2-11-8 defines its 4-byte
records (``:9003-9110``).  The scanner is first asked for the captured
6-byte 8Eh length envelope and then for exactly that declared size.  READ
uses control byte 80 as established by the LS-5000 corpus.

The command never starts a scan or moves film.  Per the spec, 8Eh data exists
after thumbnail scanning; CHECK CONDITION, or an empty pre-thumbnail length,
is reported as an expected unavailable-data result rather than a traceback.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from typing import Sequence

from coolscanpy._logging import get_logger
from coolscanpy.transport.adapter_status import _connect_device, _perform_transaction

logger = get_logger(__name__)

_DATA_TYPE = 0x8E
_HEADER_LENGTH = 6
_TABLE_PREFIX_LENGTH = 8
_RECORD_LENGTH = 4
_DATA_IN_PHASE = 0x03
_GOOD_SENSE = "000000"
_DEFAULT_TIMEOUT_MS = 30_000


class PerforationProbeError(RuntimeError):
    """The scanner returned a malformed perforation transaction."""


class PerforationUnavailable(PerforationProbeError):
    """No completed thumbnail traversal currently supplies 8Eh data."""


@dataclass(frozen=True)
class PerforationRecord:
    """One 4-byte row from section 2-11-8."""

    perforation_number: int
    count_switched: bool
    pattern_number: int
    pulse_number: int


@dataclass(frozen=True)
class PerforationTable:
    """Validated current 8Eh table."""

    declared_length: int
    records: tuple[PerforationRecord, ...]


def _read_cdb(length: int) -> str:
    if not 1 <= length <= 0xFFFFFF:
        raise ValueError("READ transfer length must fit in three bytes")
    return bytes(
        (
            0x28,
            0x00,
            _DATA_TYPE,
            0x00,
            0x00,
            0x00,
            (length >> 16) & 0xFF,
            (length >> 8) & 0xFF,
            length & 0xFF,
            0x80,
        )
    ).hex()


def _validated_read_payload(result: object, *, label: str) -> bytes:
    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise PerforationProbeError(f"{label} result has no integer protocol phase")

    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes):
        raise PerforationProbeError(f"{label} result has no bytes payload")

    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise PerforationProbeError(f"{label} result must have an 8-byte status")

    sense = getattr(result, "sense", None)
    if not isinstance(sense, str) or sense != status[1:4].hex():
        raise PerforationProbeError(
            f"{label} result sense does not match its 8-byte status"
        )
    if status[5:] != bytes(3):
        raise PerforationProbeError(f"{label} result has a malformed Nikon status")
    if status[0] == 0x02:
        raise PerforationUnavailable(
            f"{label} returned CHECK CONDITION sense {sense}; "
            "thumbnail perforation data is not available"
        )
    if phase != _DATA_IN_PHASE or status[0] != 0x00 or sense != _GOOD_SENSE:
        raise PerforationProbeError(f"{label} refused with sense {sense}")
    return payload


def _perform_read(
    ep_out: object,
    ep_in: object,
    *,
    length: int,
    sequence: str,
) -> bytes:
    try:
        result = _perform_transaction(
            ep_out,
            ep_in,
            {
                "seq": sequence,
                "name": "READ:8E",
                "cdb": _read_cdb(length),
                "request_len": length,
                "request_parts": [length],
            },
            data_timeout_ms=_DEFAULT_TIMEOUT_MS,
        )
    except Exception as error:
        raise PerforationProbeError(f"{sequence} transaction failed: {error}") from error
    return _validated_read_payload(result, label=sequence)


def _declared_table_length(header: bytes) -> int:
    if len(header) != _HEADER_LENGTH or header[:4] != b"\x00\x8e\x00\x00":
        raise PerforationProbeError(
            f"8Eh length header is malformed: {header.hex()}"
        )
    declared = int.from_bytes(header[4:6], "big")
    if declared < _TABLE_PREFIX_LENGTH:
        raise PerforationUnavailable(
            "scanner reports no completed thumbnail perforation table"
        )
    return declared


def _decode_table(payload: bytes, *, expected_length: int) -> PerforationTable:
    if len(payload) != expected_length:
        raise PerforationProbeError(
            f"8Eh table returned {len(payload)} bytes, expected {expected_length}"
        )
    if payload[:4] != b"\x00\x8e\x00\x00":
        raise PerforationProbeError("8Eh table does not repeat its length envelope")
    declared = int.from_bytes(payload[4:6], "big")
    if declared != expected_length:
        raise PerforationProbeError(
            f"8Eh table declares {declared} bytes, expected {expected_length}"
        )
    body = payload[_TABLE_PREFIX_LENGTH:]
    if len(body) % _RECORD_LENGTH:
        raise PerforationProbeError("8Eh table is not 8 plus 4 bytes per record")

    records = tuple(
        PerforationRecord(
            perforation_number=int.from_bytes(body[offset : offset + 2], "big"),
            count_switched=bool(body[offset + 2] & 0x80),
            pattern_number=body[offset + 2] & 0x7F,
            pulse_number=body[offset + 3],
        )
        for offset in range(0, len(body), _RECORD_LENGTH)
    )
    return PerforationTable(declared_length=declared, records=records)


def read_perforation_table(*, device_id: str | None = None) -> PerforationTable:
    """Claim one scanner and read the current 8Eh table without motion."""

    try:
        if device_id is None:
            device, interface, ep_out, ep_in, usb_util = _connect_device()
        else:
            device, interface, ep_out, ep_in, usb_util = _connect_device(
                device_id=device_id
            )
    except Exception as error:
        raise PerforationProbeError(f"could not open the scanner: {error}") from error

    try:
        header = _perform_read(
            ep_out,
            ep_in,
            length=_HEADER_LENGTH,
            sequence="8Eh length header",
        )
        declared = _declared_table_length(header)
        payload = _perform_read(
            ep_out,
            ep_in,
            length=declared,
            sequence="8Eh table",
        )
        return _decode_table(payload, expected_length=declared)
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception as error:
            logger.debug(f"perforation probe could not release interface: {error}")
        try:
            usb_util.dispose_resources(device)
        except Exception as error:
            logger.debug(f"perforation probe could not dispose resources: {error}")


def format_perforation_table(table: PerforationTable) -> str:
    lines = [
        f"perforation_table_bytes: {table.declared_length}",
        f"perforation_records: {len(table.records)}",
        "index perforation count_switched pattern pulse",
    ]
    lines.extend(
        f"{index} {record.perforation_number} "
        f"{str(record.count_switched).lower()} "
        f"{record.pattern_number} {record.pulse_number}"
        for index, record in enumerate(table.records, start=1)
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
        table = read_perforation_table(device_id=args.device)
    except PerforationUnavailable as error:
        print(f"CHECK CONDITION: {error}", file=sys.stderr)
        return 3
    except PerforationProbeError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    print(format_perforation_table(table), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
