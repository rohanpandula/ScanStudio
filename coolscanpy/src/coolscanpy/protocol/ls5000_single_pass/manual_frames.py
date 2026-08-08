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

Trust model (rewritten 2026-08-08 after adversarial review rejected the
original): the human supplies frame positions; this module keeps every
physical sanity check the scanner can still make from its own evidence --
clear-film transmission near the picked rows (snap assist only; never a hard
requirement) and the same-traversal transport table's local physical-motion
consistency (a hard requirement).  A placement that fails any hard check is
refused in its entirety: this module never returns a result that accepted
some picks and silently dropped others.

The transport-table check used to mean "every single-row step within 3 rows
of a pick must be 40..45 native units."  Real LS-5000 live READ(0x8e) tables
never satisfy that: they carry a deterministic ~18-row code lattice (see
``transport_native_origin`` in roll_index.py) whose per-row steps are mostly
an exact, steady rate but include a recurring minority of large single-row
jumps at selector rollovers (roughly +798/-700 native units) and smaller
jumps at sub-rollovers (the code's high byte advancing alone), averaging
back out to the steady rate over any run of a dozen-plus rows.  A ±3-row
window is on the wrong side of that: it is wide enough to *catch* a rollover
row but too narrow to *outvote* it, so it refused nearly every real capture
at the very first edge with a message ("try refeeding the strip") that could
not have been fixed by refeeding, because nothing was wrong with the strip.

The fix is the same class of machinery ``roll_index.derive_transport_mapping``
already uses for the automatic path: resolve each pick's origin from a local
affine fit over nearby table records -- robust to that lattice's own minority
of outlier rows -- rather than trusting one raw row read.  See
``_resolve_boundary_transport_origin`` for exactly how, and why it mirrors
two different ``derive_transport_mapping`` conventions depending on whether a
narrow, specific clear-film run backs the pick.  ``derive_transport_mapping``
itself is still never called: it requires >=3 "direct"-support boundaries
classified from automatic detection's own lattice fit, which no user-picked
boundary ever carries, and it owns the automatic path's exact behavior,
which nothing in this rework may change.
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
    MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS,
    NativeFrameOrigin,
    RollDetection,
    TransportMapping,
    TransportRecord,
    TRANSPORT_ORIGIN_CLAMP_REASON,
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
# Set alongside MANUAL_ORIGIN_REVIEW_REASON when a boundary's origin came
# from the broad/weak-evidence forward search (_resolve_boundary_transport_
# origin's "not narrow_run" branch) rather than a specific nearby clear-film
# trailing edge -- the same string derive_transport_mapping's own
# affine-guided-local-lookup method appends, kept identical on purpose so a
# field report grepping for it finds both paths' inferred origins together.
INFERRED_ORIGIN_REVIEW_REASON = "transport-origin-inferred"

# NativeFrameOrigin.method for every manually placed frame.
MANUAL_ORIGIN_METHOD = "user-picked-row"

# RollDetection.count_confirmation / count_confidence for manual placements.
MANUAL_COUNT_CONFIRMATION = "user-picked-boundaries"
MANUAL_COUNT_CONFIDENCE = "user-selection-required"

# Structural limits (FEEDING-UX-LADDER-OVERNIGHT-20260807.md, Rung 4 point 1).
MINIMUM_MANUAL_BOUNDARY_COUNT = 2
MAXIMUM_MANUAL_FRAMES = 40

# Physical frame-height floor (Rung 4 point 2, unchanged by the rework):
# 15 mm (~56 preview rows) is a hard physical floor -- half-frame (~19 mm) is
# the shortest real film this driver supports manual placement for, and this
# stays comfortably under it. 0.267 mm/row is this driver's documented
# 97-dpi-preview approximation (matches the ~5.3 mm / 20 rows figure already
# used for WIDE_GAP_CEILING_ROWS in roll_index.py and the ~0.8 mm / 3 rows
# figure in the Rung 3 diagnosis spec); it is used only to phrase
# user-facing sentences in mm. The row bound below is the actual gate.
MINIMUM_MANUAL_FRAME_HEIGHT_ROWS = 56
MANUAL_FRAME_HEIGHT_MM_PER_ROW = 0.267

# Physical frame-height ceiling (F2 rework, replaces the old flat 75 mm / 280
# row ceiling). The LS-5000 fine scan captures a FIXED-size window starting
# at a frame's native transport origin -- FINE_NATIVE_HEIGHT in worker.py,
# 5,959 native units -- and there is no multi-window capture: a manually
# placed frame taller than that window cannot be captured by one fine scan.
# Accepting it here anyway (the old ceiling did, up to 75 mm) would deliver
# a silently truncated frame the first time it was actually scanned, well
# after the operator believed their placement was fine. worker.py cannot be
# imported here (worker.py imports THIS module), so this hardware constant
# is re-stated locally -- the same way it is already independently re-stated
# in packed.py, density.py, capture/full_negative.py,
# capture/sane_rgb_geometry.py, and roll/preview_session.py rather than
# shared from one place.
#
# In preview rows that fixed window is FINE_NATIVE_HEIGHT // geometry.pitch;
# geometry.pitch is fixed at 41 by the scanner's own validated native/preview
# resolution ratio (4,000 dpi native optical resolution over a ~97.6 dpi
# preview -- see worker.py's IndexGeometry construction, where "pitch != 41"
# is itself a hard validation failure), so 5,959 // 41 == 145 rows is a
# fixed hardware limit, not a per-capture estimate. This module receives
# nominal_frame_rows as a caller-supplied parameter that existing tests
# deliberately vary per synthetic scenario (it is otherwise only advisory,
# carried into RollDetection.nominal_frame_rows), so it cannot stand in for
# this fixed ceiling here.
#
# This kills the old 75 mm / panoramic acceptance: manual mode still exists
# for film automatic detection cannot handle, but panoramic is no longer
# one of those cases -- the fine window cannot hold it. Half-frame (short)
# placements are unaffected; only the ceiling moved.
FINE_CAPTURE_WINDOW_ROWS = 145
# Same unfloored ratio expressed in mm, purely for phrasing the refusal
# sentence -- ~38.8 mm. The row bound above is the actual gate.
FINE_CAPTURE_WINDOW_MM = (5_959 / 41) * MANUAL_FRAME_HEIGHT_MM_PER_ROW

# Snap assist (Rung 4 point 3, unchanged by the rework).
SNAP_ASSIST_MAX_DISTANCE_ROWS = 4

# Transport sanity (F1 rework): same 40..45 native-units-per-row scale as
# roll_index.derive_transport_mapping's own minimum_scale/maximum_scale
# defaults -- every fit below is gated at this same physical bound.
MINIMUM_TRANSPORT_SCALE = 40.0
MAXIMUM_TRANSPORT_SCALE = 45.0

# Local transport-fit window (F1): how many rows on each side of a pick's
# anchor row this module is willing to look at when deciding what "a steady
# rate near this pick" means. 25 rows (a 51-row window) comfortably spans
# more than two of the table's own ~18-row lattice periods, which matters
# for the median-based robust start (below) -- it needs the steady rate to
# be the majority of the window, and a window barely wider than one period
# leaves too few rows to reliably outvote that period's own 1-2 lattice
# jumps. Widening far past this stopped helping in practice (measured
# against 45 archived live captures during this rework: identical results
# from 40 rows out to 150) and risks pulling in a genuinely different local
# rate from farther down the roll, so this stays a LOCAL window, never the
# whole table.
LOCAL_FIT_WINDOW_RADIUS_ROWS = 25
# Below this many trusted rows in a window, a fit is not attempted -- there
# is not enough signal left to tell a steady rate from noise once the
# lattice's own jumps are set aside.
LOCAL_FIT_MINIMUM_INLIER_ROWS = 8
# A window row is trusted ("inlier") when it sits within this many rows of
# the fitted line; this is also the fit's own final acceptance bound (its
# worst trusted row can differ from the line by no more than this). Matches
# MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS, the automatic path's own interior
# residual bound, imported and reused directly below rather than
# re-declared, so the two paths cannot silently drift apart.
LOCAL_FIT_TRIM_RESIDUAL_ROWS = MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS
# Bounded outlier-trim/refit rounds: the lattice's steady-rate majority and
# its jump-row minority separate cleanly after one round in every archived
# capture measured during this rework; a few extra rounds are cheap
# insurance for a borderline window where a row migrates in or out as the
# fitted line settles, not evidence more rounds are routinely needed.
LOCAL_FIT_TRIM_ROUNDS = 4

# A clear-film run up to this many rows wide is "narrow": a specific,
# physically meaningful gap between two frames, the same class of evidence
# roll_index.derive_transport_mapping's "direct" method anchors on. Wider
# than this and a run stops meaning "this one boundary's own gap" -- it is
# more likely the leader, a broad low-contrast region, or several bridged
# boundaries sharing one detected run (observed on archived 39-frame-roll
# captures during this rework: three consecutive automatic boundaries all
# carrying the SAME ~300-row "cadence-broad" run). Reused conceptually from
# roll_index.WIDE_GAP_CEILING_ROWS's own narrow/wide split rather than
# imported, since that constant's own docstring ties it specifically to the
# wide-gap recovery pass, a different feature this module must not couple
# to.
NARROW_EVIDENCE_RUN_MAX_WIDTH_ROWS = 20
# When a pick has no narrow run to anchor on, how many rows past the pick
# this module searches for the table's own closest match to the local fit's
# prediction. Matches derive_transport_mapping's own affine-guided
# local-lookup search range exactly (see roll_index.py: "the canonical
# Nikon detector selects roughly 2..5 rows after a physical gap centre").
CANDIDATE_SEARCH_LOOKAHEAD_ROWS = 8

# A narrow-run anchor whose own table read is untrusted may substitute a
# neighboring trusted row only within this distance -- the lattice's own
# selector-rollover displacement is one row, capped at three for margin.
# Anything farther extrapolates AT the anchor from the local fit instead
# (re-review 2026-08-08, F-A: the uncapped substitute silently displaced
# origins by up to 22 rows through gates that all read zero residual).
SUBSTITUTE_ANCHOR_MAX_DISTANCE_ROWS = 3

# A resolved lookup row farther than this from the operator's pick earns an
# explicit review reason: the ordinary narrow-gap trailing-edge offset is
# ~3 rows, and anything beyond it means the resolution moved meaningfully
# away from what the operator pointed at (re-review 2026-08-08, F-B).
LOOKUP_FAR_FROM_PICK_ROWS = 4
LOOKUP_FAR_FROM_PICK_REVIEW_REASON = "transport-anchor-far-from-pick"

# Placement-wide affine-fit residual gate (F4): identical bounds to
# derive_transport_mapping's own maximum_anchor_mae_rows/
# maximum_anchor_error_rows defaults. MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS is
# imported and reused for the max bound; the MAE bound has no equivalent
# module-level constant in roll_index.py (it is a default parameter value
# there, not a name), so it is restated here at the same 1.0 value.
PLACEMENT_ANCHOR_MAE_ROWS_MAX = 1.0
# A 2-boundary (single-frame) placement's own two points fit a line
# exactly, always -- MAE and max residual are trivially 0 regardless of
# whether either point is right, so this whole gate is enforced only from
# 3 boundaries (2 frames) up. See build_manual_detection's gate 6 comment
# for what a 2-boundary placement relies on instead.
PLACEMENT_ANCHOR_GATE_MINIMUM_BOUNDARIES = 3


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


@dataclass(frozen=True)
class _ResolvedTransportOrigin:
    """One boundary's transport-table origin, resolved through a local
    lattice-aware fit rather than trusted as a single raw row read.

    ``inferred`` and ``substituted`` are mutually informative, not mutually
    exclusive in meaning: ``inferred`` records which of the two resolution
    shapes ``_resolve_boundary_transport_origin`` used (narrow-run trailing
    edge vs broad/weak-evidence forward search); ``substituted`` records
    whether the row actually read differs from the picked row itself.  The
    narrow-run shape can still set ``substituted`` (its own trailing-edge
    row read was untrustworthy, so a nearby trusted row stood in for it);
    the forward-search shape always sets it (it never reads the picked row
    itself, by construction -- see its own docstring).
    """

    lookup_row: int
    code: int
    selector: int
    native_origin: int
    inferred: bool
    substituted: bool


def _ordinal(n: int) -> str:
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def _approximate_mm(row: int) -> float:
    return row * MANUAL_FRAME_HEIGHT_MM_PER_ROW


def _fit_local_transport_ramp(
    table_origins: np.ndarray,
    anchor_row: int,
    ramp_upper_bound: int,
) -> tuple[float, float, np.ndarray] | None:
    """Robustly fit an affine (intercept, scale) line to the transport table
    in a local window around ``anchor_row``.

    Tolerates the lattice's own recurring selector-rollover / sub-rollover
    code jumps (see this module's docstring) as a minority of outlier rows,
    rather than treating any one of them as proof the whole neighborhood is
    untrustworthy -- the failure mode that made the previous per-step ±3-row
    guard refuse nearly every real capture.

    Returns ``(intercept, scale, inlier_rows)`` -- ``inlier_rows`` is the
    absolute row-index array of every window row the final fit trusts -- or
    ``None`` if this neighborhood cannot support one: too few usable rows,
    no majority steady rate, or a fitted scale outside the 40..45 physical
    band even after discounting outliers.
    """

    window_lo = max(0, anchor_row - LOCAL_FIT_WINDOW_RADIUS_ROWS)
    window_hi = min(ramp_upper_bound, anchor_row + LOCAL_FIT_WINDOW_RADIUS_ROWS)
    if window_hi - window_lo + 1 < LOCAL_FIT_MINIMUM_INLIER_ROWS:
        return None

    rows = np.arange(window_lo, window_hi + 1, dtype=np.float64)
    origins = table_origins[window_lo : window_hi + 1].astype(np.float64)

    # Robust, leverage-independent starting line: on real LS-5000 tables the
    # large majority of single-row steps are exactly the scanner's steady
    # per-row rate, so the MEDIAN step and the MEDIAN per-row intercept
    # residual both land close to the true line regardless of how far a
    # minority of lattice-code-boundary rows deviate or where in the window
    # they sit. An ordinary least-squares fit over the raw window does not
    # have that property: a single high-leverage row at a window edge (a
    # leading-anchor-style jump of tens of thousands of native units,
    # observed on archived captures during this rework) can visibly tilt
    # it before any outlier has been set aside.
    step = np.diff(origins) / np.diff(rows)
    scale = float(np.median(step))
    if scale == 0:
        return None
    intercept = float(np.median(origins - scale * rows))
    inlier_mask = (
        np.abs((intercept + scale * rows - origins) / scale)
        <= LOCAL_FIT_TRIM_RESIDUAL_ROWS
    )

    # Refit by ordinary least squares on the robust round's inliers only,
    # then re-trim against THAT fit; repeat a bounded number of times so a
    # borderline row can migrate in or out as the line settles.
    for _ in range(LOCAL_FIT_TRIM_ROUNDS):
        inlier_count = int(inlier_mask.sum())
        if inlier_count < LOCAL_FIT_MINIMUM_INLIER_ROWS:
            return None
        design = np.column_stack((np.ones(inlier_count), rows[inlier_mask]))
        intercept, scale = np.linalg.lstsq(design, origins[inlier_mask], rcond=None)[0]
        if scale == 0:
            return None
        residual_rows = (intercept + scale * rows - origins) / scale
        next_mask = np.abs(residual_rows) <= LOCAL_FIT_TRIM_RESIDUAL_ROWS
        if int(next_mask.sum()) < LOCAL_FIT_MINIMUM_INLIER_ROWS:
            return None
        if np.array_equal(next_mask, inlier_mask):
            inlier_mask = next_mask
            break
        inlier_mask = next_mask

    if not MINIMUM_TRANSPORT_SCALE <= scale <= MAXIMUM_TRANSPORT_SCALE:
        return None
    final_residuals = (
        intercept + scale * rows[inlier_mask] - origins[inlier_mask]
    ) / scale
    if float(np.max(np.abs(final_residuals))) > LOCAL_FIT_TRIM_RESIDUAL_ROWS:
        return None

    inlier_rows = np.arange(window_lo, window_hi + 1)[inlier_mask]
    return float(intercept), float(scale), inlier_rows


def _resolve_boundary_transport_origin(
    records: Sequence[TransportRecord],
    table_origins: np.ndarray,
    picked_row: int,
    evidence_run: tuple[int, int] | None,
    ramp_upper_bound: int,
) -> _ResolvedTransportOrigin | None:
    """Resolve one boundary's native transport origin from a local fit.

    Same class of machinery ``roll_index.derive_transport_mapping`` uses for
    the automatic path: an affine fit over nearby table records, never a
    single raw row read trusted on its own.

    The row this reads from is always trusted first as-is: fit the local
    ramp, and if the anchor row's own raw record already fits it, that
    record IS the answer, full stop -- an honest pick on a clean table
    always resolves to the exact row picked, never a neighbor a fixed
    number of rows away "for consistency" with anything. The anchor itself
    differs by evidence, though: a narrow (``NARROW_EVIDENCE_RUN_MAX_WIDTH_
    ROWS``-wide or less) nearby clear-film evidence run is a specific
    physical reference -- Nikon's own firmware convention places a frame's
    origin a few rows past such a run's trailing edge, exactly the
    "direct-gap-trailing-row" reference ``derive_transport_mapping``'s own
    "direct" method reads -- so when one is available, THAT trailing edge
    is the anchor, not the picked row itself. Without a narrow run -- a
    broad/leader-like clear region, a weak or absent evidence signal, or
    any other picked row with no specific physical trailing edge nearby --
    there is no such reference, so the picked row itself is the anchor.

    Only when the anchor's own raw record is NOT trustworthy does this fall
    back to a substitute, and the two anchor kinds fall back differently.
    A narrow run's trailing edge substitutes its nearest trusted neighbor:
    it is still a specific physical reference, just misread by this one
    row. A picked row with no narrow run to anchor on instead searches
    forward for the table's own closest match to the fit's own prediction,
    mirroring ``derive_transport_mapping``'s affine-guided-local-lookup --
    appropriate here because, without a narrow run, there is no single
    "this one row" already earning trust the way a trailing edge does.

    Returns ``None`` when this neighborhood cannot support a local fit at
    all; the caller treats that as a refusal of the whole placement, never
    a silently accepted guess.
    """

    if not 0 <= picked_row <= ramp_upper_bound:
        return None

    narrow_run = (
        evidence_run is not None
        and evidence_run[1] - evidence_run[0] <= NARROW_EVIDENCE_RUN_MAX_WIDTH_ROWS
        and evidence_run[1] <= ramp_upper_bound
    )
    anchor_row = evidence_run[1] if narrow_run and evidence_run else picked_row

    fit = _fit_local_transport_ramp(table_origins, anchor_row, ramp_upper_bound)
    if fit is None:
        return None
    intercept, scale, inlier_rows = fit

    # The anchor's own raw record is trusted whenever the fit itself trusts
    # it (whether the anchor is the picked row directly or a narrow run's
    # trailing edge) -- this is what makes an exact, honest pick on a clean
    # table resolve to that EXACT row, not a neighbor a fixed number of rows
    # away. Only once the anchor's own reading is NOT trustworthy does this
    # fall back to a substitute: a narrow run's trailing edge substitutes
    # its nearest trusted neighbor (the anchor is still a specific physical
    # reference, just misread by this one row); a picked row with no narrow
    # run to anchor on instead searches forward for the table's own closest
    # match to the fit's prediction, mirroring derive_transport_mapping's
    # affine-guided-local-lookup -- the same convention Nikon's own firmware
    # already uses for a broad/interpolated origin, appropriate here because
    # there is no specific row already earning trust the way a narrow run's
    # trailing edge does.
    if anchor_row in inlier_rows:
        lookup_row = anchor_row
        substituted = False
        inferred = False
    elif narrow_run:
        nearest = int(inlier_rows[np.argmin(np.abs(inlier_rows - anchor_row))])
        if abs(nearest - anchor_row) <= SUBSTITUTE_ANCHOR_MAX_DISTANCE_ROWS:
            lookup_row = nearest
            substituted = True
            inferred = False
        else:
            # Re-review 2026-08-08, F-A: an uncapped nearest-inlier
            # substitute silently displaced origins by up to 22 rows on a
            # table whose symmetric jitter left the median seed standing --
            # a real physical point, so every downstream residual gate saw
            # zero error. Beyond the lattice's own ~1-row rollover
            # displacement (capped at 3 for margin), the anchor's
            # neighborhood is not trustworthy row-by-row; extrapolate AT
            # the anchor from the surviving local fit instead -- the same
            # semantics the automatic path's transport-origin clamp has
            # always had, which also makes the clamp marker truthful here.
            lookup_row = anchor_row
            record = records[anchor_row]
            return _ResolvedTransportOrigin(
                lookup_row=anchor_row,
                code=record.code,
                selector=record.selector,
                native_origin=int(round(intercept + scale * anchor_row)),
                substituted=True,
                inferred=True,
            )
    else:
        start = max(0, anchor_row + 1)
        end = min(ramp_upper_bound + 1, anchor_row + CANDIDATE_SEARCH_LOOKAHEAD_ROWS)
        if start >= end:
            return None
        candidates = np.arange(start, end)
        prediction = intercept + scale * anchor_row
        lookup_row = int(
            candidates[
                np.argmin(
                    np.abs(table_origins[candidates].astype(np.float64) - prediction)
                )
            ]
        )
        substituted = True
        inferred = True

    record = records[lookup_row]
    return _ResolvedTransportOrigin(
        lookup_row=lookup_row,
        code=record.code,
        selector=record.selector,
        native_origin=record.native_origin,
        inferred=inferred,
        substituted=substituted,
    )


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

    ``rgb16``/``known`` are the same decoded whole-roll preview raster and
    completeness mask ``detect_roll_frames`` takes; ``records`` is the same
    same-traversal live READ(0x8e) transport table used everywhere else in
    this package. No film moves and no relaxed automatic-detection knobs are
    tried here -- this is a completely separate code path from
    ``detect_roll_frames``/``derive_transport_mapping``.

    Every gate below fails closed: any failure raises before this function
    returns anything, so a caller can never end up with a placement that
    silently accepted some of the operator's picks and dropped others.

    Idempotent by construction (F3): every check that depends on the exact
    rows a placement resolves to (the height gates, transport resolution,
    pairwise and placement-wide fits) runs on ``final_rows`` -- the rows
    AFTER snap assist, i.e. this function's own output boundary rows -- so
    feeding a previously accepted placement's own ``detection.boundaries``
    output rows back in as new ``boundary_rows`` re-derives the identical
    result rather than re-litigating a pre-snap view of the picks that no
    longer describes the placement. This matters beyond a nicety: the batch
    capture wire and the worker's live-scan replay both resupply a session's
    already-snapped rows as the next call's raw ``boundary_rows``
    (``Roll.scan_many``, the batch job, and ``worker._derive_live_frame_
    selection``'s manual branch), so a placement that could not survive its
    own replay would deadlock an approved session at scan time.
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

    # ---- gate 2: snap assist (default on, never a hard requirement) -------
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
    # anything downstream. Practically unreachable given gate 1 already ran
    # on the raw picks, but cheap, correct, and this module never trusts an
    # unchecked value just because a similar one was already checked.
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

    # ---- gate 3: physical frame-height floor and ceiling, on the FINAL ----
    # ---- (post-snap) rows (F2 + F3) ----------------------------------------
    # Snap assist (gate 2) can move each boundary independently by up to
    # SNAP_ASSIST_MAX_DISTANCE_ROWS, which can shrink a frame that was
    # exactly at the floor below it, or grow one that was exactly at the
    # ceiling past it (both reachable live: a pick 56 rows from its neighbor
    # that both snap toward each other lands under the floor; one at the
    # ceiling that both snap apart lands over it). Checking the RAW picks
    # here, the way this gate used to, can accept a frame whose real
    # (post-snap) height violates either bound -- and, because the reviewed
    # session/batch-wire/worker-replay path always resupplies a prior call's
    # own final_rows as the next call's raw boundary_rows (see this
    # function's own docstring), checking raw picks here would also make
    # this function non-idempotent: a placement it just approved could
    # refuse when replayed verbatim. A post-snap check does not give up
    # anything a pre-snap one caught -- snap assist is deterministic and
    # already re-verified for order/bounds just above -- so there is no
    # reason to keep both.
    for index, (start, end) in enumerate(zip(final_rows, final_rows[1:]), start=1):
        height_rows = end - start
        if height_rows < MINIMUM_MANUAL_FRAME_HEIGHT_ROWS:
            approx_mm = _approximate_mm(height_rows)
            floor_mm = _approximate_mm(MINIMUM_MANUAL_FRAME_HEIGHT_ROWS)
            raise IndexDecodeError(
                f"the {_ordinal(index)} frame you placed is about "
                f"{approx_mm:.0f} mm tall (between rows {start} and {end}), "
                f"shorter than the {floor_mm:.0f} mm floor this driver "
                "accepts for manual placement"
            )
        if height_rows > FINE_CAPTURE_WINDOW_ROWS:
            approx_mm = _approximate_mm(height_rows)
            raise IndexDecodeError(
                f"the {_ordinal(index)} frame you placed is about "
                f"{approx_mm:.0f} mm tall (between rows {start} and {end}); "
                f"the scanner captures about {FINE_CAPTURE_WINDOW_MM:.1f} mm "
                "per frame in one fine scan and there is no way to capture "
                "a taller frame in a single pass -- place a boundary "
                "partway through it instead"
            )

    # ---- gate 4: per-boundary transport-origin resolution (F1) ------------
    # Same class of machinery roll_index.derive_transport_mapping uses for
    # the automatic path: an affine fit over nearby table records, not a
    # single raw row read trusted on its own. See
    # _resolve_boundary_transport_origin's own docstring for the two
    # resolution shapes and why each mirrors a specific
    # derive_transport_mapping convention. Every failure here still refuses
    # the WHOLE placement before anything is returned, exactly like every
    # gate above and below it.
    if len(records) < 1:
        raise IndexDecodeError(
            "manual frame placement requires the same-traversal scanner "
            "position table; none was supplied"
        )
    for index, row in enumerate(final_rows):
        if not 0 <= row < len(records):
            raise IndexDecodeError(
                f"the {_ordinal(index + 1)} frame edge you placed (row "
                f"{row}) has no matching entry in the scanner's position "
                "table; place it on a row the scanner actually recorded a "
                "position for"
            )

    tail_start = terminal_transport_tail_start(records)
    ramp_upper_bound = (
        len(records) - 1 if tail_start is None else min(len(records) - 1, tail_start - 1)
    )
    table_origins = np.fromiter(
        (record.native_origin for record in records),
        dtype=np.int64,
        count=len(records),
    )

    # The very last picked row is never a frame START -- it is only the
    # visual END of the final frame (FrameInterval.end_row below), the same
    # way roll_index.derive_transport_mapping itself only ever resolves
    # transport origins for boundaries[:frame_count], never the trailing
    # one. A roll's last frame commonly ends at or after the point the live
    # 0x8e ramp stops being trustworthy (terminal_transport_tail_start) --
    # that is an ordinary, healthy end-of-roll shape, not a defect, so
    # ONLY this one trailing pick is allowed to fail resolution without
    # refusing the whole placement. Every other pick funds an actual
    # frame's origin and must resolve or this still refuses in full.
    trailing_index = len(final_rows) - 1
    resolved: list[_ResolvedTransportOrigin | None] = []
    for index, row in enumerate(final_rows):
        origin = _resolve_boundary_transport_origin(
            records, table_origins, row, supporting_runs[index], ramp_upper_bound
        )
        if origin is None:
            if index == trailing_index:
                resolved.append(None)
                continue
            raise IndexDecodeError(
                "the scanner's position table doesn't settle into a steady "
                f"rate near the {_ordinal(index + 1)} frame edge you "
                f"placed (row {row}, about {_approximate_mm(row):.0f} mm "
                "into the roll); try placing the boundary a few rows to "
                "either side, or re-scan the preview and place the frames "
                "again"
            )
        resolved.append(origin)

    # ---- gate 5: adjacent resolved origins strictly increasing at 40..45 --
    # Same pairwise sanity as before the rework, now checked against each
    # boundary's RESOLVED origin (gate 4) instead of one raw row read. This
    # catches a distinct failure mode from gate 4: gate 4 proves each
    # boundary's own neighborhood is internally affine; this proves adjacent
    # boundaries agree with EACH OTHER, which catches a genuine mid-span
    # table discontinuity between two picks that neither boundary's own
    # local window ever sees.
    #
    # The row side of "position units per row" uses each boundary's
    # RESOLVED lookup_row, not the visual row the operator placed. A narrow
    # evidence run's trailing edge and a broad-region forward search each
    # read the table a few rows away from the exact pick, by design (see
    # _resolve_boundary_transport_origin); that offset differs between the
    # two, so two adjacent boundaries resolved through different paths (a
    # narrow inter-frame gap next to, say, the leader) can have visually
    # placed rows that imply a fine but genuine steady rate while their
    # ACTUAL table rows do not, or the other way around. lookup_row is what
    # was actually read, so it is the only row number this check can hold
    # to a physical rate without occasionally penalizing a placement for
    # nothing more than which resolution path two neighbors happened to
    # take.
    #
    # Only the trailing pick (see above) can be None, and only as the very
    # last element of ``resolved`` -- so the one pair this could affect is
    # the last one; skip it rather than compare against a resolution that
    # was never required to exist.
    for index, (before, after) in enumerate(zip(resolved, resolved[1:]), start=1):
        if before is None or after is None:
            continue
        delta_rows = after.lookup_row - before.lookup_row
        delta_origin = after.native_origin - before.native_origin
        implied_scale = delta_origin / delta_rows if delta_rows else 0.0
        if not (
            delta_origin > 0
            and MINIMUM_TRANSPORT_SCALE <= implied_scale <= MAXIMUM_TRANSPORT_SCALE
        ):
            raise IndexDecodeError(
                "the scanner's position readings between the "
                f"{_ordinal(index)} and {_ordinal(index + 1)} frame edges "
                f"you placed don't move at a steady rate (about "
                f"{implied_scale:.1f} position units per row; this driver "
                "expects roughly 40-45); try placing the boundaries again, "
                "or re-scan the preview"
            )

    # ---- gate 6: placement-wide affine-fit residuals (F4) -----------------
    # Same residual contract derive_transport_mapping enforces on the
    # automatic path (anchor_mae_rows <= PLACEMENT_ANCHOR_MAE_ROWS_MAX,
    # anchor_max_error_rows <= MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS) -- before
    # this rework computed here for TransportMapping.diagnostics() but never
    # enforced, which is exactly how a placement whose picks disagreed with
    # each other could still get bound downstream: worker.py's
    # apply_boundary_offset re-checks this same residual at bind time and
    # either refuses per frame or, if a caller wrongly granted rebase, keeps
    # a displaced origin (see worker.py's origin_rebase_allowed /
    # origin_rebase_slots computation for the other half of that fix, which
    # this rework also closes -- manual placements are no longer eligible
    # for that rebase).
    #
    # A 2-boundary (single-frame) placement's own two points always fit a
    # line exactly -- MAE and max residual are trivially 0 no matter how
    # wrong either point is, so this gate cannot add anything for a single
    # frame. What validates a 2-boundary placement is gate 4 (each pick's
    # own local neighborhood proves internally affine) and gate 5 (the one
    # pairwise implied scale between the two picks); there is no third,
    # independent boundary to cross-check either pick against, so a
    # systematic table shift confined entirely between the two picks -- one
    # that neither pick's own local window sees and that still lands inside
    # the 40..45 pairwise scale band -- is not detectable from two points,
    # full stop, no matter how this module is written. Documented here
    # rather than silently pretended away with a gate that would always
    # pass anyway.
    #
    # Fit against each boundary's RESOLVED lookup_row, for the same reason
    # gate 5 just switched to it: lookup_row is the row this placement's
    # origins actually came from, so fitting it is a check on whether the
    # TABLE is one consistent physical ramp across this placement's span --
    # true regardless of which resolution path (narrow-run trailing edge vs
    # broad-region forward search) picked each lookup_row. Fitting the
    # visual pick rows instead would fold each path's own few-row read
    # offset into the residual alongside genuine table drift, and a
    # placement that mixes both paths (e.g. a leader-adjacent first
    # boundary next to ordinary narrow inter-frame gaps -- an entirely
    # ordinary manual placement) would then show a spurious drift this gate
    # would wrongly refuse on. NativeFrameOrigin.boundary_output_row is set
    # to this same lookup_row below (not the visual pick row) precisely so
    # worker.py's apply_boundary_offset -- the only other reader of that
    # field, and out of scope for this rework -- re-predicts against the
    # identical row this fit was trained on.
    #
    # Only over the boundaries that actually resolved (see above: the
    # trailing one may not have).
    fit_indices = [index for index, item in enumerate(resolved) if item is not None]
    fit_items = [resolved[index] for index in fit_indices]
    lookup_rows_arr = np.asarray([item.lookup_row for item in fit_items], dtype=np.float64)
    origin_arr = np.asarray([item.native_origin for item in fit_items], dtype=np.float64)
    design = np.column_stack((np.ones(len(lookup_rows_arr)), lookup_rows_arr))
    placement_intercept, placement_scale = np.linalg.lstsq(design, origin_arr, rcond=None)[0]
    if placement_scale:
        fit_residual_rows = (
            design @ np.asarray((placement_intercept, placement_scale)) - origin_arr
        ) / placement_scale
        anchor_mae = float(np.mean(np.abs(fit_residual_rows)))
        anchor_max = float(np.max(np.abs(fit_residual_rows)))
    else:  # pragma: no cover - unreachable once gate 5 has passed
        fit_residual_rows = np.zeros_like(origin_arr)
        anchor_mae = 0.0
        anchor_max = 0.0
    # Full-length (per final_rows position), None only where the trailing
    # pick has no resolution -- resolved[:-1] (what the origins loop below
    # actually indexes) never includes that position, so every residual it
    # reads is always a real float.
    placement_residual_rows: list[float | None] = [None] * len(resolved)
    for index, residual in zip(fit_indices, fit_residual_rows):
        placement_residual_rows[index] = float(residual)

    if len(fit_items) >= PLACEMENT_ANCHOR_GATE_MINIMUM_BOUNDARIES and (
        anchor_mae > PLACEMENT_ANCHOR_MAE_ROWS_MAX
        or anchor_max > MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS
    ):
        raise IndexDecodeError(
            "the scanner's position readings across this whole placement "
            f"don't agree on one steady rate (average drift {anchor_mae:.2f} "
            f"rows, worst-case drift {anchor_max:.2f} rows against one "
            "straight line through this placement's own scanner-table "
            "readings); try placing the boundaries again, or re-scan the "
            "preview"
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
    for frame_index, (start_boundary, item, residual) in enumerate(
        zip(boundaries[:-1], resolved[:-1], placement_residual_rows[:-1]), start=1
    ):
        reasons = [MANUAL_ORIGIN_REVIEW_REASON]
        if item.inferred:
            reasons.append(INFERRED_ORIGIN_REVIEW_REASON)
        elif item.substituted:
            reasons.append(TRANSPORT_ORIGIN_CLAMP_REASON)
        if (
            abs(item.lookup_row - start_boundary.output_row)
            > LOOKUP_FAR_FROM_PICK_ROWS
        ):
            # Re-review 2026-08-08, F-B: a false clear-film run inside a
            # frame (blown-highlight band on slide film) can pull the
            # trailing-edge anchor well away from what the operator pointed
            # at with no snap note and no other signal. Beyond the ordinary
            # ~3-row narrow-gap offset, the divergence gets its own review
            # reason so the approval UI shows the operator that the scanner
            # will cut this frame somewhere other than exactly their line.
            reasons.append(LOOKUP_FAR_FROM_PICK_REVIEW_REASON)
        origins.append(
            NativeFrameOrigin(
                frame=frame_index,
                boundary_index=start_boundary.index,
                # Deliberately the RESOLVED lookup_row, not the visual pick
                # row (GapBoundary.output_row, used unchanged for thumbnail
                # cropping in the interval above) -- see gate 6's own
                # comment for why the placement-wide fit is trained on
                # lookup_row, and why this field has to match that same row
                # for worker.py's apply_boundary_offset (this field's only
                # other reader) to re-predict consistently with it.
                boundary_output_row=item.lookup_row,
                lookup_row=item.lookup_row,
                code=item.code,
                selector=item.selector,
                native_origin=item.native_origin,
                method=MANUAL_ORIGIN_METHOD,
                automatic=False,
                manual_review=True,
                review_reasons=tuple(reasons),
                # The placement-wide fit's own residual (gate 6) for this
                # boundary, not a per-pick local-window residual: this is
                # the same quantity worker.py's _addressable_frame_origins
                # and apply_boundary_offset already gate every AUTOMATIC
                # origin's affine_residual_rows against
                # (MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS), so reusing it here
                # keeps that shared downstream logic meaningful instead of
                # silently truncating a manual placement's addressable
                # prefix for a reason nobody surfaced. For a 2-boundary
                # placement this is exactly 0.0 (a line through two points
                # has no residual), matching what this field used to be
                # hardcoded to before the rework.
                affine_residual_rows=float(residual),
            )
        )

    # Diagnostic-only affine summary across every picked boundary (not just
    # the frame-owning ones) -- surfaced through TransportMapping.
    # diagnostics() and now also enforced above (gate 6).
    mapping = TransportMapping(
        record_count=len(records),
        native_intercept=float(placement_intercept),
        native_units_per_preview_row=float(placement_scale),
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
