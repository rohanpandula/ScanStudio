"""Regression contracts for Rung 4 manual frame placement.

FEEDING-UX-LADDER-OVERNIGHT-20260807.md: the human supplies frame boundary
rows on an already-captured preview raster; this module keeps the physical
sanity checks. These tests exercise every validation gate plus the happy
path's exact result shape, independent of and never calling
detect_roll_frames/derive_transport_mapping.

Rewritten 2026-08-08 after adversarial review rejected the original: gate 4
used to require every single-row transport-table step within 3 rows of a
pick to be 40..45 native units, which real LS-5000 tables never satisfy (see
manual_frames.py's own module docstring for the measured lattice structure).
``_lattice_records`` below builds a synthetic table with that same
structure -- deterministic ~18-row-period selector-rollover and
sub-rollover jumps, computed through the real ``transport_native_origin``
identity, not approximated deltas -- so these tests, and the ones in this
file that exercise the transport-table gates specifically, can never again
diverge from hardware reality the way the plain 42-units/row ``_clean_
records`` table did.
"""

from __future__ import annotations

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass import manual_frames
from coolscanpy.protocol.ls5000_single_pass.roll_index import (
    IndexDecodeError,
    TRANSPORT_ORIGIN_CLAMP_REASON,
    TransportRecord,
    transport_native_origin,
)


def _synthetic_roll(
    frame_count: int,
    *,
    pitch: int = 143,
    leader: int = 24,
    tail: int = 24,
    gap_half: int = 3,
) -> tuple[np.ndarray, list[int]]:
    """Same construction as test_roll_index.py's own helper: textured cells
    separated by physical clear-film gaps ``2 * gap_half`` preview rows
    wide, centered on each boundary row. The leader and tail themselves are
    one wide clear-film run each (``leader``/``tail`` rows), never a
    ``gap_half``-narrow one -- this matters for tests that care whether a
    boundary's evidence run classifies as narrow.
    """

    boundaries = [leader + index * pitch for index in range(frame_count + 1)]
    height = boundaries[-1] + tail
    y = np.arange(height, dtype=np.int64)[:, None]
    x = np.arange(90, dtype=np.int64)[None, :]
    texture = (x * 173 + y * 71 + (x * y) % 997) % 7_000
    aperture = np.empty((height, 90, 3), dtype=np.int64)
    for channel, base in enumerate((7_000, 5_500, 4_000)):
        aperture[:, :, channel] = base + texture * (3 - channel) // 2
    clear_base = np.asarray((34_200, 25_500, 17_800), dtype=np.int64)
    clear_noise = ((x * 19 + y * 13) % 301 - 150)[:, :, None]
    aperture[: boundaries[0]] = clear_base + clear_noise[: boundaries[0]]
    aperture[boundaries[-1] :] = clear_base + clear_noise[boundaries[-1] :]
    for boundary in boundaries:
        start = max(0, boundary - gap_half)
        end = min(height, boundary + gap_half)
        aperture[start:end] = clear_base + clear_noise[start:end]
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16), boundaries


def _blank_roll(height: int) -> np.ndarray:
    """A raster with NO clear-film runs anywhere, so snap assist finds no
    evidence and every pick resolves through the no-narrow-run path."""

    y = np.arange(height, dtype=np.int64)[:, None]
    x = np.arange(90, dtype=np.int64)[None, :]
    texture = (x * 173 + y * 71 + (x * y) % 997) % 7_000
    aperture = np.empty((height, 90, 3), dtype=np.int64)
    for channel, base in enumerate((7_000, 5_500, 4_000)):
        aperture[:, :, channel] = base + texture * (3 - channel) // 2
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16)


def _clean_records(count: int) -> tuple[TransportRecord, ...]:
    """Same-traversal transport table stepping at exactly 42 native units/row.

    ``code=6*(row%18), selector=row//18`` is the standard synthetic-records
    convention used throughout this package's tests (test_worker.py,
    test_ls5000_roll_session.py); it decodes to ``native_origin = 42 * row``
    exactly. A perfectly smooth ramp -- useful for gates that have nothing
    to do with the transport table's own lattice structure, but never used
    below for a test that is specifically about that structure; see
    ``_lattice_records`` for those.
    """

    return tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(count)
    )


# One ~18-row lattice period's ordinary (non-rollover) code progression,
# transcribed from the archived 20260719-phoenix live capture inspected
# during this rework (rows 1-16 of its first full period): the code's low
# byte advances by 6 almost every row, with the high byte periodically
# absorbing part of that advance (the "sub-rollover" jumps -- +28, +84
# native units here, matching the task's own measured "-56/+98/+98/+0"
# class of jump; the exact sub-rollover magnitudes are a hardware
# implementation detail this generator does not need to reproduce exactly
# to be a faithful stress test of "mostly steady, occasionally not").
_LATTICE_CYCLE_CODES = (
    0x0006, 0x000C, 0x0012, 0x0018, 0x001E, 0x0024, 0x002A,
    0x0202, 0x0208, 0x020E, 0x0214, 0x021A, 0x0220, 0x0226,
    0x0406, 0x040C,
)


def _lattice_records(count: int) -> tuple[TransportRecord, ...]:
    """Same-traversal transport table with the REAL LS-5000 code lattice.

    Real live READ(0x8e) tables are not a smooth ramp: every ~18 rows, the
    selector rolls over, and the row at that rollover reports the NEXT
    selector's own low code one row early -- a jump of roughly +798 native
    units -- corrected the very next row by roughly -700 (measured on
    archived captures during this rework; see manual_frames.py's module
    docstring). Built from ``transport_native_origin`` itself rather than
    hand-picked deltas, so every record this returns decodes losslessly the
    same way a real table does, and the average rate across any complete
    18-row cycle is exactly 42 native units/row (756 native units -- one
    selector step -- over 18 rows), matching this driver's accepted
    40..45 physical band.
    """

    cycle_len = len(_LATTICE_CYCLE_CODES)
    period = cycle_len + 2
    records = []
    for row in range(count):
        position = row % period
        selector = row // period
        if position < cycle_len:
            code = _LATTICE_CYCLE_CODES[position]
        elif position == cycle_len:
            # Selector-rollover lookahead.
            code = 0x0412
            selector += 1
        else:
            # Selector-rollover correction.
            code = 0x0004
            selector += 1
        records.append(
            TransportRecord(
                row=row,
                code=code,
                selector=selector,
                native_origin=transport_native_origin(code, selector),
            )
        )
    return tuple(records)


def _known(rgb: np.ndarray) -> np.ndarray:
    return np.ones_like(rgb, dtype=bool)


def _spike(
    records: tuple[TransportRecord, ...], row: int, delta: int
) -> tuple[TransportRecord, ...]:
    patched = list(records)
    victim = patched[row]
    patched[row] = TransportRecord(
        row=victim.row,
        code=victim.code,
        selector=victim.selector,
        native_origin=victim.native_origin + delta,
    )
    return tuple(patched)


def _corrupt_span(
    records: tuple[TransportRecord, ...], start: int, end: int, magnitude: int
) -> tuple[TransportRecord, ...]:
    """Displace every record in [start, end) by an independent random value
    in [-magnitude, magnitude] -- a widespread, genuinely noisy corruption
    with no steady rate left inside it, unlike ``_spike`` (one row) or a
    uniform/alternating shift (either of which is really just a second
    internally-consistent trend a robust fit can still lock onto -- a
    uniform shift is caught by gate 5 instead, see
    test_non_affine_implied_scale_between_boundaries_refuses; a fixed
    alternation is, structurally, two interleaved uniform shifts, which a
    median-based fit can still separate).  A seeded RNG keeps this
    deterministic across runs."""

    rng = np.random.default_rng(20260808)
    patched = list(records)
    for row in range(start, end):
        victim = patched[row]
        signed_delta = int(rng.integers(-magnitude, magnitude + 1))
        patched[row] = TransportRecord(
            row=victim.row,
            code=victim.code,
            selector=victim.selector,
            native_origin=victim.native_origin + signed_delta,
        )
    return tuple(patched)


# --------------------------------------------------------------------------
# Happy path
# --------------------------------------------------------------------------


def test_exact_picks_produce_the_real_boundaries_with_no_snaps() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb,
        _known(rgb),
        boundaries,
        nominal_frame_rows=143,
        records=records,
    )

    assert result.snaps == ()
    detection = result.detection
    mapping = result.mapping

    assert detection.confidence == "medium"
    assert manual_frames.MANUAL_PLACEMENT_WARNING in detection.warnings
    assert detection.nominal_frame_rows == 143
    assert detection.candidate_cell_count == 6
    assert detection.manual_review_frames == (1, 2, 3, 4, 5, 6)
    assert len(detection.intervals) == 6
    assert len(detection.boundaries) == 7
    assert len(mapping.origins) == 6

    for interval in detection.intervals:
        assert interval.manual_review is True
        assert "user-picked" in interval.review_reasons

    for boundary in detection.boundaries:
        assert boundary.support == "user-picked"
        assert boundary.manual_review is True
        assert "user-picked" in boundary.review_reasons
        # The VISUAL boundary position is always the exact row the operator
        # placed, regardless of how its transport origin resolved.
    assert [b.output_row for b in detection.boundaries] == boundaries

    # Origins: boundary 0 sits in the wide (24-row) leader run, which is
    # NOT a narrow inter-frame gap, so it resolves at the picked row
    # itself. Boundaries 1-5 each sit at the center of an ordinary 6-row
    # inter-frame gap -- a narrow run -- so each resolves at that run's
    # OWN trailing edge (boundary + gap_half), mirroring
    # derive_transport_mapping's "direct-gap-trailing-row" convention on
    # the automatic path (see manual_frames.py's own docstring for why).
    gap_half = 3
    expected_lookup_rows = [boundaries[0]] + [b + gap_half for b in boundaries[1:6]]
    for frame, (origin, lookup_row) in enumerate(
        zip(mapping.origins, expected_lookup_rows), start=1
    ):
        assert origin.frame == frame
        assert origin.lookup_row == lookup_row
        assert origin.native_origin == 42 * lookup_row
        assert origin.method == "user-picked-row"
        assert origin.automatic is False
        assert origin.manual_review is True
        assert manual_frames.MANUAL_ORIGIN_REVIEW_REASON in origin.review_reasons


def test_picks_off_run_edges_snap_and_are_noted() -> None:
    # A shorter pitch than the happy-path test above so a boundary shifted
    # a few rows by snap assist cannot itself brush the fine-capture-window
    # ceiling (F2) -- this test is about snap mechanics, not that gate.
    rgb, boundaries = _synthetic_roll(6, pitch=100, leader=20, tail=20)
    records = _clean_records(len(rgb))
    picks = list(boundaries)
    # The evidence run at boundaries[2] is (boundary-3, boundary+3); picking
    # 2 rows short of its leading edge should snap onto that edge.
    picks[2] = boundaries[2] - 3 - 2

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), picks, nominal_frame_rows=100, records=records
    )

    assert len(result.snaps) == 1
    snap = result.snaps[0]
    assert snap.boundary_index == 2
    assert snap.requested_row == picks[2]
    assert snap.snapped_row == boundaries[2] - 3
    assert result.detection.boundaries[2].output_row == boundaries[2] - 3
    assert "snapped-to-clear-film-edge" in result.detection.boundaries[2].review_reasons


def test_snap_assist_disabled_keeps_the_operators_exact_picks() -> None:
    rgb, boundaries = _synthetic_roll(6, pitch=100, leader=20, tail=20)
    records = _clean_records(len(rgb))
    picks = list(boundaries)
    picks[2] = boundaries[2] - 3 - 2

    result = manual_frames.build_manual_detection(
        rgb,
        _known(rgb),
        picks,
        nominal_frame_rows=100,
        records=records,
        snap_assist=False,
    )

    assert result.snaps == ()
    assert result.detection.boundaries[2].output_row == picks[2]


def test_single_frame_minimum_two_boundaries_is_accepted() -> None:
    rgb, boundaries = _synthetic_roll(1, pitch=143)
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=records
    )

    assert len(result.detection.intervals) == 1
    assert len(result.mapping.origins) == 1


# --------------------------------------------------------------------------
# Structural gates
# --------------------------------------------------------------------------


def test_refuses_fewer_than_two_boundaries() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))

    with pytest.raises(IndexDecodeError, match="at least 2 boundary rows"):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), [boundaries[0]], nominal_frame_rows=143, records=records
        )


def test_refuses_non_monotonic_boundaries() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))

    with pytest.raises(IndexDecodeError, match="strictly increasing order"):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), [10, 5, 200], nominal_frame_rows=143, records=records
        )


def test_refuses_boundary_outside_the_raster() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))

    with pytest.raises(IndexDecodeError, match="inside the captured preview"):
        manual_frames.build_manual_detection(
            rgb,
            _known(rgb),
            [10, len(rgb) + 5],
            nominal_frame_rows=143,
            records=records,
        )


def test_refuses_more_than_forty_frames() -> None:
    height = 3_000
    rgb = np.zeros((height, 96, 3), dtype=np.uint16)
    records = _clean_records(height)
    boundaries = list(range(10, 10 + 42 * 60, 60))  # 42 boundaries -> 41 frames

    with pytest.raises(IndexDecodeError, match="at most 40 frames"):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=60, records=records
        )


def test_exactly_forty_frames_is_accepted() -> None:
    height = 3_000
    rgb = np.zeros((height, 96, 3), dtype=np.uint16)
    records = _clean_records(height)
    boundaries = list(range(10, 10 + 41 * 60, 60))  # 41 boundaries -> 40 frames

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=60, records=records
    )

    assert len(result.detection.intervals) == 40


# --------------------------------------------------------------------------
# Physical frame-height gates (F2 + F3): 15 mm floor, fine-capture-window
# ceiling, both enforced on the POST-SNAP rows.
# --------------------------------------------------------------------------


def test_refuses_a_frame_shorter_than_the_floor() -> None:
    height = 3_000
    rgb = np.zeros((height, 96, 3), dtype=np.uint16)
    records = _clean_records(height)

    with pytest.raises(IndexDecodeError, match=r"shorter than the 15 mm floor"):
        manual_frames.build_manual_detection(
            rgb,
            _known(rgb),
            [100, 110, 400],  # 10 rows, ~3 mm
            nominal_frame_rows=143,
            records=records,
        )


def test_refuses_a_frame_taller_than_the_fine_capture_window() -> None:
    """F2: the fine scan captures a fixed window; there is no multi-window
    capture. A frame taller than that window must refuse honestly instead
    of silently delivering a truncated capture."""

    height = 3_000
    rgb = np.zeros((height, 96, 3), dtype=np.uint16)
    records = _clean_records(height)

    with pytest.raises(
        IndexDecodeError,
        match=r"the scanner captures about 38\.8 mm per frame in one fine scan",
    ):
        manual_frames.build_manual_detection(
            rgb,
            _known(rgb),
            [100, 100 + manual_frames.FINE_CAPTURE_WINDOW_ROWS + 1, 2_900],
            nominal_frame_rows=143,
            records=records,
        )


def test_frame_exactly_at_the_ceiling_is_accepted() -> None:
    height = 3_000
    rgb = np.zeros((height, 96, 3), dtype=np.uint16)
    records = _clean_records(height)

    result = manual_frames.build_manual_detection(
        rgb,
        _known(rgb),
        [100, 100 + manual_frames.FINE_CAPTURE_WINDOW_ROWS],
        nominal_frame_rows=143,
        records=records,
    )

    assert len(result.detection.intervals) == 1


def test_half_frame_heights_are_accepted() -> None:
    rgb, boundaries = _synthetic_roll(4, pitch=71, leader=20, tail=20)
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=71, records=records
    )

    assert len(result.detection.intervals) == 4
    for interval in result.detection.intervals:
        assert interval.height_rows == 71


def test_panoramic_heights_are_now_refused() -> None:
    """F2 rework: panoramic acceptance is deliberately removed. The fine
    scan cannot capture a ~66 mm frame in one pass, so this must refuse
    rather than silently truncate -- manual mode still exists for film
    automatic detection cannot handle, but panoramic is no longer one of
    those cases."""

    rgb, boundaries = _synthetic_roll(3, pitch=250, leader=30, tail=30)
    records = _clean_records(len(rgb))

    with pytest.raises(
        IndexDecodeError, match="there is no way to capture a taller frame"
    ):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=250, records=records
        )


@pytest.mark.parametrize(
    ("picks", "clear_runs", "expected_match"),
    [
        # P1 (adversarial review probe): a raw pick pair exactly at the 56-
        # row floor, crafted so snap assist pulls them TOWARD each other,
        # eroding the post-snap height to 48 rows (~12.8 mm). Must refuse.
        ([100, 156], [(104, 110), (146, 153)], r"shorter than the 15 mm floor"),
        # P1b: a raw pick pair exactly at the (old) 280-row ceiling,
        # crafted so snap assist pushes them APART; under the new
        # fine-window ceiling this is refused even more decisively.
        ([100, 380], [(90, 97), (384, 390)], "there is no way to capture"),
    ],
)
def test_height_gate_runs_on_post_snap_rows(
    picks: list[int], clear_runs: list[tuple[int, int]], expected_match: str
) -> None:
    height = 700
    rgb = _blank_roll(height)
    clear = np.asarray((34_200, 25_500, 17_800), dtype=np.int64)
    rgb_i = rgb.astype(np.int64)
    for start, end in clear_runs:
        rgb_i[start:end, 2:92] = clear
    rgb = rgb_i.clip(0, 65_535).astype(np.uint16)
    records = _clean_records(height)

    with pytest.raises(IndexDecodeError, match=expected_match):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), picks, nominal_frame_rows=143, records=records
        )


# --------------------------------------------------------------------------
# Transport table gates (F1 + F4 rework)
# --------------------------------------------------------------------------


def test_isolated_table_row_anomaly_near_a_boundary_is_tolerated() -> None:
    """F1: a single-row transport-table anomaly -- exactly the shape a real
    lattice rollover takes -- near a boundary no longer refuses the whole
    placement. The local fit robustly resolves around it, the same way it
    resolves around the real lattice's own rollover rows.
    """

    rgb, boundaries = _synthetic_roll(6)
    spiked = _spike(_clean_records(len(rgb)), boundaries[2] + 1, 5_000)

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=spiked
    )

    # Frame 3 (0-indexed origin 2) anchors on boundaries[2]'s own narrow-run
    # trailing edge (boundaries[2] + 3), untouched by the spike at
    # boundaries[2] + 1, so it resolves exactly as if the spike were absent.
    assert result.mapping.origins[2].native_origin == 42 * (boundaries[2] + 3)


def test_widespread_table_corruption_near_a_boundary_still_refuses() -> None:
    """The tolerance F1 adds has a limit: when a boundary's ENTIRE local
    neighborhood is corrupted (not one isolated row), there is no steady
    rate left to find, and this must still refuse -- naming that specific
    edge, not blaming the physical strip for a table-reading problem."""

    rgb, boundaries = _synthetic_roll(6)
    # Wide enough to blank out this boundary's ENTIRE local-fit window
    # (LOCAL_FIT_WINDOW_RADIUS_ROWS on each side) with alternating noise,
    # leaving no steady-rate majority anywhere nearby to find.
    radius = manual_frames.LOCAL_FIT_WINDOW_RADIUS_ROWS
    corrupted = _corrupt_span(
        _clean_records(len(rgb)),
        boundaries[2] - radius - 5,
        boundaries[2] + radius + 5,
        30_000,
    )

    with pytest.raises(
        IndexDecodeError, match=r"doesn't settle into a steady rate"
    ):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=corrupted
        )


def test_non_affine_implied_scale_between_boundaries_refuses() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = list(_clean_records(len(rgb)))
    # A jump well clear of every boundary's own local-fit window (radius
    # LOCAL_FIT_WINDOW_RADIUS_ROWS; boundaries[2]=310, next boundary 453,
    # the jump sits at 380) still skews the relationship between those two
    # picks' own resolved origins -- a distinct failure mode from gate 4's
    # per-boundary local check.
    jump_row = boundaries[2] + 70
    for row in range(jump_row, len(records)):
        victim = records[row]
        records[row] = TransportRecord(
            row=victim.row,
            code=victim.code,
            selector=victim.selector,
            native_origin=victim.native_origin + 3_000,
        )

    with pytest.raises(IndexDecodeError, match="don't move at a steady rate"):
        manual_frames.build_manual_detection(
            rgb,
            _known(rgb),
            boundaries,
            nominal_frame_rows=143,
            records=tuple(records),
        )


def test_refuses_when_no_transport_records_are_supplied() -> None:
    rgb, boundaries = _synthetic_roll(6)

    with pytest.raises(IndexDecodeError, match="scanner position table"):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=()
        )


def test_lattice_table_boundaries_resolve_despite_rollover_neighbors() -> None:
    """F1's core regression: a REAL lattice table (see _lattice_records)
    carries a selector-rollover jump pair roughly every 18 rows -- so a
    typical local-fit window around any boundary contains at least one.
    Every boundary here must still be accepted, and every resolved origin
    must land on the true clean-ramp value (42 * lookup_row) despite that
    neighbor, the same way real archived captures do (see this rework's
    51-table regression in test_roll_index.py).
    """

    rgb, boundaries = _synthetic_roll(6)
    records = _lattice_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=records
    )

    assert len(result.mapping.origins) == 6
    for origin in result.mapping.origins:
        expected = transport_native_origin(
            records[origin.lookup_row].code, records[origin.lookup_row].selector
        )
        assert origin.native_origin == expected
        # Every resolved origin must itself be an exact, real table read --
        # never a value that does not correspond to any row in the table.
        assert origin.native_origin == records[origin.lookup_row].native_origin


def test_lattice_table_pick_exactly_on_a_rollover_row_is_tolerated() -> None:
    """The narrowest version of F1's fix: the operator's own pick (not just
    a nearby row) lands exactly on one of the lattice's rollover rows. No
    narrow evidence run is nearby (a blank roll), so the pick row itself is
    the anchor -- and it is NOT trustworthy on its own. Resolution must
    still succeed, via the no-narrow-run forward search (the same
    resolution shape a broad/weak-evidence pick always uses -- see
    _resolve_boundary_transport_origin's own docstring), landing on a
    nearby row the local fit does trust.
    """

    height = 900
    rgb = _blank_roll(height)
    records = _lattice_records(height)
    period = len(_LATTICE_CYCLE_CODES) + 2

    # A rollover-lookahead row (see _lattice_records) comfortably inside
    # the table, far from either raster edge or the terminal-tail concept
    # (records here have none).
    rollover_row = next(
        row for row in range(300, 340) if row % period == len(_LATTICE_CYCLE_CODES)
    )
    picks = [rollover_row - 100, rollover_row, rollover_row + 100]

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), picks, nominal_frame_rows=143, records=records
    )

    origin = result.mapping.origins[1]  # frame 2 starts at the rollover pick
    assert origin.lookup_row != rollover_row
    assert abs(origin.lookup_row - rollover_row) <= manual_frames.CANDIDATE_SEARCH_LOOKAHEAD_ROWS
    assert manual_frames.INFERRED_ORIGIN_REVIEW_REASON in origin.review_reasons
    assert origin.native_origin == records[origin.lookup_row].native_origin


# --------------------------------------------------------------------------
# Placement-wide affine-fit gate (F4)
# --------------------------------------------------------------------------


def test_placement_wide_drift_too_small_for_any_single_pair_still_refuses() -> None:
    """A gentle, CONTINUOUS bow across the whole table -- a mild quadratic
    offset, applied to every row, never a step -- curves too slowly to
    disturb any one boundary's own local-fit window (gate 4) or any one
    adjacent pair's implied scale (gate 5: a quadratic's local slope near
    either end of an 8-frame placement is still well inside the 40..45
    band), but a single straight line cannot fit a bow across the WHOLE
    placement, and that is exactly the worst-case residual only the
    placement-wide fit (>=3 boundaries) checks. (A step offset, tried
    first while writing this test, is a much blunter tool: any discrete
    jump has to sit inside SOME boundary's own window, so it trips gate 4
    or gate 5 instead of demonstrating gate 6 specifically -- a bow is the
    shape that is invisible to both of those and visible only in
    aggregate.) The k=0.0015 coefficient below was chosen empirically
    against this exact scenario: comfortably clear of gate 4 (which first
    breaks around k=0.003) with about a 1.5-row aggregate drift, comfortably
    past the gate 6 bounds (MAE 1.0, max 2.0 rows).
    """

    rgb, boundaries = _synthetic_roll(8, pitch=90, leader=30, tail=30)
    records = list(_clean_records(len(rgb)))
    center = len(records) / 2
    curvature = 0.0015
    for row in range(len(records)):
        victim = records[row]
        offset = int(round(curvature * (row - center) ** 2))
        records[row] = TransportRecord(
            row=victim.row,
            code=victim.code,
            selector=victim.selector,
            native_origin=victim.native_origin + offset,
        )
    records_tuple = tuple(records)

    with pytest.raises(
        IndexDecodeError, match="don't agree on one steady rate"
    ):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=90, records=records_tuple
        )


def test_two_boundary_placement_skips_the_placement_wide_gate() -> None:
    """Documented limitation (F4): two points always fit a line exactly, so
    the placement-wide MAE/max gate is vacuous for a single-frame
    placement and is not enforced -- gate 4 (each pick's own local
    neighborhood) and gate 5 (the one pairwise implied scale) are what
    validate a 2-boundary placement instead."""

    rgb, boundaries = _synthetic_roll(1, pitch=143)
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=records
    )

    # A 2x2 least-squares solve through exactly 2 points is analytically
    # exact but not always bit-exact in floating point.
    assert result.mapping.anchor_mae_rows == pytest.approx(0.0, abs=1e-6)
    assert result.mapping.anchor_max_error_rows == pytest.approx(0.0, abs=1e-6)


# --------------------------------------------------------------------------
# Idempotency (F3): build_manual_detection(final_rows) must accept its own
# output rows unchanged -- the batch capture wire and the worker's live-scan
# replay both resupply a prior call's own boundary output rows as the next
# call's raw picks.
# --------------------------------------------------------------------------


def test_build_manual_detection_is_idempotent_on_its_own_output() -> None:
    # Shorter pitch than the default 143: this test shifts a pick by 5 rows
    # before snapping, and the resulting frame must stay comfortably clear
    # of the fine-capture-window ceiling (F2) -- a different gate than the
    # one this test exercises.
    rgb, boundaries = _synthetic_roll(6, pitch=100, leader=20, tail=20)
    records = _lattice_records(len(rgb))
    picks = list(boundaries)
    picks[2] = boundaries[2] - 5  # off the run edge, exercises a real snap

    first = manual_frames.build_manual_detection(
        rgb, _known(rgb), picks, nominal_frame_rows=100, records=records
    )
    replay_rows = tuple(b.output_row for b in first.detection.boundaries)

    second = manual_frames.build_manual_detection(
        rgb, _known(rgb), replay_rows, nominal_frame_rows=100, records=records
    )

    assert second.snaps == ()
    assert [b.output_row for b in second.detection.boundaries] == list(replay_rows)
    assert [o.native_origin for o in second.mapping.origins] == [
        o.native_origin for o in first.mapping.origins
    ]
    assert [o.lookup_row for o in second.mapping.origins] == [
        o.lookup_row for o in first.mapping.origins
    ]


def test_idempotency_holds_after_a_gate_3_snap_erosion_scenario() -> None:
    """The exact P1 probe scenario (adversarial review), but confirming the
    NEW behavior end to end: gate 3 now refuses the eroded placement
    directly (test_height_gate_runs_on_post_snap_rows above), so there is
    no approved-then-unreplayable placement left to deadlock on -- replay
    of a placement that WAS accepted (picks safely clear of the floor)
    still round-trips cleanly."""

    height = 700
    rgb = _blank_roll(height)
    clear = np.asarray((34_200, 25_500, 17_800), dtype=np.int64)
    rgb_i = rgb.astype(np.int64)
    rgb_i[104:110, 2:92] = clear
    rgb_i[146:153, 2:92] = clear
    rgb = rgb_i.clip(0, 65_535).astype(np.uint16)
    records = _clean_records(height)
    # Snaps to (104, 152): 48 rows, short of the 56-row floor on purpose --
    # must refuse identically on first call and replay.
    picks = [100, 156]

    for _ in range(2):
        with pytest.raises(IndexDecodeError, match="shorter than the 15 mm floor"):
            manual_frames.build_manual_detection(
                rgb, _known(rgb), picks, nominal_frame_rows=143, records=records
            )


# --------------------------------------------------------------------------
# Shape/completeness gates
# --------------------------------------------------------------------------


def test_refuses_mismatched_raster_and_completeness_shapes() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))
    wrong_known = np.ones((len(rgb) - 1, 96, 3), dtype=bool)

    with pytest.raises(IndexDecodeError, match="shapes differ"):
        manual_frames.build_manual_detection(
            rgb, wrong_known, boundaries, nominal_frame_rows=143, records=records
        )


def test_refuses_an_incomplete_preview() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))
    known = _known(rgb)
    known[:200] = False

    with pytest.raises(manual_frames.IncompleteIndexError, match="row coverage"):
        manual_frames.build_manual_detection(
            rgb, known, boundaries, nominal_frame_rows=143, records=records
        )


def test_far_substitute_extrapolates_at_the_anchor_instead_of_drifting() -> None:
    """Re-review 2026-08-08, F-A: symmetric corruption around a narrow run's
    trailing edge left the local fit's median seed standing while pushing the
    nearest trusted row far from the anchor. The uncapped nearest-inlier
    substitute then silently displaced the origin by up to 22 rows through
    gates that all read zero residual. Beyond the 3-row cap the origin must
    now extrapolate AT the anchor from the surviving fit -- landing within
    one step of the true line -- and carry the clamp reason truthfully."""

    rgb, boundaries = _synthetic_roll(6)
    records = list(_clean_records(len(rgb)))
    target = boundaries[3]
    run_end = target + 3
    for offset in range(-12, 13):
        row = run_end + offset
        if not 0 <= row < len(records):
            continue
        if abs(offset) <= 8:
            spoiled = records[row]
            records[row] = TransportRecord(
                row=spoiled.row,
                code=spoiled.code,
                selector=spoiled.selector,
                native_origin=spoiled.native_origin
                + (30_000 if offset % 2 else -30_000),
            )

    result = manual_frames.build_manual_detection(
        rgb,
        np.ones_like(rgb, dtype=bool),
        list(boundaries),
        nominal_frame_rows=145,
        records=records,
    )

    frame4 = result.mapping.origins[3]
    assert abs(frame4.native_origin - 42 * run_end) <= 84
    assert TRANSPORT_ORIGIN_CLAMP_REASON in frame4.review_reasons or (
        manual_frames.INFERRED_ORIGIN_REVIEW_REASON in frame4.review_reasons
    )


def test_lookup_far_from_pick_earns_its_own_review_reason() -> None:
    """Re-review 2026-08-08, F-B: an 18-row clear band inside a frame pulls
    the trailing-edge anchor well away from the operator's line with no
    other signal; the divergence now carries an explicit review reason."""

    rgb, boundaries = _synthetic_roll(6)
    clear_row = rgb[boundaries[2]].copy()
    # Extend boundary 2's natural clear run (rows b-3..b+3) to a 20-row
    # band b-3..b+17 -- still narrow (<= 20), so the trailing-edge anchor
    # lands at b+17 while the operator's line stays at b: a 17-row
    # divergence with no snap and no other signal.
    rgb[boundaries[2] + 3 : boundaries[2] + 17] = clear_row
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb,
        np.ones_like(rgb, dtype=bool),
        list(boundaries),
        nominal_frame_rows=145,
        records=records,
    )

    frame3 = result.mapping.origins[2]
    assert abs(frame3.lookup_row - result.detection.boundaries[2].output_row) > 4
    assert (
        manual_frames.LOOKUP_FAR_FROM_PICK_REVIEW_REASON in frame3.review_reasons
    )
