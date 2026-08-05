"""Motion-free LS-5000 film-presence probe over raw USB.

A bare SCSI TEST UNIT READY has no data phase and does not command transport
motion. Captured LS-5000 traffic establishes the two verdicts used here:
``000000`` means the scanner is ready with medium gripped and ``023a00`` is
NOT READY / MEDIUM NOT PRESENT. Every other reply is unknown.

The probe cannot distinguish movable film from a short strip parked at the
transport end-stop; both can report ``000000``. It therefore answers only
whether film is present, never whether a subsequent movement will succeed.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from numbers import Real

from coolscanpy._logging import get_logger
from coolscanpy.transport._usb_selector import parse_local_usb_device_id

logger = get_logger(__name__)

_TEST_UNIT_READY_CDB = "000000000000"
_TEST_UNIT_READY_PHASE = 0x01
_MEDIUM_NOT_PRESENT_SENSE = "023a00"
_READY_SENSE = "000000"
_STARTUP_UNIT_ATTENTION_SENSES = frozenset({"062900", "063f04", "062800", "063f03"})
_ADAPTER_FRAME_CAPACITY = 40
_DEFAULT_TIMEOUT_MS = 5_000
_SETTLE_DEADLINE_SECONDS = 10.0
_SETTLE_POLL_SECONDS = 0.1


@dataclass(frozen=True)
class AdapterStatus:
    """One tri-state, motion-free reading of the scanner transport.

    ``None`` means no trustworthy verdict was available, never that film is
    absent. ``frame_capacity`` is the adapter's fixed mechanical bound and is
    populated only when film presence is confirmed.
    """

    film_present: bool | None
    frame_capacity: int | None
    raw_status: str | None
    sense_history: tuple[str, ...] = ()
    device_id: str | None = None


def _classify_film_presence(sense: str) -> bool | None:
    if sense == _READY_SENSE:
        return True
    if sense == _MEDIUM_NOT_PRESENT_SENSE:
        return False
    return None


def _connect_device(*, device_id: str | None = None):
    """Use the capture worker's verified raw-USB claim routine."""

    usb_bus: int | None = None
    usb_address: int | None = None
    if device_id is not None:
        usb_bus, usb_address = parse_local_usb_device_id(device_id)

    from coolscanpy.protocol.ls5000_single_pass.worker import _connect_device as connect

    return connect(
        expected_usb_bus=usb_bus,
        expected_usb_address=usb_address,
    )


def _perform_transaction(
    ep_out,
    ep_in,
    entry: dict,
    *,
    data_timeout_ms: int,
    deadline_monotonic: float | None = None,
):
    """Use the capture worker's verified single-command transaction."""

    from coolscanpy.protocol.ls5000_single_pass.worker import perform_transaction

    return perform_transaction(
        ep_out,
        ep_in,
        entry,
        data_timeout_ms=data_timeout_ms,
        deadline_monotonic=deadline_monotonic,
    )


def _validated_transaction_sense(result: object) -> str:
    """Return a sense only from a complete, well-formed no-data reply."""

    phase = getattr(result, "phase", None)
    if type(phase) is not int:
        raise ValueError("TEST UNIT READY result has no integer protocol phase")
    if phase != _TEST_UNIT_READY_PHASE:
        raise ValueError(
            f"TEST UNIT READY result phase 0x{phase:02x}, "
            f"expected 0x{_TEST_UNIT_READY_PHASE:02x}"
        )

    payload = getattr(result, "payload", None)
    if not isinstance(payload, bytes) or payload:
        raise ValueError("TEST UNIT READY result must have an empty bytes payload")

    status = getattr(result, "status", None)
    if not isinstance(status, bytes) or len(status) != 8:
        raise ValueError("TEST UNIT READY result must have an 8-byte status")

    sense = getattr(result, "sense", None)
    status_sense = status[1:4].hex()
    if not isinstance(sense, str) or sense != status_sense:
        raise ValueError(
            "TEST UNIT READY result sense does not match its 8-byte status"
        )

    expected_condition = 0x00 if sense == _READY_SENSE else 0x02
    if status[0] != expected_condition or status[5:] != bytes(3):
        raise ValueError("TEST UNIT READY result has a malformed Nikon status envelope")
    return sense


def _validate_timing(
    name: str,
    value: object,
    *,
    integer: bool = False,
    strictly_positive: bool = False,
) -> None:
    expected_type = int if integer else Real
    if isinstance(value, bool) or not isinstance(value, expected_type):
        kind = "integer" if integer else "number"
        raise TypeError(f"{name} must be a finite nonnegative {kind}")
    if not math.isfinite(value) or value < 0 or (strictly_positive and value == 0):
        bound = "positive" if strictly_positive else "nonnegative"
        raise ValueError(f"{name} must be finite and {bound}")


def probe_adapter_status(
    *,
    device_id: str | None = None,
    data_timeout_ms: int = _DEFAULT_TIMEOUT_MS,
    settle_deadline_seconds: float = _SETTLE_DEADLINE_SECONDS,
    settle_poll_seconds: float = _SETTLE_POLL_SECONDS,
) -> AdapterStatus:
    """Read film presence without moving the scanner.

    The interface is opened only for this query and always released. Recorded
    startup unit-attention replies may be drained with repeated idempotent TEST
    UNIT READY queries. Connection, claim, protocol, validation, and cleanup
    failures all degrade to an unknown verdict.
    """

    _validate_timing(
        "data_timeout_ms",
        data_timeout_ms,
        integer=True,
        strictly_positive=True,
    )
    _validate_timing("settle_deadline_seconds", settle_deadline_seconds)
    _validate_timing("settle_poll_seconds", settle_poll_seconds)

    try:
        if device_id is None:
            device, interface, ep_out, ep_in, usb_util = _connect_device()
        else:
            device, interface, ep_out, ep_in, usb_util = _connect_device(
                device_id=device_id
            )
    except Exception as error:
        logger.debug(f"adapter status probe could not open the scanner: {error}")
        return AdapterStatus(
            film_present=None,
            frame_capacity=None,
            raw_status=None,
        )

    usb_bus = getattr(device, "bus", None)
    usb_address = getattr(device, "address", None)
    claimed_device_id = (
        f"usb:{usb_bus}:{usb_address}"
        if usb_bus is not None and usb_address is not None
        else None
    )

    try:
        initial_transaction_deadline = time.monotonic() + data_timeout_ms / 1_000
        settle_deadline: float | None = None
        sense_history: list[str] = []
        while True:
            if settle_deadline is not None and time.monotonic() >= settle_deadline:
                return AdapterStatus(
                    film_present=None,
                    frame_capacity=None,
                    raw_status=sense_history[-1],
                    sense_history=tuple(sense_history),
                    device_id=claimed_device_id,
                )

            try:
                result = _perform_transaction(
                    ep_out,
                    ep_in,
                    {
                        "seq": "adapter-status-probe",
                        "name": "TEST_UNIT_READY",
                        "cdb": _TEST_UNIT_READY_CDB,
                    },
                    data_timeout_ms=data_timeout_ms,
                    deadline_monotonic=(
                        initial_transaction_deadline
                        if settle_deadline is None
                        else settle_deadline
                    ),
                )
                sense = _validated_transaction_sense(result)
            except Exception as error:
                logger.debug(f"adapter status probe transaction failed: {error}")
                return AdapterStatus(
                    film_present=None,
                    frame_capacity=None,
                    raw_status=sense_history[-1] if sense_history else None,
                    sense_history=tuple(sense_history),
                    device_id=claimed_device_id,
                )

            sense_history.append(sense)
            if sense not in _STARTUP_UNIT_ATTENTION_SENSES:
                present = _classify_film_presence(sense)
                return AdapterStatus(
                    film_present=present,
                    frame_capacity=(
                        _ADAPTER_FRAME_CAPACITY if present is True else None
                    ),
                    raw_status=sense,
                    sense_history=(
                        tuple(sense_history) if len(sense_history) > 1 else ()
                    ),
                    device_id=claimed_device_id,
                )

            if settle_deadline is None:
                settle_deadline = time.monotonic() + settle_deadline_seconds
            now = time.monotonic()
            if now >= settle_deadline:
                return AdapterStatus(
                    film_present=None,
                    frame_capacity=None,
                    raw_status=sense,
                    sense_history=tuple(sense_history),
                    device_id=claimed_device_id,
                )
            time.sleep(
                min(
                    settle_poll_seconds,
                    max(0.0, settle_deadline - now),
                )
            )
    finally:
        try:
            usb_util.release_interface(device, interface.bInterfaceNumber)
        except Exception as error:
            logger.debug(f"adapter status probe could not release interface: {error}")
        try:
            usb_util.dispose_resources(device)
        except Exception as error:
            logger.debug(f"adapter status probe could not dispose resources: {error}")


__all__ = ["AdapterStatus", "probe_adapter_status"]
