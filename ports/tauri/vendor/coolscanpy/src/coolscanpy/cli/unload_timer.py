#!/usr/bin/env python3
"""Read the LS-5000 automatic unload timer with GET PARAMETER B4h.

This probe is read-only: it sends GET PARAMETER (E1h) and never sends SET
PARAMETER or EXECUTE.  The 9-byte request follows the B4h fields through the
second setting value: Table 2-15-2 defines the first and second values at
bytes 1--4 and 5--8 (``LS5kIFSpec.md:9755-9810``), Table 2-15-3 identifies
B4h as ``Unload time set`` (``:9953-9957``), and Table 2-15-4 defines those
values as seconds and 0=timer OFF / 1=timer ON (``:10165-10175``).  GET
PARAMETER's E1h CDB and control byte 00 are specified by Table 2-16-1
(``:10276-10347``).
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from typing import Sequence

from coolscanpy._logging import get_logger
from coolscanpy.transport.adapter_status import _connect_device, _perform_transaction

logger = get_logger(__name__)

_GET_PARAMETER_CDB = "e100b400000000000900"
_PARAMETER_LENGTH = 9
_DATA_IN_PHASE = 0x03
_GOOD_SENSE = "000000"
_DEFAULT_TIMEOUT_MS = 5_000


class UnloadTimerError(RuntimeError):
    """The scanner refused or returned an invalid B4h parameter."""


@dataclass(frozen=True)
class UnloadTimer:
    """Current B4h values reported by the scanner."""

    seconds: int
    enabled: bool


def _validated_payload(result: object) -> bytes:
    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise UnloadTimerError("GET PARAMETER result has no integer protocol phase")

    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes):
        raise UnloadTimerError("GET PARAMETER result has no bytes payload")

    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise UnloadTimerError("GET PARAMETER result must have an 8-byte status")

    sense = getattr(result, "sense", None)
    if not isinstance(sense, str) or sense != status[1:4].hex():
        raise UnloadTimerError(
            "GET PARAMETER result sense does not match its 8-byte status"
        )
    if status[5:] != bytes(3):
        raise UnloadTimerError("GET PARAMETER result has a malformed Nikon status")
    if phase != _DATA_IN_PHASE or status[0] != 0x00 or sense != _GOOD_SENSE:
        raise UnloadTimerError(f"GET PARAMETER B4h refused with sense {sense}")
    if len(payload) != _PARAMETER_LENGTH:
        raise UnloadTimerError(
            f"GET PARAMETER B4h returned {len(payload)} bytes, "
            f"expected {_PARAMETER_LENGTH}"
        )
    return payload


def _decode_unload_timer(payload: bytes) -> UnloadTimer:
    if len(payload) != _PARAMETER_LENGTH:
        raise UnloadTimerError(
            f"B4h parameter has {len(payload)} bytes, expected {_PARAMETER_LENGTH}"
        )
    seconds = int.from_bytes(payload[1:5], "big")
    enabled_value = int.from_bytes(payload[5:9], "big")
    if seconds != 0 and not 60 <= seconds <= 3_600:
        raise UnloadTimerError(
            f"B4h unload time {seconds} is outside the specified 60..3600 seconds"
        )
    if enabled_value not in (0, 1):
        raise UnloadTimerError(
            f"B4h timer enable value {enabled_value} is not 0 or 1"
        )
    return UnloadTimer(seconds=seconds, enabled=enabled_value == 1)


def read_unload_timer(*, device_id: str | None = None) -> UnloadTimer:
    """Claim one scanner, perform the read-only B4h query, and release it."""

    try:
        if device_id is None:
            device, interface, ep_out, ep_in, usb_util = _connect_device()
        else:
            device, interface, ep_out, ep_in, usb_util = _connect_device(
                device_id=device_id
            )
    except Exception as error:
        raise UnloadTimerError(f"could not open the scanner: {error}") from error

    try:
        try:
            result = _perform_transaction(
                ep_out,
                ep_in,
                {
                    "seq": "unload-timer",
                    "name": "GET_PARAMETER:B4",
                    "cdb": _GET_PARAMETER_CDB,
                    "request_len": _PARAMETER_LENGTH,
                    "request_parts": [_PARAMETER_LENGTH],
                },
                data_timeout_ms=_DEFAULT_TIMEOUT_MS,
            )
        except Exception as error:
            raise UnloadTimerError(
                f"GET PARAMETER B4h transaction failed: {error}"
            ) from error
        return _decode_unload_timer(_validated_payload(result))
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception as error:
            logger.debug(f"unload timer probe could not release interface: {error}")
        try:
            usb_util.dispose_resources(device)
        except Exception as error:
            logger.debug(f"unload timer probe could not dispose resources: {error}")


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
        timer = read_unload_timer(device_id=args.device)
    except UnloadTimerError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    print(f"unload_timer_seconds: {timer.seconds}")
    print(f"unload_timer_enabled: {str(timer.enabled).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
