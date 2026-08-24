"""Public exception hierarchy.

Every exception a caller can reasonably expect to catch from the public
surface (``coolscanpy.get_devices``/``open``/``Device``/``Roll``) is defined
here and re-exported from :mod:`coolscanpy`. Nothing under a leading
underscore anywhere else in this package is part of the contract these
exceptions describe.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from coolscanpy.types import FingerprintComparison, TransportSmearAssessment

__all__ = [
    "PyCoolscanError",
    "DeviceNotFound",
    "DeviceBusy",
    "EjectFailed",
    "EjectNotAvailable",
    "SafeStopRequested",
    "FeederParked",
    "AdapterUnsupported",
    "CaptureWorkerBootstrapFailed",
    "RollMismatch",
    "FingerprintRefused",
    "ManualReviewRequired",
    "RefeedRequired",
    "TransportIndexRefused",
    "GeometryValidationError",
    "TransportSmearDetected",
    "SplitAlignmentError",
    "BatchIntegrityError",
    "MeterUnusableError",
    "MeterControllerRefusalReason",
    "MeterControllerRefused",
]


class PyCoolscanError(Exception):
    """Root of coolscanpy's exception hierarchy."""


class DeviceNotFound(PyCoolscanError):
    """``open()`` found no attached unit, or more than one and could not
    disambiguate."""


class DeviceBusy(PyCoolscanError):
    """The transport, or an in-process reservation on it, is already claimed.

    This package only ever serializes access within one process (an
    in-process lock, not a cross-process reservation) -- see the session
    model notes in the package README.
    """


class EjectFailed(PyCoolscanError):
    """A vendor eject/unload action was available but triggering it, or the
    surrounding open/close, failed."""


class EjectNotAvailable(PyCoolscanError):
    """:meth:`Roll.eject` was called with no held reservation to eject.

    Valid only while a preview's reservation is still held (between
    :meth:`Roll.preview` and the next :meth:`Roll.scan_many`/:meth:`Roll.scan`
    or an explicit :meth:`Roll.release`), or as part of the same batch call
    that finishes it (``scan_many(..., eject_after=True)``). A Roll whose
    reservation was already released -- explicitly, by a prior non-holding
    ``scan_many()``, or because no ``preview()`` has run yet -- has nothing
    left to eject from inside; physically remove the strip, or refeed and
    call :meth:`Roll.preview` again.
    """


class SafeStopRequested(PyCoolscanError):
    """A frame was attempted after :meth:`Roll.safe_stop` had already been
    requested. The frame in flight when ``safe_stop()`` was called always
    finishes and is returned/yielded normally; this is raised only for the
    frame that would have started next."""


class FeederParked(PyCoolscanError):
    """The capture outcome requires a power cycle before the transport can be
    used again."""


class AdapterUnsupported(PyCoolscanError):
    """The inserted film adapter cannot run the requested workflow.

    The strip workflows (:meth:`Roll.preview` and the batch scans that
    follow it) replay a command trace captured behind a strip feeder, and
    the hardware itself gates parts of that trace on the adapter — a
    mount adapter drops VPD page ``E2h`` and does not support the
    perforation reads the roll traversal is built on. Swapping to a
    strip feeder (SA-21/SA-30) is the remedy; slide media needs a
    dedicated single-frame workflow that does not exist yet.

    ``adapter`` is the scanner's page-01h ASCII identity (for example
    ``"Mount"``); ``supported`` names the adapter identities the
    workflow accepts.
    """

    def __init__(
        self,
        message: str,
        *,
        adapter: str,
        supported: tuple[str, ...],
    ) -> None:
        super().__init__(message)
        self.adapter = adapter
        self.supported = supported


class CaptureWorkerBootstrapFailed(PyCoolscanError):
    """The bundled worker failed before it could dispatch to the scanner.

    This is a local installation/packaging repair condition, not a statement
    about the scanner or a reason to power-cycle it.
    """


class RollMismatch(PyCoolscanError):
    """Base class for a roll that no longer matches the identity reviewed at
    the last :meth:`Roll.preview` call."""


class FingerprintRefused(RollMismatch):
    """A fresh transport read disagreed with the fingerprint bound at the
    last :meth:`Roll.preview` call: a different roll, a reordered roll, or a
    roll that shifted since preview."""

    def __init__(self, message: str, *, comparison: "FingerprintComparison") -> None:
        super().__init__(message)
        self.comparison = comparison


class ManualReviewRequired(RollMismatch):
    """A slot whose transport origin was not confidently automatic was
    scanned before being approved via :meth:`Roll.approve`."""

    def __init__(self, message: str, *, slot: int) -> None:
        super().__init__(message)
        self.slot = slot


class RefeedRequired(RollMismatch):
    """Compatibility exception for a confirmed physical refeed condition.

    Generic command-status text is not sufficient to emit this exception.
    """


class TransportIndexRefused(RefeedRequired):
    """A fresh scan binding produced a bounded replayable transport witness."""

    def __init__(
        self,
        message: str,
        *,
        error_id: str,
        diagnostics: dict,
    ) -> None:
        super().__init__(message)
        self.error_id = error_id
        self.diagnostics = diagnostics


class GeometryValidationError(PyCoolscanError):
    """A returned frame's shape, dpi, depth, or resolution tag did not match
    the request."""


class TransportSmearDetected(PyCoolscanError):
    """The stopped-transport smear assessment for a captured frame was
    ``"smear"``, or ``"indeterminate"`` with no override."""

    def __init__(self, message: str, *, assessment: "TransportSmearAssessment") -> None:
        super().__init__(message)
        self.assessment = assessment


class SplitAlignmentError(PyCoolscanError):
    """Split RGB/IR registration confidence check failed for a Coolscan
    split capture."""


class BatchIntegrityError(PyCoolscanError):
    """The packaged capture worker, plan, or manifest failed self-
    verification before any hardware access was attempted."""


@dataclass(frozen=True)
class MeterControllerRefusalReason:
    """One bounded, machine-readable meter-controller safety refusal."""

    code: str
    message: str
    channel: str | None = None
    valid_raw_samples: int | None = None
    required_raw_samples: int | None = None
    valid_aggregate_samples: int | None = None
    required_aggregate_samples: int | None = None

    @classmethod
    def from_dict(cls, payload: object) -> "MeterControllerRefusalReason":
        if not isinstance(payload, dict):
            raise ValueError("meter-controller refusal reason must be an object")
        allowed = {
            "code",
            "message",
            "channel",
            "valid_raw_samples",
            "required_raw_samples",
            "valid_aggregate_samples",
            "required_aggregate_samples",
        }
        if set(payload) - allowed:
            raise ValueError("meter-controller refusal reason has unknown fields")
        code = payload.get("code")
        message = payload.get("message")
        channel = payload.get("channel")
        if (
            not isinstance(code, str)
            or not 1 <= len(code) <= 128
            or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for character in code)
        ):
            raise ValueError("meter-controller refusal code is invalid")
        if (
            not isinstance(message, str)
            or not 1 <= len(message) <= 512
            or "\n" in message
            or "\r" in message
        ):
            raise ValueError("meter-controller refusal message is invalid")
        if channel is not None and channel not in {"R", "G", "B", "IR"}:
            raise ValueError("meter-controller refusal channel is invalid")

        counts: dict[str, int | None] = {}
        for field in (
            "valid_raw_samples",
            "required_raw_samples",
            "valid_aggregate_samples",
            "required_aggregate_samples",
        ):
            value = payload.get(field)
            if value is not None and (
                isinstance(value, bool)
                or not isinstance(value, int)
                or not 0 <= value <= 2**31 - 1
            ):
                raise ValueError(f"meter-controller refusal {field} is invalid")
            counts[field] = value
        if code == "linearity_insufficient" and any(
            counts[field] is None for field in counts
        ):
            raise ValueError(
                "linearity-insufficient refusal is missing bounded sample counts"
            )
        return cls(
            code=code,
            message=message,
            channel=channel,
            **counts,
        )

    def to_dict(self) -> dict[str, object]:
        result: dict[str, object] = {"code": self.code, "message": self.message}
        if self.channel is not None:
            result["channel"] = self.channel
        for field in (
            "valid_raw_samples",
            "required_raw_samples",
            "valid_aggregate_samples",
            "required_aggregate_samples",
        ):
            value = getattr(self, field)
            if value is not None:
                result[field] = value
        return result


class MeterControllerRefused(PyCoolscanError):
    """Fine capture was blocked by one or more meter-controller safeguards.

    This is deliberately distinct from :class:`MeterUnusableError` (no usable
    meter mean) and from :class:`RollMismatch` (roll identity or feed shift).
    """

    def __init__(
        self,
        *,
        pass_number: int,
        reasons: tuple[MeterControllerRefusalReason, ...],
    ) -> None:
        if isinstance(pass_number, bool) or pass_number not in (1, 2, 3):
            raise ValueError("meter-controller refusal pass must be 1, 2, or 3")
        if not reasons or not all(
            isinstance(reason, MeterControllerRefusalReason) for reason in reasons
        ):
            raise ValueError("meter-controller refusal must contain typed reasons")
        self.pass_number = pass_number
        self.reasons = tuple(reasons)
        channels = tuple(
            dict.fromkeys(
                reason.channel for reason in self.reasons if reason.channel is not None
            )
        )
        codes = ", ".join(reason.code for reason in self.reasons)
        channel_suffix = (
            f"; affected channels: {', '.join(channels)}" if channels else ""
        )
        super().__init__(
            f"meter pass {pass_number} controller refused: {codes}{channel_suffix}"
        )

    @classmethod
    def from_dict(cls, payload: object) -> "MeterControllerRefused":
        if not isinstance(payload, dict) or set(payload) != {"pass", "reasons"}:
            raise ValueError("meter-controller refusal record is invalid")
        pass_number = payload.get("pass")
        raw_reasons = payload.get("reasons")
        if (
            isinstance(pass_number, bool)
            or not isinstance(pass_number, int)
            or not isinstance(raw_reasons, list)
            or not 1 <= len(raw_reasons) <= 4
        ):
            raise ValueError("meter-controller refusal record is invalid")
        return cls(
            pass_number=pass_number,
            reasons=tuple(
                MeterControllerRefusalReason.from_dict(reason)
                for reason in raw_reasons
            ),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "pass": self.pass_number,
            "reasons": [reason.to_dict() for reason in self.reasons],
        }


class MeterUnusableError(PyCoolscanError):
    """The metering pass could not find usable image data for a channel.

    Raised when neither the primary meter window nor the widened full-frame
    window yields a nonzero, unsaturated mean for a channel (a B&W strip, a
    modified SA-21, or a dense negative whose G rows are all zero or
    saturated, per #17). Fail-closed: no capture proceeds with fabricated
    metering. Bridges to the ``METER_UNUSABLE`` wire code, never ``INTERNAL``.
    """

    def __init__(self, channel: str) -> None:
        super().__init__(
            f"the metering pass could not find usable image data for channel "
            f"{channel} \u2014 check film density/orientation and adapter "
            f"modification; try a different process setting"
        )
        self.channel = channel
