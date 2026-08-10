#!/usr/bin/env python3
"""Plan or explicitly execute LS-5000 wedge-recovery motion commands.

These are MOTION commands.  Live validation is owner-gated: the default is a
dry run that opens no device and sends nothing; ``--execute`` also requires a
single selected operation and an interactive ``yes`` confirmation.  There is
no non-interactive confirmation bypass.

Table 2-15-1 defines SET PARAMETER E0h and its 13-byte recommended parameter
length (``LS5kIFSpec.md:9673-9736``).  Table 2-15-2 defines that zero-filled
parameter envelope (``:9755-9809``), Table 2-15-3 assigns 80h Initialize and
81h Return to origin (``:9868-9900``), and Table 2-15-4 marks both operations
as having no parameters (``:10039-10088``).  The spec requires EXECUTE after
SET PARAMETER to start the selected operation (``:9741-9753``).
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from typing import Sequence

from coolscanpy._logging import get_logger
from coolscanpy.transport.adapter_status import _connect_device, _perform_transaction

logger = get_logger(__name__)

_PARAMETER_LENGTH = 13
_PARAMETER_DATA = bytes(_PARAMETER_LENGTH)
_EXECUTE_CDB = "c10000000000"
_GOOD_SENSE = "000000"
_DEFAULT_TIMEOUT_MS = 30_000


class WedgeRecoveryError(RuntimeError):
    """The selected recovery command was refused or malformed."""


@dataclass(frozen=True)
class RecoveryOperation:
    """One owner-selectable SET PARAMETER operation."""

    key: str
    label: str
    operation_code: int

    @property
    def set_parameter_cdb(self) -> str:
        return bytes(
            (
                0xE0,
                0x00,
                self.operation_code,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                _PARAMETER_LENGTH,
                0x00,
            )
        ).hex()


_OPERATIONS = (
    RecoveryOperation("return-to-origin", "ReturnToOrigin", 0x81),
    RecoveryOperation("initialize", "Initialize", 0x80),
)
_OPERATIONS_BY_KEY = {operation.key: operation for operation in _OPERATIONS}


def format_plan(operations: Sequence[RecoveryOperation]) -> str:
    lines = ["DRY RUN: no commands sent"]
    for operation in operations:
        lines.extend(
            (
                f"{operation.label} ({operation.operation_code:02X}h)",
                f"  SET PARAMETER CDB: {operation.set_parameter_cdb}",
                f"  parameter data ({_PARAMETER_LENGTH} bytes): {_PARAMETER_DATA.hex()}",
                f"  EXECUTE CDB: {_EXECUTE_CDB}",
                "  spec: LS5kIFSpec.md Tables 2-15-1 through 2-15-4",
            )
        )
    return "\n".join(lines) + "\n"


def _validate_no_data_result(
    result: object,
    *,
    label: str,
    expected_phase: int,
) -> None:
    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise WedgeRecoveryError(f"{label} result has no integer protocol phase")
    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes) or payload:
        raise WedgeRecoveryError(f"{label} result must have an empty bytes payload")
    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise WedgeRecoveryError(f"{label} result must have an 8-byte status")
    sense = getattr(result, "sense", None)
    if not isinstance(sense, str) or sense != status[1:4].hex():
        raise WedgeRecoveryError(
            f"{label} result sense does not match its 8-byte status"
        )
    if status[5:] != bytes(3):
        raise WedgeRecoveryError(f"{label} result has a malformed Nikon status")
    if phase != expected_phase or status[0] != 0x00 or sense != _GOOD_SENSE:
        raise WedgeRecoveryError(f"{label} refused with sense {sense}")


def execute_operation(
    operation: RecoveryOperation,
    *,
    device_id: str | None = None,
) -> None:
    """Send one confirmed SET PARAMETER + EXECUTE sequence and release USB."""

    try:
        if device_id is None:
            device, interface, ep_out, ep_in, usb_util = _connect_device()
        else:
            device, interface, ep_out, ep_in, usb_util = _connect_device(
                device_id=device_id
            )
    except Exception as error:
        raise WedgeRecoveryError(f"could not open the scanner: {error}") from error

    try:
        try:
            set_result = _perform_transaction(
                ep_out,
                ep_in,
                {
                    "seq": f"wedge-recovery-{operation.key}-set",
                    "name": f"SET_PARAMETER:{operation.operation_code:02X}",
                    "cdb": operation.set_parameter_cdb,
                    "data_out": _PARAMETER_DATA.hex(),
                },
                data_timeout_ms=_DEFAULT_TIMEOUT_MS,
            )
            _validate_no_data_result(
                set_result,
                label=f"SET PARAMETER {operation.label}",
                expected_phase=0x02,
            )
            execute_result = _perform_transaction(
                ep_out,
                ep_in,
                {
                    "seq": f"wedge-recovery-{operation.key}-execute",
                    "name": "EXECUTE",
                    "cdb": _EXECUTE_CDB,
                },
                data_timeout_ms=_DEFAULT_TIMEOUT_MS,
            )
            _validate_no_data_result(
                execute_result,
                label=f"EXECUTE {operation.label}",
                expected_phase=0x01,
            )
        except WedgeRecoveryError:
            raise
        except Exception as error:
            raise WedgeRecoveryError(
                f"{operation.label} transaction failed: {error}"
            ) from error
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception as error:
            logger.debug(f"wedge recovery could not release interface: {error}")
        try:
            usb_util.dispose_resources(device)
        except Exception as error:
            logger.debug(f"wedge recovery could not dispose resources: {error}")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--operation",
        choices=tuple(_OPERATIONS_BY_KEY),
        help="one recovery operation; required with --execute",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="send the selected motion command after interactive confirmation",
    )
    parser.add_argument(
        "--device",
        help="exact local USB device ID; default is fresh LS-5000 discovery",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.execute and args.operation is None:
        parser.error("--execute requires --operation")

    selected = (
        (_OPERATIONS_BY_KEY[args.operation],)
        if args.operation is not None
        else _OPERATIONS
    )
    print(format_plan(selected), end="")
    if not args.execute:
        return 0

    operation = selected[0]
    try:
        confirmation = input(
            f"Type yes to send {operation.label} MOTION commands [yes/NO]: "
        )
    except EOFError:
        confirmation = ""
    if confirmation.strip().lower() != "yes":
        print("Cancelled; no commands sent.")
        return 1

    try:
        execute_operation(operation, device_id=args.device)
    except WedgeRecoveryError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    print(f"SENT: {operation.label} SET PARAMETER + EXECUTE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
