from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import numpy as np

from coolscanpy.session.params import ScannerCaptureState


@dataclass(frozen=True)
class SplitIrAlignment:
    """Measured transform + confidence for a split RGB/IR Coolscan capture.

    ``mode`` is "identity" when the registration proxy was byte-identical to
    the multisampled RGB, "phase-ecc" when both estimators corroborated the
    translation, "phase-only" for the strict near-zero three-channel phase
    fallback used when ECC finds a conflicting local optimum, or
    "tiled-phase" for the legacy single-scale periodic fallback,
    "multiscale-global" for a short-wide global consensus, or
    "multiscale-tiled" when a periodic global alias is rejected by stable
    local evidence at two resolutions. Confidence fields are None only in
    identity mode. New multiscale fields default empty so historical source
    checkpoints remain readable.
    """

    mode: str
    dx_px: float
    dy_px: float
    phase_responses: tuple[float, ...] = ()
    channel_spread_px: float | None = None
    ecc_coefficient: float | None = None
    tile_support_counts: tuple[int, ...] = ()
    tile_shift_spread_px: float | None = None
    estimator_version: int | None = None
    multiscale_max_dimensions: tuple[int, ...] = ()
    multiscale_channel_shifts_px: tuple[tuple[tuple[float, float], ...], ...] = ()
    multiscale_responses: tuple[tuple[float, ...], ...] = ()
    multiscale_tile_support_counts: tuple[tuple[int, ...], ...] = ()
    multiscale_tile_shift_spreads_px: tuple[tuple[float, ...], ...] = ()
    multiscale_global_alias_shifts_px: tuple[tuple[tuple[float, float], ...], ...] = ()


def multiscale_alignment_fields(payload: Mapping[str, Any]) -> dict[str, Any]:
    """Convert the six multiscale_* JSON arrays back to SplitIrAlignment tuples.

    Shared by every site that re-hydrates a ``SplitIrAlignment`` from parsed
    JSON (fine-QC sidecar validation, checkpoint reload): the six fields
    below are identical shapes/conversions at each call site, unlike the
    scalar fields, which differ slightly in how they coerce and stay inline.
    """

    return {
        "multiscale_max_dimensions": tuple(
            int(value) for value in payload.get("multiscale_max_dimensions", ())
        ),
        "multiscale_channel_shifts_px": tuple(
            tuple((float(pair[0]), float(pair[1])) for pair in scale)
            for scale in payload.get("multiscale_channel_shifts_px", ())
        ),
        "multiscale_responses": tuple(
            tuple(float(value) for value in scale)
            for scale in payload.get("multiscale_responses", ())
        ),
        "multiscale_tile_support_counts": tuple(
            tuple(int(value) for value in scale)
            for scale in payload.get("multiscale_tile_support_counts", ())
        ),
        "multiscale_tile_shift_spreads_px": tuple(
            tuple(float(value) for value in scale)
            for scale in payload.get("multiscale_tile_shift_spreads_px", ())
        ),
        "multiscale_global_alias_shifts_px": tuple(
            tuple((float(pair[0]), float(pair[1])) for pair in scale)
            for scale in payload.get("multiscale_global_alias_shifts_px", ())
        ),
    }


@dataclass(frozen=True)
class SplitSourceCapture:
    """Unmodified arrays returned by the legacy two-transfer SANE reservation."""

    rgb4x: np.ndarray
    rgb1x_proxy: np.ndarray
    ir1x: np.ndarray


@dataclass(frozen=True)
class ScanResult:
    rgb: np.ndarray
    ir: np.ndarray | None
    dpi: int
    device_model: str
    # Present only for split Coolscan RGB+IR captures: how IR was registered
    # to the multisampled RGB, with the measured confidence that acceptance
    # tooling must be able to audit.
    ir_alignment: SplitIrAlignment | None = None
    # True where the IR sample comes from the scanner.  Split captures keep
    # the complete RGB canvas and mark warp/tail borders false instead of
    # cropping real photograph or letting zero-fill masquerade as dust.
    ir_valid_mask: np.ndarray | None = None
    # Replayable focus/exposure values actually used by the scanner.  A second
    # adjacent source window consumes this state with AF/AE disabled.
    capture_state: ScannerCaptureState | None = None
    split_source: SplitSourceCapture | None = None
