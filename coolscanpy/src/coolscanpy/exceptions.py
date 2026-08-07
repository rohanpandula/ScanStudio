"""Public exception hierarchy.

Every exception a caller can reasonably expect to catch from the public
surface (``coolscanpy.get_devices``/``open``/``Device``/``Roll``) is defined
here and re-exported from :mod:`coolscanpy`. Nothing under a leading
underscore anywhere else in this package is part of the contract these
exceptions describe.
"""

from __future__ import annotations

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
    "CaptureWorkerBootstrapFailed",
    "RollMismatch",
    "FingerprintRefused",
    "ManualReviewRequired",
    "RefeedRequired",
    "GeometryValidationError",
    "TransportSmearDetected",
    "SplitAlignmentError",
    "BatchIntegrityError",
    "MeterUnusableError",
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
