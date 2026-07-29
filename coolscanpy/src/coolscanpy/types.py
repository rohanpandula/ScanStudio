"""Public dataclasses and enums shared across the top-level surface.

``Material`` is a re-export of the concrete package's own
:class:`coolscanpy.roll.controls.ScanMaterial` under the public name used by
the API contract -- the recipe each member maps to (dpi/depth/samples/IR) is
computed by the concrete ``recipe_for_material`` function, not duplicated
here.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from enum import StrEnum
from types import MappingProxyType
from typing import TYPE_CHECKING, Callable, Literal

import numpy as np

from coolscanpy.roll.controls import ScanMaterial as Material

if TYPE_CHECKING:
    from coolscanpy.protocol.ls5000_single_pass.density import (
        NikonDensityEvidence,
        NikonDensityFrameOwnershipReceipt,
        NikonExactBuilderEvidence,
    )

__all__ = [
    "Material",
    "OptionType",
    "OptionUnit",
    "Option",
    "Capabilities",
    "DeviceInfo",
    "Thumbnail",
    "RollFingerprint",
    "FingerprintComparison",
    "Progress",
    "ProgressCallback",
    "ExposureVector",
    "SplitAlignment",
    "ClippingTelemetry",
    "FocusDetailTelemetry",
    "TransportSmearAssessment",
    "ArtifactEvidence",
    "DigitalIceAcquisition",
    "DigitalIceAcquisitionEvidence",
    "DIGITAL_ICE_STORAGE_TRANSFORM",
    "DIGITAL_ICE_STORAGE_TRANSFORM_V1_ROT90K1",
    "build_digital_ice_acquisition_evidence",
    "ApprovalReceipt",
    "Receipt",
    "Frame",
]


class OptionType(StrEnum):
    BOOL = "bool"
    INT = "int"
    FLOAT = "float"
    STRING = "string"


class OptionUnit(StrEnum):
    NONE = "none"
    PIXEL = "pixel"
    DPI = "dpi"
    MICROSECOND = "microsecond"


@dataclass(frozen=True)
class Option:
    """Mirrors python-sane's ``Option`` (name/title/desc/type/unit/constraint
    plus ``is_active()``/``is_settable()``), trimmed of SANE-internal
    bookkeeping that has no meaning outside a SANE backend."""

    name: str
    title: str
    desc: str
    type: OptionType
    unit: OptionUnit
    constraint: tuple[float, float, float] | tuple[int, ...] | tuple[str, ...] | None
    active: bool
    settable: bool


@dataclass(frozen=True)
class Capabilities:
    ir_channel: bool
    supported_dpi: tuple[int, ...]
    supported_depths: tuple[int, ...]
    multi_sample: bool
    adapter_frame_capacity: int | None
    adapter_frame_control: bool
    auto_exposure: bool
    registered_geometry: bool
    can_eject: bool


@dataclass(frozen=True)
class DeviceInfo:
    id: str
    vendor: str
    model: str
    capabilities: Capabilities


@dataclass(frozen=True)
class Thumbnail:
    """One preview crop plus its transport-review state.

    ``boundary_rows`` is the slot's unshifted detected interval in the saved
    whole-roll preview. ``spacing_offset`` selects another saved transport
    table row and re-crops ``image`` from that same preview; it does not alter
    the base interval reported by ``boundary_rows``.
    """

    slot: int
    image: np.ndarray
    boundary_rows: tuple[int, int]
    spacing_offset: int
    needs_approval: bool
    warnings: tuple[str, ...]


@dataclass(frozen=True)
class RollFingerprint:
    """Opaque physical-roll identity bound at the last ``preview()``."""

    sha256: str
    slot_count: int
    preview_shape: tuple[int, int, int]


@dataclass(frozen=True)
class FingerprintComparison:
    """Attached to :class:`coolscanpy.exceptions.FingerprintRefused` when a
    fresh transport read disagrees with the reviewed fingerprint."""

    matches: bool
    reason: str
    compared_frames: int
    visual_median_hamming: float | None
    visual_p90_hamming: int | None
    frame_start_median_delta_rows: float | None
    frame_start_max_delta_rows: int | None


@dataclass(frozen=True)
class Progress:
    stage: Literal["preview", "fine-scan"]
    slot: int | None
    index: int
    total: int
    fraction: float
    message: str


ProgressCallback = Callable[[Progress], None]


@dataclass(frozen=True)
class ExposureVector:
    """The replayable per-channel state the scanner actually used."""

    focus_position: int
    exposure_multiplier: float
    red_exposure_us: float
    green_exposure_us: float
    blue_exposure_us: float


@dataclass(frozen=True)
class SplitAlignment:
    """How IR was registered to the multisampled RGB in a split Coolscan
    capture, with full audit confidence."""

    mode: str
    dx_px: float
    dy_px: float
    phase_responses: tuple[float, ...]
    channel_spread_px: float | None
    ecc_coefficient: float | None
    tile_support_counts: tuple[int, ...]
    tile_shift_spread_px: float | None
    estimator_version: int | None
    multiscale_max_dimensions: tuple[int, ...]
    multiscale_channel_shifts_px: tuple[tuple[tuple[float, float], ...], ...]
    multiscale_responses: tuple[tuple[float, ...], ...]
    multiscale_tile_support_counts: tuple[tuple[int, ...], ...]
    multiscale_tile_shift_spreads_px: tuple[tuple[float, ...], ...]
    multiscale_global_alias_shifts_px: tuple[tuple[tuple[float, float], ...], ...]


@dataclass(frozen=True)
class ClippingTelemetry:
    """Warning-only. Never gates a capture."""

    fractions: tuple[float, float, float]
    clip_level: float
    warning_fraction: float
    warning: bool


@dataclass(frozen=True)
class FocusDetailTelemetry:
    """Scene-dependent detail proxy; informational, never an autofocus
    gate."""

    method: str
    verdict: Literal["measured", "indeterminate"]
    score: float | None
    texture_span: float


@dataclass(frozen=True)
class TransportSmearAssessment:
    """Fail-closed assessment of an abnormally repeated RGB tail (a stopped
    transport re-reading the same rows)."""

    verdict: Literal["clean", "smear", "indeterminate"]
    start_row: int | None
    suffix_rows: int
    minimum_matches: int
    tail_median_rms: float | None
    tail_min_corr: float | None
    pre_tail_median_rms: float | None
    texture_span: float | None
    reason: str


@dataclass(frozen=True)
class ArtifactEvidence:
    """In-memory sha256/shape/dtype of a returned array."""

    sha256: str
    byte_length: int
    shape: tuple[int, ...]
    dtype: str


DIGITAL_ICE_STORAGE_TRANSFORM = "swapaxes01-scanner-native-to-nikon-render-parity-v2"
# Pre-05bfe2a historical transform. No live capture path emits this any more
# -- single_pass_workflow.py has only ever produced DIGITAL_ICE_STORAGE_TRANSFORM
# above -- but it is named here, once, as the single canonical identifier a
# human/operator can use to LABEL an archived pre-05bfe2a capture whose
# provenance is independently known (e.g. from capture timestamp vs commit
# history), since those captures predate Receipt.storage_transform existing
# at all and carry no on-disk stamp of their own (Sol adversarial review
# 2026-07-26, finding 2). Never assigned by this module; render_roll.py's
# own copy of this same string is what an operator actually passes.
DIGITAL_ICE_STORAGE_TRANSFORM_V1_ROT90K1 = "rot90k1-scanner-native-to-storage-v1"
_DIGITAL_ICE_EVIDENCE_KIND = "coolscanpy.digital-ice-acquisition-evidence"
_DIGITAL_ICE_EVIDENCE_VERSION = 1


def _canonical_array_artifact(
    array: np.ndarray,
    *,
    dtype: np.dtype,
) -> ArtifactEvidence:
    canonical = np.array(array, dtype=dtype, order="C", copy=True)
    payload = memoryview(canonical).cast("B")
    return ArtifactEvidence(
        sha256=hashlib.sha256(payload).hexdigest(),
        byte_length=payload.nbytes,
        shape=tuple(canonical.shape),
        dtype=canonical.dtype.str,
    )


def _artifact_payload(evidence: ArtifactEvidence) -> dict[str, object]:
    return {
        "byte_length": evidence.byte_length,
        "dtype": evidence.dtype,
        "sha256": evidence.sha256,
        "shape": list(evidence.shape),
    }


def _digital_ice_identity(
    *,
    slot: int,
    reservation_id: str,
    capture_attempt_id: str,
) -> str:
    payload = {
        "capture_attempt_id": capture_attempt_id,
        "kind": "coolscanpy.digital-ice-acquisition-identity",
        "reservation_id": reservation_id,
        "slot": slot,
        "version": 1,
    }
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return f"dice-{hashlib.sha256(encoded).hexdigest()}"


def _scanner_native_main_rgbi(
    storage_rgb: np.ndarray,
    storage_ir: np.ndarray,
) -> np.ndarray:
    # swapaxes(0,1) is self-inverse, so the storage->native direction uses the
    # same operation the workflow used native->storage. This MUST track
    # single_pass_workflow's storage transform: when storage was rot90(k=1)
    # the inverse here was rot90(k=-1); storage is now swapaxes(0,1) for Nikon
    # render parity (LS5000-FLIP-OWNERSHIP-20260724), so a rot90 inverse would
    # silently mirror the reconstructed native raster.
    native_shape = (storage_rgb.shape[1], storage_rgb.shape[0])
    native = np.empty((*native_shape, 4), dtype="<u2", order="C")
    native[..., :3] = np.swapaxes(storage_rgb, 0, 1)
    native[..., 3] = np.swapaxes(storage_ir, 0, 1)
    return native


def _scanner_native_ir_validity(storage_ir_validity: np.ndarray) -> np.ndarray:
    # Same self-inverse swap as _scanner_native_main_rgbi -- keep both in step.
    return np.array(
        np.swapaxes(storage_ir_validity, 0, 1),
        dtype=np.bool_,
        order="C",
        copy=True,
    )


@dataclass(frozen=True)
class DigitalIceAcquisitionEvidence:
    """Hash-bound scanner-native inputs behind one storage-oriented frame."""

    version: int
    acquisition_id: str
    slot: int
    reservation_id: str
    capture_attempt_id: str
    storage_transform: str
    storage_rgb: ArtifactEvidence
    storage_ir: ArtifactEvidence
    storage_ir_validity: ArtifactEvidence
    scanner_native_main_rgbi: ArtifactEvidence
    scanner_native_meter_rgbi: ArtifactEvidence
    scanner_native_ir_validity: ArtifactEvidence

    def __post_init__(self) -> None:
        if self.version != _DIGITAL_ICE_EVIDENCE_VERSION:
            raise ValueError("Digital ICE evidence version is unsupported")
        if type(self.slot) is not int or not 1 <= self.slot <= 40:
            raise ValueError("Digital ICE evidence slot must be in 1..40")
        for label, value in (
            ("reservation_id", self.reservation_id),
            ("capture_attempt_id", self.capture_attempt_id),
        ):
            if type(value) is not str or not value.strip():
                raise ValueError(f"Digital ICE evidence {label} must be non-empty")
        expected_id = _digital_ice_identity(
            slot=self.slot,
            reservation_id=self.reservation_id,
            capture_attempt_id=self.capture_attempt_id,
        )
        if self.acquisition_id != expected_id:
            raise ValueError("Digital ICE acquisition identity is not canonical")
        if self.storage_transform != DIGITAL_ICE_STORAGE_TRANSFORM:
            raise ValueError("Digital ICE storage transform is unsupported")
        for label, artifact in (
            ("storage RGB", self.storage_rgb),
            ("storage IR", self.storage_ir),
            ("storage IR validity", self.storage_ir_validity),
            ("scanner-native main RGBI", self.scanner_native_main_rgbi),
            ("scanner-native meter RGBI", self.scanner_native_meter_rgbi),
            ("scanner-native IR validity", self.scanner_native_ir_validity),
        ):
            if not isinstance(artifact, ArtifactEvidence):
                raise TypeError(f"Digital ICE {label} evidence is malformed")
            if re.fullmatch(r"[0-9a-f]{64}", artifact.sha256) is None:
                raise ValueError(f"Digital ICE {label} SHA-256 is malformed")
            if artifact.byte_length < 1 or not artifact.shape:
                raise ValueError(f"Digital ICE {label} geometry is malformed")

    @property
    def sha256(self) -> str:
        payload = {
            "acquisition_id": self.acquisition_id,
            "artifacts": {
                "scanner_native_ir_validity": _artifact_payload(
                    self.scanner_native_ir_validity
                ),
                "scanner_native_main_rgbi": _artifact_payload(
                    self.scanner_native_main_rgbi
                ),
                "scanner_native_meter_rgbi": _artifact_payload(
                    self.scanner_native_meter_rgbi
                ),
                "storage_ir": _artifact_payload(self.storage_ir),
                "storage_ir_validity": _artifact_payload(self.storage_ir_validity),
                "storage_rgb": _artifact_payload(self.storage_rgb),
            },
            "capture_attempt_id": self.capture_attempt_id,
            "kind": _DIGITAL_ICE_EVIDENCE_KIND,
            "reservation_id": self.reservation_id,
            "slot": self.slot,
            "storage_transform": self.storage_transform,
            "version": self.version,
        }
        encoded = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True)
class DigitalIceAcquisition:
    """Revalidated scanner-native inputs ready for the Digital ICE engine."""

    acquisition_id: str
    slot: int
    reservation_id: str
    capture_attempt_id: str
    storage_transform: str
    evidence_sha256: str
    main_rgbi_sha256: str
    meter_rgbi_sha256: str
    ir_validity_sha256: str
    main_rgbi: np.ndarray
    meter_rgbi: np.ndarray
    ir_validity: np.ndarray


def build_digital_ice_acquisition_evidence(
    *,
    slot: int,
    reservation_id: str,
    capture_attempt_id: str,
    storage_rgb: np.ndarray,
    storage_ir: np.ndarray,
    storage_ir_validity: np.ndarray,
    meter_rgbi: np.ndarray,
) -> DigitalIceAcquisitionEvidence:
    rgb = np.asarray(storage_rgb)
    ir = np.asarray(storage_ir)
    validity = np.asarray(storage_ir_validity)
    meter = np.asarray(meter_rgbi)
    if rgb.ndim != 3 or rgb.shape[2] != 3 or rgb.dtype != np.uint16:
        raise ValueError("Digital ICE storage RGB must be HxWx3 uint16")
    if ir.shape != rgb.shape[:2] or ir.dtype != np.uint16:
        raise ValueError("Digital ICE storage IR must match RGB as uint16")
    if validity.shape != rgb.shape[:2] or validity.dtype != np.bool_:
        raise ValueError("Digital ICE IR validity must match RGB as bool")
    if meter.ndim != 3 or meter.shape[2] != 4 or meter.dtype != np.uint16:
        raise ValueError("Digital ICE meter must be HxWx4 uint16")
    native_main = _scanner_native_main_rgbi(rgb, ir)
    native_validity = _scanner_native_ir_validity(validity)
    acquisition_id = _digital_ice_identity(
        slot=slot,
        reservation_id=reservation_id,
        capture_attempt_id=capture_attempt_id,
    )
    return DigitalIceAcquisitionEvidence(
        version=_DIGITAL_ICE_EVIDENCE_VERSION,
        acquisition_id=acquisition_id,
        slot=slot,
        reservation_id=reservation_id,
        capture_attempt_id=capture_attempt_id,
        storage_transform=DIGITAL_ICE_STORAGE_TRANSFORM,
        storage_rgb=_canonical_array_artifact(rgb, dtype=np.dtype("<u2")),
        storage_ir=_canonical_array_artifact(ir, dtype=np.dtype("<u2")),
        storage_ir_validity=_canonical_array_artifact(
            validity, dtype=np.dtype(np.bool_)
        ),
        scanner_native_main_rgbi=_canonical_array_artifact(
            native_main, dtype=np.dtype("<u2")
        ),
        scanner_native_meter_rgbi=_canonical_array_artifact(
            meter, dtype=np.dtype("<u2")
        ),
        scanner_native_ir_validity=_canonical_array_artifact(
            native_validity, dtype=np.dtype(np.bool_)
        ),
    )


class _ImmutableArtifacts(Mapping[str, ArtifactEvidence]):
    """Copied, read-only artifact evidence with stable mapping semantics."""

    __slots__ = ("__values",)

    def __init__(self, values: Mapping[str, ArtifactEvidence]) -> None:
        object.__setattr__(
            self,
            "_ImmutableArtifacts__values",
            MappingProxyType(dict(values)),
        )

    def __getitem__(self, key: str) -> ArtifactEvidence:
        return self.__values[key]

    def __iter__(self) -> Iterator[str]:
        return iter(self.__values)

    def __len__(self) -> int:
        return len(self.__values)

    def __deepcopy__(self, memo: dict[int, object]) -> _ImmutableArtifacts:
        memo[id(self)] = self
        return self

    def __setattr__(self, name: str, value: object) -> None:
        del name, value
        raise TypeError("receipt artifact evidence is immutable")


@dataclass(frozen=True)
class ApprovalReceipt:
    reviewed_fingerprint_sha256: str
    slot: int
    spacing_offset: int
    thumbnail_sha256: str
    reviewed_lookup_row: int
    reviewed_native_origin: int
    review_reasons: tuple[str, ...]

    def __post_init__(self) -> None:
        if re.fullmatch(r"[0-9a-f]{64}", self.reviewed_fingerprint_sha256) is None:
            raise ValueError("manual approval fingerprint identity is invalid")
        if type(self.slot) is not int or not 1 <= self.slot <= 40:
            raise ValueError("manual approval slot must be in 1..40")
        minimum_offset = 0 if self.slot == 1 else -144
        if type(self.spacing_offset) is not int or not (
            minimum_offset <= self.spacing_offset <= 144
        ):
            raise ValueError("manual approval spacing offset is invalid")
        if re.fullmatch(r"[0-9a-f]{64}", self.thumbnail_sha256) is None:
            raise ValueError("manual approval thumbnail identity is invalid")
        if type(self.reviewed_lookup_row) is not int or self.reviewed_lookup_row < 0:
            raise ValueError("manual approval lookup row is invalid")
        if (
            type(self.reviewed_native_origin) is not int
            or self.reviewed_native_origin < 0
        ):
            raise ValueError("manual approval native origin is invalid")
        if (
            not isinstance(self.review_reasons, tuple)
            or not self.review_reasons
            or any(
                type(reason) is not str or not reason for reason in self.review_reasons
            )
        ):
            raise ValueError("manual approval requires explicit review reasons")

    @property
    def binding_sha256(self) -> str:
        """Recompute the exact ManualFrameApproval v1 content binding."""

        payload = {
            "boundary_offset_rows": self.spacing_offset,
            "review_reasons": list(self.review_reasons),
            "reviewed_fingerprint_sha256": self.reviewed_fingerprint_sha256,
            "reviewed_lookup_row": self.reviewed_lookup_row,
            "reviewed_native_origin": self.reviewed_native_origin,
            "schema_version": 1,
            "slot": self.slot,
            "thumbnail_sha256": self.thumbnail_sha256,
        }
        encoded = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True)
class Receipt:
    """One receipt per :class:`Frame`, entirely in-memory."""

    version: int
    slot: int
    spacing_offset: int
    dpi: int
    depth: int
    device_id: str
    device_model: str
    reviewed_fingerprint_sha256: str
    fresh_fingerprint_sha256: str
    manual_approval: ApprovalReceipt | None
    exposure: ExposureVector
    split_alignment: SplitAlignment | None
    clipping: ClippingTelemetry
    focus_detail: FocusDetailTelemetry
    transport_smear: TransportSmearAssessment
    artifacts: Mapping[str, ArtifactEvidence]
    # Mandatory (Sol adversarial review 2026-07-26, finding 2): the versioned
    # identifier for the numpy transform single_pass_workflow.py applied to
    # go from the scanner-native RGB/IR planes to this frame's stored
    # rgb/ir -- currently always DIGITAL_ICE_STORAGE_TRANSFORM, sourced
    # directly from this same frame's DigitalIceAcquisitionEvidence so the
    # value a downstream consumer sees can never drift from the value that
    # was actually used to build the native Digital ICE pair. Required (not
    # Optional/defaulted) so a caller cannot construct a Receipt without
    # deciding it, and so JSON produced from old code that predates this
    # field is distinguishable from JSON that declares one: a missing key
    # after `dataclasses.asdict()`/round-trip is a loud TypeError, never a
    # silent None a reader could mistake for "no transform applied".
    storage_transform: str
    nikon_density_ownership: NikonDensityFrameOwnershipReceipt | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "artifacts", _ImmutableArtifacts(self.artifacts))
        if type(self.storage_transform) is not str or not self.storage_transform.strip():
            raise ValueError("receipt storage_transform must be a non-empty string")


@dataclass(frozen=True)
class Frame:
    slot: int
    rgb: np.ndarray
    ir: np.ndarray | None
    ir_validity: np.ndarray | None
    receipt: Receipt
    meter_rgbi: np.ndarray | None = None
    nikon_density_evidence: NikonDensityEvidence | None = None
    nikon_exact_builder_evidence: NikonExactBuilderEvidence | None = None
    digital_ice_evidence: DigitalIceAcquisitionEvidence | None = None

    @property
    def nikon_density_ownership(self) -> NikonDensityFrameOwnershipReceipt | None:
        """Exact reservation-preview ownership carried by this frame receipt."""

        return self.receipt.nikon_density_ownership

    def __post_init__(self) -> None:
        digital_ice = self.digital_ice_evidence
        if digital_ice is not None:
            if self.ir is None or self.ir_validity is None or self.meter_rgbi is None:
                raise ValueError(
                    "Digital ICE evidence requires RGB, IR, IR validity, and meter RGBI"
                )
            snapshots = (
                ("rgb", self.rgb, np.dtype("<u2")),
                ("ir", self.ir, np.dtype("<u2")),
                ("ir_validity", self.ir_validity, np.dtype(np.bool_)),
                ("meter_rgbi", self.meter_rgbi, np.dtype("<u2")),
            )
            for name, value, dtype in snapshots:
                snapshot = np.array(value, dtype=dtype, order="C", copy=True)
                snapshot.setflags(write=False)
                object.__setattr__(self, name, snapshot)
            if (
                self.slot != digital_ice.slot
                or getattr(self.receipt, "slot", None) != self.slot
            ):
                raise ValueError("Digital ICE evidence belongs to another slot")
            ownership = self.nikon_density_ownership
            if ownership is None:
                raise ValueError("Digital ICE evidence requires reservation ownership")
            if (
                getattr(ownership, "reservation_id", None) != digital_ice.reservation_id
                or getattr(ownership, "frame_capture_attempt_id", None)
                != digital_ice.capture_attempt_id
                or getattr(ownership, "selected_slot", self.slot) != self.slot
            ):
                raise ValueError(
                    "Digital ICE evidence belongs to another reservation or capture"
                )
            rebuilt = build_digital_ice_acquisition_evidence(
                slot=self.slot,
                reservation_id=digital_ice.reservation_id,
                capture_attempt_id=digital_ice.capture_attempt_id,
                storage_rgb=self.rgb,
                storage_ir=self.ir,
                storage_ir_validity=self.ir_validity,
                meter_rgbi=self.meter_rgbi,
            )
            if rebuilt != digital_ice:
                raise ValueError("Digital ICE frame arrays do not match their evidence")
        ownership = self.nikon_density_ownership
        evidence = self.nikon_density_evidence
        if (ownership is None) != (evidence is None):
            raise ValueError(
                "Nikon density evidence and frame ownership must be present together"
            )
        if ownership is not None and evidence is not None:
            ownership.validate_evidence(evidence)
        builder = self.nikon_exact_builder_evidence
        if builder is not None:
            if ownership is None or evidence is None:
                raise ValueError(
                    "Nikon exact builder evidence requires density evidence and "
                    "frame ownership"
                )
            builder.validate_bindings(evidence, ownership)
            if builder.slot != self.slot:
                raise ValueError("Nikon exact builder evidence belongs to another slot")

    def prepare_digital_ice(self) -> DigitalIceAcquisition:
        """Revalidate and expose the scanner-native pair for one repair call."""

        evidence = self.digital_ice_evidence
        if evidence is None:
            raise ValueError("frame has no bound Digital ICE acquisition evidence")
        if self.ir is None or self.ir_validity is None or self.meter_rgbi is None:
            raise ValueError("frame no longer carries complete Digital ICE inputs")
        rebuilt = build_digital_ice_acquisition_evidence(
            slot=self.slot,
            reservation_id=evidence.reservation_id,
            capture_attempt_id=evidence.capture_attempt_id,
            storage_rgb=self.rgb,
            storage_ir=self.ir,
            storage_ir_validity=self.ir_validity,
            meter_rgbi=self.meter_rgbi,
        )
        if rebuilt != evidence:
            raise ValueError("Digital ICE inputs changed after capture")
        main = _scanner_native_main_rgbi(self.rgb, self.ir)
        validity = _scanner_native_ir_validity(self.ir_validity)
        meter = np.array(self.meter_rgbi, dtype="<u2", order="C", copy=True)
        for array in (main, validity, meter):
            array.setflags(write=False)
        return DigitalIceAcquisition(
            acquisition_id=evidence.acquisition_id,
            slot=evidence.slot,
            reservation_id=evidence.reservation_id,
            capture_attempt_id=evidence.capture_attempt_id,
            storage_transform=evidence.storage_transform,
            evidence_sha256=evidence.sha256,
            main_rgbi_sha256=evidence.scanner_native_main_rgbi.sha256,
            meter_rgbi_sha256=evidence.scanner_native_meter_rgbi.sha256,
            ir_validity_sha256=evidence.scanner_native_ir_validity.sha256,
            main_rgbi=main,
            meter_rgbi=meter,
            ir_validity=validity,
        )
