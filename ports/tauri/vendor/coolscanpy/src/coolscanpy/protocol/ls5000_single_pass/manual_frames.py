"""Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): driver-side manual frame
placement for the LS-5000 whole-roll pipeline.

This module never runs film movement and never re-derives detection with
relaxed knobs.  It accepts an already-decoded whole-roll preview raster (from
a preview attempt that has already completed and released the device) plus
the boundary rows a human picked by looking at that raster, and turns those
picks into the same ``RollDetection``/``TransportMapping`` shape the
automatic detector in ``roll_index.py`` produces -- so every downstream
consumer (``preview_session.py``, the worker's live-scan binding, the app's
thumbnail/approval UI) keeps working unchanged.

Trust model (binding, from the overnight doc): the human supplies frame
positions; this module keeps every physical sanity check the scanner can
still make from its own evidence -- clear-film transmission near the picked
rows (snap assist only; never a hard requirement) and the same-traversal
transport table's local physical-motion consistency (a hard requirement).
A placement that fails any hard check is refused in its entirety: this
module never returns a result that accepted some picks and silently
dropped others.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

import numpy as np

from .roll_index import (
    FrameInterval,
    GapBoundary,
    IncompleteIndexError,
    IndexDecodeError,
    NativeFrameOrigin,
    RollDetection,
    TransportMapping,
    TransportRecord,
    _active_aperture,
    _physical_gap_evidence,
    _true_runs,
    terminal_transport_tail_start,
)

# RollDetection.warnings marker: the one thing worker.py's live-scan gate
# checks to recognize a manually-placed roll. Only this module ever sets it;
# the automatic detector in roll_index.py never does. See worker.py's
# _derive_live_frame_selection for the one gate path this marker unlocks.
MANUAL_PLACEMENT_WARNING = "user-picked-frames"

# review_reasons markers.
USER_PICKED_REVIEW_REASON = "user-picked"
SNAP_REVIEW_REASON = "snapped-to-clear-film-edge"
MANUAL_ORIGIN_REVIEW_REASON = "user-picked-origin"

# NativeFrameOrigin.method for every manually placed frame.
MANUAL_ORIGIN_METHOD = "user-picked-row"

# RollDetection.count_confirmation / count_confidence for manual placements.
MANUAL_COUNT_CONFIRMATION = "user-picked-boundaries"
MANUAL_COUNT_CONFIDENCE = "user-selection-required"

# Structural limits (FEEDING-UX-LADDER-OVERNIGHT-20260807.md, Rung 4 point 1).
MINIMUM_MANUAL_BOUNDARY_COUNT = 2
MAXIMUM_MANUAL_FRAMES = 40

# Physical frame-height gate (Rung 4 point 2): 15-75 mm, deliberately wider
# than automatic detection's fixed nominal-pitch tolerance band because
# manual mode exists specifically for film automatic detection does not
# handle -- half-frame (~19 mm) and panoramic (~65-72 mm). 0.267 mm/row is
# this driver's documented 97-dpi-preview approximation (matches the ~5.3 mm
# / 20 rows figure already used for WIDE_GAP_CEILING_ROWS in roll_index.py
# and the ~0.8 mm / 3 rows figure in the Rung 3 diagnosis spec); it is used
# only to phrase user-facing sentences in mm. The row bounds below are the
# actual gate.
MINIMUM_MANUAL_FRAME_HEIGHT_ROWS = 56
MAXIMUM_MANUAL_FRAME_HEIGHT_ROWS = 280
MANUAL_FRAME_HEIGHT_MM_PER_ROW = 0.267

# Snap assist (Rung 4 point 3).
SNAP_ASSIST_MAX_DISTANCE_ROWS = 4

# Transport sanity (Rung 4 points 4-5): same 40..45 native-units-per-row
# scale as roll_index.derive_transport_mapping's own minimum_scale/
# maximum_scale defaults, and the same per-step local-ramp guard shape as
# derive_transport_mapping's wide-gap-anchor admission check (grep
# ramp_is_affine in roll_index.py) -- reimplemented here rather than
# imported because manual mode's origins are exact same-traversal table
# reads, never an affine fit prediction, so derive_transport_mapping itself
# is not called (it requires >=3 "direct"-support boundaries, which no
# user-picked boundary ever carries).
MINIMUM_TRANSPORT_SCALE = 40.0
MAXIMUM_TRANSPORT_SCALE = 45.0
RAMP_GUARD_RADIUS_ROWS = 3


@dataclass(frozen=True)
class BoundarySnap:
    """One snap-assist adjustment applied to a user-picked boundary row."""

    boundary_index: int
    requested_row: int
    snapped_row: int
    evidence_run: tuple[int, int]


@dataclass(frozen=True)
class ManualFrameDetection:
    """A manual placement's detection, transport mapping, and snap notes."""

    detection: RollDetection
    mapping: TransportMapping
    snaps: tuple[BoundarySnap, ...]


def _ordinal(n: int) -> str:
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def _approximate_mm(row: int) -> float:
    return row * MANUAL_FRAME_HEIGHT_MM_PER_ROW


def build_manual_detection(
    rgb16: np.ndarray,
    known: np.ndarray,
    boundary_rows: Sequence[int],
    *,
    nominal_frame_rows: int,
    records: Sequence[TransportRecord],
    snap_assist: bool = True,
) -> ManualFrameDetection:
    """Turn operator-picked boundary rows into a reviewed roll detection.

    ``rgb16``/``known`` are the same decoded whole-roll raster and
    completeness mask ``detect_roll_frames`` takes; ``records`` is the same
    same-traversal live READ(0x8e) transport table used everywhere else in
    this package. No film moves and no relaxed automatic-detection knobs are
    tried here -- this is a completely separate code path from
    ``detect_roll_frames``/``derive_transport_mapping``.

    Every gate below fails closed: any failure raises before this function
    returns anything, so a caller can never end up with a placement that
    silently accepted some of the operator's picks and dropped others.
    """

    # ---- gate 0: same shape/completeness floor as the automatic detector --
    if rgb16.ndim != 3 or rgb16.shape[2] != 3:
        raise IndexDecodeError("manual frame placement requires an HxWx3 RGB raster")
    if rgb16.shape != known.shape:
        raise IndexDecodeError("RGB raster and completeness mask shapes differ")
    complete_rows = known.all(axis=(1, 2))
    if complete_rows.mean() < 0.995:
        raise IncompleteIndexError(
            "manual frame placement requires a persisted complete preview; "
            f"row coverage is {complete_rows.mean():.1%}"
        )
    if (
        type(nominal_frame_rows) is not int
        or isinstance(nominal_frame_rows, bool)
        or nominal_frame_rows < 1
    ):
        raise IndexDecodeError("nominal frame rows must be a positive integer")

    # ---- gate 1: structure -- count, type, order, in-raster ---------------
    height = int(rgb16.shape[0])
    rows = list(boundary_rows)
    if len(rows) < MINIMUM_MANUAL_BOUNDARY_COUNT:
        raise IndexDecodeError(
            "manual frame placement needs at least 2 boundary rows (1 frame); "
            f"only {len(rows)} were given"
        )
    if any(type(row) is not int or isinstance(row, bool) for row in rows):
        raise IndexDecodeError("manual frame boundary rows must be plain integers")
    if any(a >= b for a, b in zip(rows, rows[1:])):
        raise IndexDecodeError(
            "frame boundary rows must be placed in strictly increasing order, "
            "top to bottom of the preview"
        )
    if any(not 0 <= row < height for row in rows):
        raise IndexDecodeError(
            "every boundary row must lie inside the captured preview "
            f"(0..{height - 1}); a boundary was placed outside it"
        )
    frame_count = len(rows) - 1
    if frame_count > MAXIMUM_MANUAL_FRAMES:
        raise IndexDecodeError(
            f"manual placement supports at most {MAXIMUM_MANUAL_FRAMES} frames; "
            f"{len(rows)} boundary rows would create {frame_count}"
        )

    # ---- gate 2: physical frame-height range, on the operator's own picks -
    for index, (start, end) in enumerate(zip(rows, rows[1:]), start=1):
        height_rows = end - start
        if not (
            MINIMUM_MANUAL_FRAME_HEIGHT_ROWS
            <= height_rows
            <= MAXIMUM_MANUAL_FRAME_HEIGHT_ROWS
        ):
            approx_mm = _approximate_mm(height_rows)
            raise IndexDecodeError(
                f"the {_ordinal(index)} frame you placed is about "
                f"{approx_mm:.0f} mm tall (between rows {start} and {end}), "
                "outside the 15-75 mm range this driver accepts for manual "
                "placement"
            )

    # ---- gate 3: snap assist (default on, never a hard requirement) -------
    # Reuses roll_index's own clear-film evidence signal so a "clear film
    # edge" means the exact same physical thing here as it does to the
    # automatic detector and the Rung 3 diagnosis module. If this raster
    # defeats that heuristic (e.g. an aperture shape automatic detection
    # itself would have refused), snap assist degrades to a no-op instead of
    # refusing the placement -- unlike every gate above and below, snapping
    # is a nicety layered on top of the operator's own judgement, not a
    # physical sanity check, and manual mode exists precisely for rasters
    # this heuristic cannot always read.
    evidence_signal: np.ndarray | None = None
    transmission_signal: np.ndarray | None = None
    nonuniformity_signal: np.ndarray | None = None
    aperture: tuple[int, int] | None = None
    evidence_runs: list[tuple[int, int]] = []
    try:
        aperture = _active_aperture(rgb16)
        evidence_signal, transmission_signal, nonuniformity_signal, direct = (
            _physical_gap_evidence(rgb16, aperture)
        )
        evidence_runs = _true_runs(direct)
    except IndexDecodeError:
        aperture = None
        evidence_signal = None
        transmission_signal = None
        nonuniformity_signal = None
        evidence_runs = []

    final_rows: list[int] = []
    supporting_runs: list[tuple[int, int] | None] = []
    snaps: list[BoundarySnap] = []
    for index, row in enumerate(rows):
        nearest_edge: int | None = None
        nearest_run: tuple[int, int] | None = None
        nearest_distance = SNAP_ASSIST_MAX_DISTANCE_ROWS + 1
        if snap_assist:
            # Same reference points as roll_index._nearest_evidence_run: a
            # row already inside a run is a perfect (zero-distance) match --
            # it needs no snap, and in particular a pick already centered on
            # a clear-film run must NOT get pulled to that run's start/end
            # sides just because they happen to be the closer numbers.
            # Outside a run, distance is to the nearer of the run's own
            # first/last clear-film row (never past it).
            for start, end in evidence_runs:
                if start <= row < end:
                    distance, edge = 0, row
                else:
                    distance_to_start = abs(row - start)
                    distance_to_last = abs(row - (end - 1))
                    if distance_to_start <= distance_to_last:
                        distance, edge = distance_to_start, start
                    else:
                        distance, edge = distance_to_last, end - 1
                if distance < nearest_distance:
                    nearest_distance = distance
                    nearest_edge = edge
                    nearest_run = (start, end)
        if nearest_run is not None and nearest_distance <= SNAP_ASSIST_MAX_DISTANCE_ROWS:
            supporting_runs.append(nearest_run)
            final_rows.append(nearest_edge)  # type: ignore[arg-type]
            if nearest_edge != row:
                snaps.append(
                    BoundarySnap(
                        boundary_index=index,
                        requested_row=row,
                        snapped_row=nearest_edge,  # type: ignore[arg-type]
                        evidence_run=nearest_run,
                    )
                )
        else:
            supporting_runs.append(None)
            final_rows.append(row)

    # Snapping moves each boundary independently by at most
    # SNAP_ASSIST_MAX_DISTANCE_ROWS; re-verify order and raster bounds still
    # hold on the (small number of) final rows before trusting them for
    # anything downstream. Practically unreachable given the height gate
    # above already ran on the raw picks, but cheap, correct, and this
    # module never trusts an unchecked value just because a similar one was
    # already checked.
    if any(a >= b for a, b in zip(final_rows, final_rows[1:])):
        raise IndexDecodeError(
            "snap assist moved two placed boundaries out of order; place "
            "them farther apart, or place them by hand with snap assist off"
        )
    if any(not 0 <= row < height for row in final_rows):
        raise IndexDecodeError(
            "snap assist moved a boundary outside the captured preview "
            f"(0..{height - 1})"
        )

    # ---- gate 4: per-boundary local transport-ramp guard -------------------
    # Same guard shape as derive_transport_mapping's wide-gap-anchor
    # admission check (grep ramp_is_affine in roll_index.py), applied
    # uniformly to every picked boundary -- manual mode has no separate
    # "leading anchor" tolerance the way the automatic path does, because
    # nothing here is inferred from an affine fit; every origin is a direct
    # table read, and a direct table read next to an untrustworthy ramp is
    # exactly the case this guard exists to catch.
    if len(records) < 1:
        raise IndexDecodeError(
            "manual frame placement requires the same-traversal scanner "
            "position table; none was supplied"
        )
    tail_start = terminal_transport_tail_start(records)
    ramp_upper_bound = (
        len(records) - 1 if tail_start is None else min(len(records) - 1, tail_start - 1)
    )
    for index, row in enumerate(final_rows):
        if not 0 <= row < len(records):
            raise IndexDecodeError(
                f"the {_ordinal(index + 1)} frame edge you placed (row {row}) "
                "has no matching entry in the scanner's position table; try "
                "refeeding the strip and re-scanning the preview"
            )
        lo = max(0, row - RAMP_GUARD_RADIUS_ROWS)
        hi = min(ramp_upper_bound, row + RAMP_GUARD_RADIUS_ROWS)
        steps_ok = hi > lo and all(
            MINIMUM_TRANSPORT_SCALE
            <= records[r + 1].native_origin - records[r].native_origin
            <= MAXIMUM_TRANSPORT_SCALE
            for r in range(lo, hi)
        )
        if not steps_ok:
            raise IndexDecodeError(
                "the scanner's position readings look unreliable around the "
                f"{_ordinal(index + 1)} frame edge you placed (approximately "
                f"{_approximate_mm(row):.0f} mm into the roll); try refeeding "
                "the strip and re-scanning the preview"
            )

    # ---- gate 5: origins strictly increasing at 40..45 units/row ----------
    picked_origins = [records[row].native_origin for row in final_rows]
    for index, (row_a, row_b, origin_a, origin_b) in enumerate(
        zip(final_rows, final_rows[1:], picked_origins, picked_origins[1:]),
        start=1,
    ):
        delta_rows = row_b - row_a
        delta_origin = origin_b - origin_a
        implied_scale = delta_origin / delta_rows if delta_rows else 0.0
        if not (
            delta_origin > 0
            and MINIMUM_TRANSPORT_SCALE <= implied_scale <= MAXIMUM_TRANSPORT_SCALE
        ):
            raise IndexDecodeError(
                "the scanner's position readings between the "
                f"{_ordinal(index)} and {_ordinal(index + 1)} frame edges you "
                f"placed don't move at a steady rate (about "
                f"{implied_scale:.1f} position units per row; this driver "
                "expects roughly 40-45); try refeeding the strip and "
                "re-scanning the preview"
            )

    # ---- build the result in the shared roll_index shapes ------------------
    def boundary_reading(row: int) -> tuple[float, float, float]:
        if evidence_signal is None:
            return 0.0, 0.0, 1.0
        return (
            float(evidence_signal[row]),
            float(transmission_signal[row]),  # type: ignore[index]
            float(nonuniformity_signal[row]),  # type: ignore[index]
        )

    snapped_indices = {snap.boundary_index for snap in snaps}
    boundaries: list[GapBoundary] = []
    for index, row in enumerate(final_rows):
        ev, tm, nu = boundary_reading(row)
        reasons = [USER_PICKED_REVIEW_REASON]
        if index in snapped_indices:
            reasons.append(SNAP_REVIEW_REASON)
        boundaries.append(
            GapBoundary(
                index=index,
                output_row=row,
                fitted_row=float(row),
                evidence=ev,
                transmission=tm,
                nonuniformity=nu,
                support="user-picked",
                evidence_run=supporting_runs[index],
                manual_review=True,
                review_reasons=tuple(reasons),
            )
        )

    intervals: list[FrameInterval] = []
    for frame_index, (start_boundary, end_boundary) in enumerate(
        zip(boundaries, boundaries[1:]), start=1
    ):
        intervals.append(
            FrameInterval(
                frame=frame_index,
                start_row=start_boundary.output_row,
                end_row=end_boundary.output_row,
                height_rows=end_boundary.output_row - start_boundary.output_row,
                start_boundary=start_boundary.index,
                end_boundary=end_boundary.index,
                # Manual mode's whole premise is that the operator's own
                # visual judgement substitutes for the content heuristic the
                # automatic detector uses, so both fractions are reported as
                # fully trusted. coverage_fraction=1.0 is also the honest
                # value: gate 1 above already proved every boundary lies
                # inside the captured raster, so no manual frame can ever be
                # a raster-edge partial the way an automatic detection can.
                content_fraction=1.0,
                coverage_fraction=1.0,
                count_supported=True,
                count_bridged=False,
                manual_review=True,
                review_reasons=(USER_PICKED_REVIEW_REASON,),
                unclamped_start_row=float(start_boundary.output_row),
                unclamped_end_row=float(end_boundary.output_row),
            )
        )

    origins: list[NativeFrameOrigin] = []
    for frame_index, start_boundary in enumerate(boundaries[:-1], start=1):
        record = records[start_boundary.output_row]
        origins.append(
            NativeFrameOrigin(
                frame=frame_index,
                boundary_index=start_boundary.index,
                boundary_output_row=start_boundary.output_row,
                lookup_row=start_boundary.output_row,
                code=record.code,
                selector=record.selector,
                native_origin=record.native_origin,
                method=MANUAL_ORIGIN_METHOD,
                automatic=False,
                manual_review=True,
                review_reasons=(MANUAL_ORIGIN_REVIEW_REASON,),
                # Exact same-traversal table read, not an affine-fit
                # prediction -- there is no fit error to report. Zero here
                # also keeps worker.py's _addressable_frame_origins residual
                # filter from ever excluding a manually placed frame; gate 4
                # above is this module's own, stricter physical check.
                affine_residual_rows=0.0,
            )
        )

    # Diagnostic-only affine summary across every picked boundary (not just
    # the frame-owning ones) -- purely for TransportMapping.diagnostics();
    # nothing above derives an origin from this fit.
    rows_arr = np.asarray([b.output_row for b in boundaries], dtype=np.float64)
    origin_arr = np.asarray(picked_origins, dtype=np.float64)
    design = np.column_stack((np.ones(len(rows_arr)), rows_arr))
    intercept, scale = np.linalg.lstsq(design, origin_arr, rcond=None)[0]
    if scale:
        residual_rows = (design @ np.asarray((intercept, scale)) - origin_arr) / scale
        anchor_mae = float(np.mean(np.abs(residual_rows)))
        anchor_max = float(np.max(np.abs(residual_rows)))
    else:  # pragma: no cover - unreachable once gate 5 has passed
        anchor_mae = 0.0
        anchor_max = 0.0

    mapping = TransportMapping(
        record_count=len(records),
        native_intercept=float(intercept),
        native_units_per_preview_row=float(scale),
        anchor_mae_rows=anchor_mae,
        anchor_max_error_rows=anchor_max,
        origins=tuple(origins),
    )

    evidences = [b.evidence for b in boundaries]
    detection = RollDetection(
        aperture_columns=aperture if aperture is not None else (0, int(rgb16.shape[1])),
        nominal_frame_rows=nominal_frame_rows,
        # No autocorrelation/lattice fit is ever run for a manual placement;
        # these carry neutral values rather than fabricated ones.
        autocorrelation_lag=0,
        autocorrelation_peak=0.0,
        autocorrelation_best_non_neighbor=0.0,
        pitch_rows=float(np.mean([end - start for start, end in zip(final_rows, final_rows[1:])])),
        phase_rows=0.0,
        lattice_score=0.0,
        alternative_lattice_score=0.0,
        lattice_margin_fraction=0.0,
        mean_boundary_evidence=float(np.mean(evidences)),
        minimum_boundary_evidence=float(np.min(evidences)),
        content_level_threshold=0.0,
        content_range_threshold=0.0,
        candidate_cell_count=frame_count,
        bridged_cell_count=0,
        expected_frame_count=None,
        expected_frame_count_matches=None,
        count_confirmation=MANUAL_COUNT_CONFIRMATION,
        count_confidence=MANUAL_COUNT_CONFIDENCE,
        content_end_candidates=(),
        # Never higher than "medium": a human placed these rows, but nothing
        # here re-derives or double-checks that placement against scene
        # content or an independent lattice fit the way "high" requires
        # elsewhere in this package.
        confidence="medium",
        warnings=(MANUAL_PLACEMENT_WARNING,),
        boundaries=tuple(boundaries),
        intervals=tuple(intervals),
        manual_review_frames=tuple(range(1, frame_count + 1)),
    )

    return ManualFrameDetection(
        detection=detection,
        mapping=mapping,
        snaps=tuple(snaps),
    )


__all__ = [
    "BoundarySnap",
    "MANUAL_PLACEMENT_WARNING",
    "ManualFrameDetection",
    "build_manual_detection",
]
