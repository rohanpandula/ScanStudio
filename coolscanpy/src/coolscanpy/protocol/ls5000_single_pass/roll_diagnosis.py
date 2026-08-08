"""Read-only probable-cause diagnosis for an LS-5000 roll-index refusal.

Analyzes the same physical evidence signals the frame detector itself
computes -- illuminated aperture, per-row transmission/uniformity, and the
resulting clear-film run structure -- to translate *why* a roll failed into
one plain-English sentence a film hobbyist can act on. This module never
re-derives or relaxes any detection knob and cannot construct a detection
result of any kind: its only public function returns a sentence or nothing,
enforced by a structural test. See FEEDING-UX-LADDER-OVERNIGHT-20260807.md
("Rung 3") for the design and FEEDING-ROBUSTNESS-20260805.md ("P3") for the
original rationale this module adapts.
"""

from __future__ import annotations

import math

import numpy as np

from .roll_index import (
    WIDE_GAP_CEILING_ROWS,
    _active_aperture,
    _physical_gap_evidence,
    _true_runs,
)

# One 97 dpi preview row of film, in mm. FEEDING-ROBUSTNESS-20260805.md Sec
# 1.1: 142.5 measured preview rows per 38.1 mm standard 8-perforation frame.
MM_PER_PREVIEW_ROW = 0.267

# The detector's own accepted pitch band, as a fraction of nominal_frame_rows
# (mirrors roll_index.py's own coarse lag_min/lag_max search constants).
_STANDARD_LAG_LOW_RATIO = 0.85
_STANDARD_LAG_HIGH_RATIO = 1.15

# Half-frame (18x24) and panoramic/Xpan true pitch, as a fraction of the
# driver's assumed standard-35mm nominal_frame_rows (~71/145 and ~259/145
# measured, FEEDING-ROBUSTNESS-20260805.md Sec 3.3).
_HALF_FRAME_PITCH_RATIO = 0.49
_PANORAMA_PITCH_RATIO = 1.79

# Search tolerance (+/-) around each alternate-format point estimate above.
_ALTERNATE_LAG_TOLERANCE = 0.10

# A clear-film run has to stay below this fraction of one whole frame pitch
# to count as a candidate for the periodicity search below. Without this, a
# long leading/trailing unexposed leader (legitimately dozens to hundreds of
# rows, e.g. test_variable_leader_and_trailer_are_visible_without_guessing_
# roll_count's leader=300/tail=260 case) is one giant, non-periodic block
# whose own short-lag self-similarity swamps the real inter-frame signal
# and reads as false alternate-pitch periodicity.
_ALTERNATE_PITCH_CANDIDATE_SCALE_FRACTION = 0.5

# How much of the standard-window peak an alternate-pitch peak must reach
# before it is trusted. See _diagnose_alternate_pitch's docstring for why
# these two differ by an order of magnitude -- it is not an oversight.
_HALF_FRAME_DOMINANCE_MARGIN = 0.85
_PANORAMA_DOMINANCE_MARGIN = 2.0

# A panorama candidate whose winning lag sits this close to exactly double
# the standard-window lag is that roll's own second harmonic, not panorama.
_HARMONIC_ALIAS_TOLERANCE_ROWS = 4

# Matches the detector's own narrow-run floor (roll_index.py's accepted
# [3, 12]-row clear-film run window).
_NARROW_GAP_FLOOR_ROWS = 3

# Distinct too-narrow/too-wide runs required before this check trusts a
# systematic pattern instead of one noisy outlier run.
_GAP_GEOMETRY_MIN_RUNS = 3

# A run has to stay below this fraction of one whole frame pitch to still
# read as "a gap" rather than "an unexposed frame".
_TOO_WIDE_FRAME_SCALE_FRACTION = 0.5

# The near-miss band just under the detector's own direct-gap gates
# (roll_index.py's _physical_gap_evidence: transmission >= 0.87,
# nonuniformity <= 0.18).
_CONTRAST_FLOOR_LOW = 0.80
_CONTRAST_FLOOR_HIGH = 0.87
_CONTRAST_FLOOR_NONUNIFORMITY_CEILING = 0.18

# A near-miss run has to be at least this wide, and there have to be at
# least this many of them, before low contrast (not noise) is the read.
_CONTRAST_FLOOR_MIN_RUN_ROWS = 2
_CONTRAST_FLOOR_MIN_CLUSTERS = 3

# Leading/trailing slice of the aperture width checked against the middle.
_APERTURE_EDGE_FRACTION = 0.20
# A side at or below this fraction of the middle's brightness reads as
# obstructed (measured cliff: 15/96 cols @ 70% transmission fails detection,
# 10 columns does not -- FEEDING-ROBUSTNESS-20260805.md Sec 3.3).
_APERTURE_OBSTRUCTION_RATIO = 0.85
# The fog/dense-base sentence requires both aperture edges within this
# fraction of the middle: below it, the transmission depression is
# one-sided (an obstruction-shaped signal, whatever its depth), and the
# contrast check stays silent rather than blaming the film stock.
_CONTRAST_FLOOR_SYMMETRY_FLOOR = 0.90
# The obstruction profile is judged over clear-film candidate rows: rows
# whose middle-column level reaches this fraction of the raster's own
# clear-base reference (p99 of row middles -- the same self-normalising
# shape the detector's clear_base uses). A fixed top-percentile cut is
# wrong here: on a full roll only ~6% of rows are clear film, so any
# percentile wide enough to be robust also admits bright FRAME rows,
# whose scene content carries per-column structure that median-stacks
# into a false one-sided depression (caught by the healthy-roll
# regression, 2026-08-08). A minimum count of candidate rows is still
# required before the check may speak at all.
_OBSTRUCTION_CLEAR_LEVEL_FRACTION = 0.75
_OBSTRUCTION_MIN_BRIGHT_ROWS = 6
# ...and the p99 reference itself must stand clearly apart from the typical
# row before those candidates are believed to be clear film at all: on a
# roll with NO clear rows (dense/gapless refusals -- exactly when diagnosis
# runs), p99 lands on bright FRAME rows whose one-sided scene content then
# resurrects the phantom-obstruction sentence (re-review 2026-08-08, F-C).
# Real clear film reads several times brighter than frame content; a p99
# within this ratio of the median row means there is no clear-film
# population to judge from, and the check stays silent. 1.8 sits between
# frame texture's own p99/median spread (~1.5-1.6 measured on the synthetic
# fixtures) and real clear film's ~3x separation; dense film whose clear
# rows barely clear its frames loses obstruction diagnosis rather than
# risking a wrong sentence.
_OBSTRUCTION_CLEAR_SEPARATION_RATIO = 1.8
# Below this aperture width, edge/middle columns cannot be split usefully.
_APERTURE_MIN_WIDTH_FOR_OBSTRUCTION_CHECK = 10

# Mirrors the detector's own row-completeness floor
# (complete_rows.mean() < 0.995 -- see roll_index.py's single-pass core).
_MINIMUM_COMPLETE_ROW_FRACTION = 0.995


def _autocorrelation_peak(
    centered: np.ndarray, lag_min: int, lag_max: int
) -> tuple[float | None, int | None]:
    """Best centered-signal dot-product correlation in one lag window.

    Same normalized form the detector's own coarse pitch search uses
    (``np.dot(centered[:-lag], centered[lag:]) / (len(centered) - lag)``) --
    a single lag-by-lag scan, not a lattice fit, so it stays cheap enough to
    run on every failure. Returns ``(None, None)`` when the window has no
    valid lag for this raster's length.
    """

    lag_min = max(1, int(math.floor(lag_min)))
    lag_max = min(len(centered) - 3, int(math.ceil(lag_max)))
    if lag_min > lag_max:
        return None, None
    best_value: float | None = None
    best_lag: int | None = None
    for lag in range(lag_min, lag_max + 1):
        value = float(np.dot(centered[:-lag], centered[lag:]) / (len(centered) - lag))
        if best_value is None or value > best_value:
            best_value, best_lag = value, lag
    return best_value, best_lag


def _dominates(alternate: float | None, standard: float | None, margin: float) -> bool:
    """Whether an alternate-pitch peak is confidently the real periodicity.

    ``alternate`` must itself be a genuine positive correlation -- a
    hypothesis nothing in the raster supports never fires, no matter how
    weak ``standard`` is. Once that holds, a non-positive ``standard`` peak
    (no periodicity found at the driver's assumed pitch at all) is beaten
    automatically; otherwise ``alternate`` must clear ``margin`` times
    ``standard``.
    """

    if alternate is None or alternate <= 0:
        return False
    if standard is None or standard <= 0:
        return True
    return alternate >= margin * standard


def _diagnose_alternate_pitch(
    evidence: np.ndarray, direct: np.ndarray, nominal_frame_rows: int
) -> str | None:
    """Half-frame and panoramic film pitch check.

    Half-frame's true pitch sits close to half the driver's assumed
    nominal; panoramic/Xpan's sits close to 1.79x it. Both are recognized
    by directly probing an autocorrelation window centered on the
    alternate pitch instead of the driver's assumed one.

    The signal correlated is ``evidence`` zeroed everywhere except inside
    clear-film runs narrower than the candidate-scale fraction of one frame
    pitch (``_ALTERNATE_PITCH_CANDIDATE_SCALE_FRACTION``) -- the same
    "restrict to run-scale evidence" shape the detector's own
    ``anchor_signal`` uses, adapted here with a wider, format-agnostic cap
    instead of the detector's exact [3, 12]-row window, since a half-frame
    or panoramic roll's own gaps need not fall in that specific band.
    Without this restriction, a long unexposed leader/trailer (legitimately
    dozens to hundreds of rows) is one giant non-periodic block whose own
    short-lag self-similarity reads as false periodicity at short lags --
    confirmed by direct measurement, not theory: an otherwise-healthy
    synthetic roll with a 300-row leader produced a spurious "half-frame"
    reading before this restriction, and none after.

    A margin note, because the obvious "just beat the standard-window
    peak" comparison does not hold for half-frame: on a clean periodic
    signal, autocorrelation at any integer multiple of the true period is
    roughly *equal* to correlation at the true period itself (measured
    0.87-1.06x across many synthetic half-frame rolls, never close to
    2x) -- the driver's standard window is finding half-frame film's own
    second harmonic, not a competing signal. The real tell is sign, not
    multiple: a genuinely standard roll shows no periodicity at all at the
    half-frame lag (consistently negative in the same sweep), so
    ``_HALF_FRAME_DOMINANCE_MARGIN`` only has to rule out noise once the
    alternate peak is already positive.

    Panorama does not share that ambiguity -- 1.79x is not an integer
    relationship with the standard pitch -- so the far stricter
    ``_PANORAMA_DOMINANCE_MARGIN`` applies there instead, matching this
    check's own "e.g. 2x" starting point. The one confound is the mirror
    image of the half-frame case: a standard roll's *own* second harmonic
    (2x its true pitch) can land inside the panorama search window, and
    there it ties the standard peak the same way half-frame's does.
    Rejecting any panorama candidate whose winning lag sits within
    ``_HARMONIC_ALIAS_TOLERANCE_ROWS`` of exactly twice the standard-window
    lag (the same neighbor-exclusion radius the detector's own
    ``autocorrelation_best_non_neighbor`` uses) closes that hole.
    """

    candidate_scale_rows = (
        _ALTERNATE_PITCH_CANDIDATE_SCALE_FRACTION * nominal_frame_rows
    )
    periodic = np.zeros_like(evidence)
    for start, end in _true_runs(direct):
        if (end - start) < candidate_scale_rows:
            periodic[start:end] = evidence[start:end]
    centered = periodic - float(periodic.mean())
    standard_peak, standard_lag = _autocorrelation_peak(
        centered,
        nominal_frame_rows * _STANDARD_LAG_LOW_RATIO,
        nominal_frame_rows * _STANDARD_LAG_HIGH_RATIO,
    )
    standard_mm = nominal_frame_rows * MM_PER_PREVIEW_ROW

    half_peak, half_lag = _autocorrelation_peak(
        centered,
        nominal_frame_rows * _HALF_FRAME_PITCH_RATIO * (1 - _ALTERNATE_LAG_TOLERANCE),
        nominal_frame_rows * _HALF_FRAME_PITCH_RATIO * (1 + _ALTERNATE_LAG_TOLERANCE),
    )
    if _dominates(half_peak, standard_peak, _HALF_FRAME_DOMINANCE_MARGIN):
        half_mm = half_lag * MM_PER_PREVIEW_ROW
        return (
            f"this looks like half-frame film (a frame about every {half_mm:.0f} mm); "
            f"this driver expects standard 35 mm spacing (about {standard_mm:.0f} mm "
            "between frame starts)"
        )

    panorama_peak, panorama_lag = _autocorrelation_peak(
        centered,
        nominal_frame_rows * _PANORAMA_PITCH_RATIO * (1 - _ALTERNATE_LAG_TOLERANCE),
        nominal_frame_rows * _PANORAMA_PITCH_RATIO * (1 + _ALTERNATE_LAG_TOLERANCE),
    )
    aliases_standard_second_harmonic = (
        standard_peak is not None
        and standard_peak > 0
        and standard_lag is not None
        and panorama_lag is not None
        and abs(panorama_lag - 2 * standard_lag) <= _HARMONIC_ALIAS_TOLERANCE_ROWS
    )
    if not aliases_standard_second_harmonic and _dominates(
        panorama_peak, standard_peak, _PANORAMA_DOMINANCE_MARGIN
    ):
        panorama_mm = panorama_lag * MM_PER_PREVIEW_ROW
        return (
            f"this looks like panoramic film (a frame about every {panorama_mm:.0f} mm); "
            f"this driver expects standard 35 mm spacing (about {standard_mm:.0f} mm "
            "between frame starts)"
        )
    return None


def _diagnose_gap_geometry(direct: np.ndarray, nominal_frame_rows: int) -> str | None:
    """Clear-film run-width histogram: systematically too-narrow or too-wide gaps.

    Only fires when *every* found run shares the same problem -- a mix of
    narrow and wide runs is a messier picture this check should not guess
    at, and ``_GAP_GEOMETRY_MIN_RUNS`` keeps one stray run from deciding
    the sentence on its own.
    """

    runs = _true_runs(direct)
    if len(runs) < _GAP_GEOMETRY_MIN_RUNS:
        return None
    widths = [end - start for start, end in runs]

    if all(width < _NARROW_GAP_FLOOR_ROWS for width in widths):
        measured_mm = float(np.median(widths)) * MM_PER_PREVIEW_ROW
        floor_mm = _NARROW_GAP_FLOOR_ROWS * MM_PER_PREVIEW_ROW
        return (
            f"the blank strips between your frames measure about {measured_mm:.1f} mm; "
            f"that is under the {floor_mm:.1f} mm this detector needs to recognize a gap"
        )

    frame_scale_rows = _TOO_WIDE_FRAME_SCALE_FRACTION * nominal_frame_rows
    too_wide = [
        width for width in widths if WIDE_GAP_CEILING_ROWS < width < frame_scale_rows
    ]
    if too_wide and len(too_wide) == len(widths):
        measured_mm = float(np.median(too_wide)) * MM_PER_PREVIEW_ROW
        return (
            f"a blank region measures about {measured_mm:.1f} mm; that is wider than "
            "anything the detector accepts as a between-frame gap"
        )
    return None


def _diagnose_contrast_floor(
    transmission: np.ndarray,
    nonuniformity: np.ndarray,
    direct: np.ndarray,
    rgb16: np.ndarray,
    aperture: tuple[int, int],
) -> str | None:
    """Rows that fail only the transmission half of the direct gap gate.

    ``nonuniformity`` is held to the same ceiling the detector's own direct
    gate uses, so this isolates rows that are flat (not scene content) but
    simply too dim -- fog or a dense film base, not noise.

    Fog and a dense base are whole-film properties, so the depression must
    be roughly column-symmetric before this speaks (adversarial review
    2026-08-08, F5): a one-sided aperture band can drag gap rows into the
    same 0.80-0.87 near-miss window while sitting just above the
    obstruction check's own ratio, and the fog sentence would then send
    the reporter chasing their film stock when the real problem is holder
    seating. An asymmetric profile stays silent -- no sentence beats a
    wrong one.
    """

    lo, hi = aperture
    width = hi - lo
    if width >= _APERTURE_MIN_WIDTH_FOR_OBSTRUCTION_CHECK:
        column_level = np.median(
            rgb16[:, lo:hi].astype(np.float64).mean(axis=2), axis=0
        )
        edge = max(1, round(width * _APERTURE_EDGE_FRACTION))
        if width - 2 * edge >= edge:
            middle = float(np.median(column_level[edge:-edge]))
            if middle > 0:
                leading = float(np.median(column_level[:edge])) / middle
                trailing = float(np.median(column_level[-edge:])) / middle
                if min(leading, trailing) < _CONTRAST_FLOOR_SYMMETRY_FLOOR:
                    return None

    near_miss = (
        ~direct
        & (nonuniformity <= _CONTRAST_FLOOR_NONUNIFORMITY_CEILING)
        & (transmission >= _CONTRAST_FLOOR_LOW)
        & (transmission < _CONTRAST_FLOOR_HIGH)
    )
    runs = _true_runs(near_miss)
    clusters = [
        (start, end)
        for start, end in runs
        if end - start >= _CONTRAST_FLOOR_MIN_RUN_ROWS
    ]
    if len(clusters) < _CONTRAST_FLOOR_MIN_CLUSTERS:
        return None
    measured = float(
        np.median(np.concatenate([transmission[start:end] for start, end in clusters]))
    )
    return (
        "the blank film between frames is only slightly clearer than the frames "
        f"themselves (relative brightness about {measured:.2f}, against the "
        f"{_CONTRAST_FLOOR_HIGH:.2f} the detector needs); this could be fog or a "
        "dense film base"
    )


def _diagnose_aperture_obstruction(
    rgb16: np.ndarray, aperture: tuple[int, int]
) -> str | None:
    """Column-wise brightness profile: one aperture edge depressed against the middle.

    Measured over the raster's BRIGHTEST rows by middle-column level -- the
    clear-film candidates. A real physical obstruction -- carrier mask
    edge, curl shadow, tape, heavy edge fog -- depresses a fixed band of
    columns on every row including the clear ones, while a roll whose
    photographs simply carry dark content along one side (2026-08-08
    review, S9) depresses that side only where there is picture. Judging
    on bright rows keeps the first and drops the second: an obstruction
    still shows there (its columns stay dark even when the film is clear),
    but composition cannot (a bright/clear row has no dark subject edge).
    """

    lo, hi = aperture
    width = hi - lo
    if width < _APERTURE_MIN_WIDTH_FOR_OBSTRUCTION_CHECK:
        return None
    levels = rgb16[:, lo:hi].astype(np.float64).mean(axis=2)
    edge = max(1, round(width * _APERTURE_EDGE_FRACTION))
    if width - 2 * edge < edge:
        return None
    row_middle = np.median(levels[:, edge:-edge], axis=1)
    clear_reference = float(np.percentile(row_middle, 99.0))
    if clear_reference <= 0:
        return None
    typical_row = float(np.median(row_middle))
    if typical_row > 0 and clear_reference < (
        _OBSTRUCTION_CLEAR_SEPARATION_RATIO * typical_row
    ):
        return None
    bright_rows = row_middle >= _OBSTRUCTION_CLEAR_LEVEL_FRACTION * clear_reference
    if int(bright_rows.sum()) < _OBSTRUCTION_MIN_BRIGHT_ROWS:
        return None
    column_level = np.median(levels[bright_rows], axis=0)
    middle = float(np.median(column_level[edge:-edge]))
    if middle <= 0:
        return None
    leading_ratio = float(np.median(column_level[:edge])) / middle
    trailing_ratio = float(np.median(column_level[-edge:])) / middle
    if leading_ratio <= _APERTURE_OBSTRUCTION_RATIO:
        side = "leading"
    elif trailing_ratio <= _APERTURE_OBSTRUCTION_RATIO:
        side = "trailing"
    else:
        return None
    return (
        f"one edge of the film window looks partly blocked (the {side} side reads "
        "darker than the middle); check the film holder seating and film curl"
    )


def diagnose_roll_refusal(
    rgb16: np.ndarray,
    known: np.ndarray,
    *,
    nominal_frame_rows: int,
) -> str | None:
    """One plain-English probable cause for a roll refusal, or ``None``.

    Pure read-only analysis over the same evidence signals the frame
    detector itself computes -- aperture, per-row transmission/uniformity,
    and the resulting clear-film run structure. It never re-runs detection
    with relaxed knobs and cannot produce frames, boundaries, or a
    detection result of any kind: the only thing it can hand back is one
    sentence or nothing. Checks run in a fixed priority order and the
    first one confident enough to speak wins; if none clear their margin
    this returns ``None``, on the belief that no sentence beats a wrong
    one.
    """

    try:
        if rgb16.shape != known.shape or nominal_frame_rows < 16:
            return None
        complete_rows = np.asarray(known, dtype=bool).all(axis=(1, 2))
        if complete_rows.mean() < _MINIMUM_COMPLETE_ROW_FRACTION:
            return None
        aperture = _active_aperture(rgb16)
        evidence, transmission, nonuniformity, direct = _physical_gap_evidence(
            rgb16, aperture
        )
    except Exception:
        # Every check below assumes a well-formed raster with a real
        # aperture; anything that breaks those preconditions leaves
        # nothing trustworthy left to diagnose.
        return None

    # Obstruction runs BEFORE the contrast floor (adversarial review
    # 2026-08-08, F5): a one-sided aperture band dims gap rows into the
    # contrast check's 0.80-0.87 near-miss window, and the fog/dense-base
    # sentence would then send the reporter chasing their film stock when
    # the physically correct advice is to reseat the holder. The
    # obstruction check is the more specific signal, so it speaks first.
    checks = (
        lambda: _diagnose_alternate_pitch(evidence, direct, nominal_frame_rows),
        lambda: _diagnose_gap_geometry(direct, nominal_frame_rows),
        lambda: _diagnose_aperture_obstruction(rgb16, aperture),
        lambda: _diagnose_contrast_floor(
            transmission, nonuniformity, direct, rgb16, aperture
        ),
    )
    for check in checks:
        try:
            sentence = check()
        except Exception:
            # One check's own bug must not block the others, and must
            # never surface here as anything but "this check found
            # nothing".
            continue
        if sentence is not None:
            return sentence
    return None
