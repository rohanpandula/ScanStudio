"""coolscanpy -- direct-USB acquisition library for Nikon Coolscan film scanners.

A python-sane-style API (module-level ``get_devices()``/``open()``, a
``Device`` with typed option attributes, ``dev.scan() -> ndarray``) plus a
roll-feeder extension (``Device.roll() -> Roll``: whole-roll preview,
spacing-offset registration, fingerprint-refusal safety, one-shot batch fine
scanning, receipts). See the package README for the hardware this has
actually been validated against and what remains untested.
"""

from __future__ import annotations

try:
    from importlib.metadata import version as _pkg_version

    __version__ = _pkg_version("coolscanpy")
except Exception:  # pragma: no cover - only when the package isn't installed
    __version__ = "0.1.0"

from coolscanpy._device import Device, get_devices, open
from coolscanpy._roll import Roll
from coolscanpy.exceptions import (
    BatchIntegrityError,
    CaptureWorkerBootstrapFailed,
    DeviceBusy,
    DeviceNotFound,
    EjectFailed,
    FeederParked,
    FingerprintRefused,
    GeometryValidationError,
    ManualReviewRequired,
    PyCoolscanError,
    RefeedRequired,
    RollMismatch,
    SafeStopRequested,
    SplitAlignmentError,
    TransportSmearDetected,
)
from coolscanpy.types import (
    ApprovalReceipt,
    ArtifactEvidence,
    Capabilities,
    ClippingTelemetry,
    DeviceInfo,
    DigitalIceAcquisition,
    DigitalIceAcquisitionEvidence,
    ExposureVector,
    FingerprintComparison,
    FocusDetailTelemetry,
    Frame,
    Material,
    Option,
    OptionType,
    OptionUnit,
    Progress,
    Receipt,
    RollFingerprint,
    SplitAlignment,
    Thumbnail,
    TransportSmearAssessment,
    build_digital_ice_acquisition_evidence,
)

__all__ = [
    "__version__",
    # module-level (python-sane-shaped)
    "get_devices",
    "open",
    # core objects
    "Device",
    "Option",
    "OptionType",
    "OptionUnit",
    "Capabilities",
    "DeviceInfo",
    "DigitalIceAcquisition",
    "DigitalIceAcquisitionEvidence",
    # roll extension
    "Roll",
    "Material",
    "Thumbnail",
    "Frame",
    "RollFingerprint",
    "FingerprintComparison",
    "Progress",
    # receipts
    "Receipt",
    "ExposureVector",
    "SplitAlignment",
    "ClippingTelemetry",
    "FocusDetailTelemetry",
    "TransportSmearAssessment",
    "ArtifactEvidence",
    "ApprovalReceipt",
    "build_digital_ice_acquisition_evidence",
    # exceptions
    "PyCoolscanError",
    "DeviceNotFound",
    "DeviceBusy",
    "EjectFailed",
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
]
