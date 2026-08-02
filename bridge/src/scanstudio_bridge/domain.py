"""Typed bridge wire vocabulary: one frozen dataclass per type in BRIDGE.md's
Types section (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md), field-for-field. Python fields are
snake_case; `protocol.to_wire`/`from_wire` convert mechanically to/from
BRIDGE.md's camelCase wire names, with one documented exception:
`DeviceInfo.device_id` renames CoolscanPy's own `DeviceInfo.id`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from enum import StrEnum

from scanstudio_bridge.protocol import BridgeError, ErrorCode, to_camel_case

__all__ = [
    "Material",
    "Channels",
    "Capabilities",
    "DeviceInfo",
    "DeviceStatus",
    "CaptureRecipe",
    "OutputSpec",
    "SlotOutputSpec",
    "Thumbnail",
    "ScanProgress",
    "ExposureVector",
    "ClippingTelemetry",
    "FocusDetailTelemetry",
    "TransportSmearAssessment",
    "ArtifactEvidence",
    "ApprovalReceipt",
    "ExposureAuthority",
    "ScanReceipt",
    "PreviewResult",
    "ScanSummary",
    "FIXED_COLOR_NEGATIVE_RECIPE",
    "DEBUG_RECIPE_ENV_VAR",
    "DEBUG_COLOR_NEGATIVE_RECIPE",
    "validate_capture_recipe",
]


class Material(StrEnum):
    COLOR_NEGATIVE = "colorNegative"
    BLACK_AND_WHITE_NEGATIVE = "blackAndWhiteNegative"


class Channels(StrEnum):
    RGB = "rgb"
    RGBI = "rgbi"


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
    supported_multisample_passes: tuple[int, ...]


@dataclass(frozen=True)
class DeviceInfo:
    device_id: str  # renames CoolscanPy's own DeviceInfo.id
    vendor: str
    model: str
    capabilities: Capabilities


@dataclass(frozen=True)
class DeviceStatus:
    connected: bool
    device_id: str | None
    preview_established: bool
    slot_count: int | None
    active_job_id: str | None
    lane_held: bool
    motion_armed: bool
    film_present: bool | None


@dataclass(frozen=True)
class CaptureRecipe:
    resolution_dpi: int
    bit_depth: int
    multisample_passes: int
    channels: Channels
    autofocus: bool
    auto_exposure: bool


@dataclass(frozen=True)
class SlotOutputSpec:
    destination: str
    filename_template: str


@dataclass(frozen=True)
class OutputSpec:
    destination: str
    filename_template: str
    # Optional decimal-slot -> template mapping. Absent preserves the
    # established one-template batch wire shape.
    slot_outputs: dict[str, SlotOutputSpec] | None = None


@dataclass(frozen=True)
class Thumbnail:
    slot: int
    boundary_rows: tuple[int, int]
    spacing_offset: int
    needs_approval: bool
    warnings: tuple[str, ...]
    image_path: str


@dataclass(frozen=True)
class ScanProgress:
    job_id: str
    slot: int
    ordinal: int
    total_slots: int
    fraction: float
    message: str


@dataclass(frozen=True)
class ExposureVector:
    focus_position: int
    exposure_multiplier: float
    red_exposure_us: float
    green_exposure_us: float
    blue_exposure_us: float


@dataclass(frozen=True)
class ClippingTelemetry:
    fractions: tuple[float, float, float]
    clip_level: float
    warning_fraction: float
    warning: bool


@dataclass(frozen=True)
class FocusDetailTelemetry:
    method: str
    verdict: str  # "measured" | "indeterminate"
    score: float | None
    texture_span: float


@dataclass(frozen=True)
class TransportSmearAssessment:
    verdict: str  # "clean" | "smear" | "indeterminate"
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
    sha256: str
    byte_length: int
    shape: tuple[int, ...]
    dtype: str


@dataclass(frozen=True)
class ApprovalReceipt:
    reviewed_fingerprint_sha256: str
    slot: int
    spacing_offset: int
    thumbnail_sha256: str
    reviewed_lookup_row: int
    reviewed_native_origin: int
    review_reasons: tuple[str, ...]


@dataclass(frozen=True)
class ExposureAuthority:
    """Verbatim hardware exposure provenance from CoolscanPy's journal."""

    rgb_source: str
    ir_source: str
    commanded_channels_raw_10ns: dict[str, int]
    active_controller_channels_raw_10ns: dict[str, int]
    device_bound_clamped_channels_raw_10ns: dict[str, int]
    device_exposure_bounds_raw_10ns: tuple[int, int]


@dataclass(frozen=True)
class ScanReceipt:
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
    # Always null for the one wired route: single-pass RGBI4 shares one
    # pass for RGB+IR, so CoolscanPy never populates a separate
    # registration record. Opaque/nullable rather than fully typed until a
    # route populates it -- see BRIDGE.md's Types section.
    split_alignment: object | None
    clipping: ClippingTelemetry
    focus_detail: FocusDetailTelemetry
    transport_smear: TransportSmearAssessment
    artifacts: dict[str, ArtifactEvidence]
    # Mandatory (Sol adversarial review 2026-07-26, finding 2), mirrored
    # verbatim from CoolscanPy's own Receipt.storage_transform -- the
    # versioned identifier for the numpy transform applied between the
    # scanner-native RGB/IR planes and this receipt's rgbPath/irPath. See
    # BRIDGE.md's ScanReceipt Types entry for the wire contract and the two
    # values a consumer may see.
    storage_transform: str
    rgb_path: str  # bridge-added: CoolscanPy's roll engine returns arrays, never files
    ir_path: str | None
    meter_rgbi_path: str | None
    # Optional, bridge-added provenance for the real transport: the exact
    # caller-owned CoolscanPy attempts root for this Roll/session.  Mock and
    # other routes without persistent CoolscanPy evidence report None.
    # Defaulted so existing in-process ScanReceipt construction and older
    # wire payloads remain compatible.
    attempts_root: str | None = None
    # Best-effort copy of CoolscanPy's active_exposure_authority journal
    # block. Defaulted for older persisted and in-process receipts.
    exposure_authority: ExposureAuthority | None = None


# --- internal (non-wire) types Plan 08-02 needs ---


@dataclass(frozen=True)
class PreviewResult:
    count: int
    fingerprint: str


@dataclass(frozen=True)
class ScanSummary:
    completed: tuple[int, ...]
    failed: tuple[int, ...]
    stopped: bool
    # Plan 10-09 (per-frame failure reasons, coordinator scope addition):
    # slot -> {"reason_class": str, "reason_message": str, "code": str} for
    # any slot in `failed` whose cause is already known when this
    # ScanSummary is constructed -- today populated only by
    # CoolscanPyTransport's ManualReviewRequired per-slot skip-and-continue
    # (start_scan never raises for it, so it would otherwise reach
    # service.py as a bare failed-slot number with zero diagnostic; see
    # coolscanpy_transport.py's start_scan). Defaulted to an empty dict so
    # every pre-existing `ScanSummary(completed=..., failed=...,
    # stopped=...)` call site (this codebase's own test suite included)
    # keeps working unchanged. Deliberately NOT included when this
    # ScanSummary crosses the wire (service.py builds `scan.completed`'s
    # `summary` payload by hand rather than via `to_wire(summary)`) --
    # BRIDGE.md's documented `{completed, failed, stopped}` shape is
    # unchanged; this field is consumed only internally, translated into
    # `scan.frameFailed` telemetry/wire events instead (see service.py).
    failure_reasons: dict[int, dict[str, str]] = field(default_factory=dict)


# The single wired material: "colorNegative" combination -- fixed by the
# LS-5000's single-pass protocol, not client-configurable. See BRIDGE.md's
# Recipe constraints section.
FIXED_COLOR_NEGATIVE_RECIPE = CaptureRecipe(
    resolution_dpi=4000,
    bit_depth=16,
    multisample_passes=4,
    channels=Channels.RGBI,
    autofocus=True,
    auto_exposure=True,
)

_FIXED_COLOR_NEGATIVE_FIELDS = (
    "resolution_dpi",
    "bit_depth",
    "multisample_passes",
    "channels",
    "autofocus",
    "auto_exposure",
)

# Plan 10-09: lab-only diagnostic override, env-gated. See
# `validate_capture_recipe`'s docstring and BRIDGE.md's Recipe constraints
# section for the full contract.
DEBUG_RECIPE_ENV_VAR = "SCANSTUDIO_BRIDGE_DEBUG_RECIPE"

# A fast, low-res, single-pass, no-IR recipe for bench diagnosis without
# waiting on a full 4000dpi/16-bit/4-pass/RGBI fine scan -- accepted ONLY in
# ADDITION to FIXED_COLOR_NEGATIVE_RECIPE above, and ONLY when
# DEBUG_RECIPE_ENV_VAR is exactly "1" (see `_debug_recipe_armed`).
# autofocus/auto_exposure are placeholders here: `_DEBUG_COLOR_NEGATIVE_FIELDS`
# deliberately excludes both from the match check below, since neither
# affects which diagnostic phase/failure this override exists to isolate --
# any bool value for either is accepted.
DEBUG_COLOR_NEGATIVE_RECIPE = CaptureRecipe(
    resolution_dpi=1000,
    bit_depth=8,
    multisample_passes=1,
    channels=Channels.RGB,
    autofocus=True,
    auto_exposure=True,
)

_DEBUG_COLOR_NEGATIVE_FIELDS = (
    "resolution_dpi",
    "bit_depth",
    "multisample_passes",
    "channels",
)


def _debug_recipe_armed() -> bool:
    """Live re-check, never cached -- mirrors safety.armed_media's own
    read-fresh-every-call convention. `True` only when
    DEBUG_RECIPE_ENV_VAR is exactly `"1"`."""
    return os.environ.get(DEBUG_RECIPE_ENV_VAR) == "1"


def _matches_debug_color_negative_recipe(recipe: CaptureRecipe) -> bool:
    return all(
        getattr(recipe, field_name) == getattr(DEBUG_COLOR_NEGATIVE_RECIPE, field_name)
        for field_name in _DEBUG_COLOR_NEGATIVE_FIELDS
    )


def validate_capture_recipe(recipe: CaptureRecipe, material: Material) -> None:
    """Raise `BridgeError` when `recipe` doesn't satisfy BRIDGE.md's Recipe
    constraints for `material`; return `None` when it does.

    Plan 10-09 debug-recipe gate: when env `SCANSTUDIO_BRIDGE_DEBUG_RECIPE`
    is exactly `"1"`, a `material=colorNegative` recipe ALSO validates
    successfully against `DEBUG_COLOR_NEGATIVE_RECIPE` (every field except
    `autofocus`/`autoExposure`, which are unconstrained under this
    override). This is purely additive and lab-only: `FIXED_COLOR_NEGATIVE_RECIPE`
    is still accepted whether or not the env var is set, and the env check
    is short-circuited before any recipe comparison runs, so behavior with
    the env unset (or set to anything other than exactly `"1"`) is
    byte-identical to before this override existed."""
    if material is Material.BLACK_AND_WHITE_NEGATIVE:
        raise BridgeError(
            ErrorCode.NOT_IMPLEMENTED,
            "fine scanning material=blackAndWhiteNegative is not implemented",
        )
    if material is Material.COLOR_NEGATIVE:
        if _debug_recipe_armed() and _matches_debug_color_negative_recipe(recipe):
            return None
        for field_name in _FIXED_COLOR_NEGATIVE_FIELDS:
            expected = getattr(FIXED_COLOR_NEGATIVE_RECIPE, field_name)
            actual = getattr(recipe, field_name)
            if actual != expected:
                wire_field = to_camel_case(field_name)
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"recipe.{wire_field} must be {expected!r} for "
                    f"material=colorNegative, got {actual!r}",
                )
        return None
    raise BridgeError(ErrorCode.INVALID_PARAMS, f"unknown material: {material!r}")
