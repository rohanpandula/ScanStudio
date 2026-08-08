"""Regression contracts for Rung 4 manual frame placement.

FEEDING-UX-LADDER-OVERNIGHT-20260807.md: the human supplies frame boundary
rows on an already-captured preview raster; this module keeps the physical
sanity checks. These tests exercise every validation gate plus the happy
path's exact result shape, independent of and never calling
detect_roll_frames/derive_transport_mapping.
"""

from __future__ import annotations

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass import manual_frames
from coolscanpy.protocol.ls5000_single_pass.roll_index import (
    IndexDecodeError,
    TransportRecord,
)


def _synthetic_roll(
    frame_count: int,
    *,
    pitch: int = 143,
    leader: int = 24,
    tail: int = 24,
) -> tuple[np.ndarray, list[int]]:
    """Same construction as test_roll_index.py's own helper: textured cells
    separated by physical clear-film gaps six preview rows wide, centered on
    each boundary row.
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
        start = max(0, boundary - 3)
        end = min(height, boundary + 3)
        aperture[start:end] = clear_base + clear_noise[start:end]
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16), boundaries


def _clean_records(count: int) -> tuple[TransportRecord, ...]:
    """Same-traversal transport table stepping at exactly 42 native units/row.

    ``code=6*(row%18), selector=row//18`` is the standard synthetic-records
    convention used throughout this package's tests (test_worker.py,
    test_ls5000_roll_session.py); it decodes to ``native_origin = 42 * row``
    exactly.
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

    for frame, (origin, boundary_row) in enumerate(
        zip(mapping.origins, boundaries), start=1
    ):
        assert origin.frame == frame
        assert origin.native_origin == 42 * boundary_row
        assert origin.method == "user-picked-row"
        assert origin.automatic is False
        assert origin.manual_review is True


def test_picks_off_run_edges_snap_and_are_noted() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))
    picks = list(boundaries)
    # The evidence run at boundaries[2] is (boundary-3, boundary+3); picking
    # 2 rows short of its leading edge should snap onto that edge.
    picks[2] = boundaries[2] - 3 - 2

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), picks, nominal_frame_rows=143, records=records
    )

    assert len(result.snaps) == 1
    snap = result.snaps[0]
    assert snap.boundary_index == 2
    assert snap.requested_row == picks[2]
    assert snap.snapped_row == boundaries[2] - 3
    assert result.detection.boundaries[2].output_row == boundaries[2] - 3
    assert "snapped-to-clear-film-edge" in result.detection.boundaries[2].review_reasons


def test_snap_assist_disabled_keeps_the_operators_exact_picks() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = _clean_records(len(rgb))
    picks = list(boundaries)
    picks[2] = boundaries[2] - 3 - 2

    result = manual_frames.build_manual_detection(
        rgb,
        _known(rgb),
        picks,
        nominal_frame_rows=143,
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


@pytest.mark.parametrize(
    ("start", "end"),
    [
        (100, 110),  # ~3 mm, below the 15 mm floor
        (100, 500),  # ~107 mm, above the 75 mm ceiling
    ],
)
def test_refuses_absurd_frame_heights(start: int, end: int) -> None:
    height = 3_000
    rgb = np.zeros((height, 96, 3), dtype=np.uint16)
    records = _clean_records(height)

    with pytest.raises(IndexDecodeError, match="outside the 15-75 mm range"):
        manual_frames.build_manual_detection(
            rgb,
            _known(rgb),
            [start, end, end + 200],
            nominal_frame_rows=143,
            records=records,
        )


def test_half_frame_heights_are_accepted() -> None:
    rgb, boundaries = _synthetic_roll(4, pitch=71, leader=20, tail=20)
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=71, records=records
    )

    assert len(result.detection.intervals) == 4
    for interval in result.detection.intervals:
        assert interval.height_rows == 71


def test_panoramic_heights_are_accepted() -> None:
    rgb, boundaries = _synthetic_roll(3, pitch=250, leader=30, tail=30)
    records = _clean_records(len(rgb))

    result = manual_frames.build_manual_detection(
        rgb, _known(rgb), boundaries, nominal_frame_rows=250, records=records
    )

    assert len(result.detection.intervals) == 3
    for interval in result.detection.intervals:
        assert interval.height_rows == 250


# --------------------------------------------------------------------------
# Transport table gates
# --------------------------------------------------------------------------


def test_single_record_spike_near_a_boundary_refuses_the_whole_placement() -> None:
    rgb, boundaries = _synthetic_roll(6)
    spiked = _spike(_clean_records(len(rgb)), boundaries[2] + 1, 5_000)

    with pytest.raises(IndexDecodeError, match="position readings look unreliable"):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=spiked
        )


def test_spike_message_names_the_ordinal_edge_and_no_frames_are_returned() -> None:
    rgb, boundaries = _synthetic_roll(6)
    spiked = _spike(_clean_records(len(rgb)), boundaries[2] + 1, 5_000)

    with pytest.raises(IndexDecodeError, match="3rd frame edge"):
        manual_frames.build_manual_detection(
            rgb, _known(rgb), boundaries, nominal_frame_rows=143, records=spiked
        )


def test_non_affine_implied_scale_between_boundaries_refuses() -> None:
    rgb, boundaries = _synthetic_roll(6)
    records = list(_clean_records(len(rgb)))
    # A jump well clear of every boundary's own +-3 row ramp-guard window
    # (boundaries[2]=310, next boundary 453; the jump sits at 380) still
    # skews the aggregate origins-vs-rows relationship between those two
    # picked boundaries -- a distinct failure mode from the local guard.
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
