"""Regression contracts for whole-roll index decoding and dynamic frame origins."""

import math
import os
import struct
from pathlib import Path

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass import roll_index as roll


# This one golden-data regression test wants a personal, non-git wire-capture
# archive (multi-GB) that is never shipped with this package. Point
# COOLSCANPY_SINGLE_PASS_WIRE_DIR at a directory containing the two files
# below to exercise it; otherwise it skips cleanly.
_WIRE_DIR_ENV = "COOLSCANPY_SINGLE_PASS_WIRE_DIR"
_wire_dir = os.environ.get(_WIRE_DIR_ENV)
CAMPAIGN_WIRE = Path(_wire_dir) if _wire_dir else None
GOLD36_PREVIEW = (
    CAMPAIGN_WIRE / "rgbi4-gold36-frame18-meter2-preview.bin" if CAMPAIGN_WIRE else None
)
GOLD36_TABLE = (
    CAMPAIGN_WIRE / "rgbi4-gold36-frame18-meter2-008e.bin" if CAMPAIGN_WIRE else None
)

# Optional never-committed live-attempt regression.  Point this at a banked
# preview attempt containing the worker's capture-preview.bin and
# capture-008e.bin artifacts.
_LIVE_PREVIEW_DIR_ENV = "COOLSCANPY_LIVE_PREVIEW_ATTEMPT_DIR"
_live_preview_dir = os.environ.get(_LIVE_PREVIEW_DIR_ENV)
LIVE_PREVIEW_ATTEMPT = Path(_live_preview_dir) if _live_preview_dir else None
LIVE_PREVIEW = (
    LIVE_PREVIEW_ATTEMPT / "capture-preview.bin" if LIVE_PREVIEW_ATTEMPT else None
)
LIVE_TABLE = LIVE_PREVIEW_ATTEMPT / "capture-008e.bin" if LIVE_PREVIEW_ATTEMPT else None


def _encode_index(rgb16: np.ndarray) -> bytes:
    assert rgb16.shape[1:] == (96, 3)
    assert rgb16.shape[0] % 2 == 0
    blocks = np.zeros((rgb16.shape[0] // 2, roll.INDEX_BLOCK_WORDS), dtype=np.uint16)
    blocks[:, 0:96] = rgb16[0::2, :, 0]
    blocks[:, 96:192] = rgb16[0::2, :, 1]
    blocks[:, 192:288] = rgb16[0::2, :, 2]
    blocks[:, 512:608] = rgb16[1::2, :, 0]
    blocks[:, 608:704] = rgb16[1::2, :, 1]
    blocks[:, 704:800] = rgb16[1::2, :, 2]
    blocks[:, 800::2] = roll.INDEX_TRAILER_MARK
    blocks[:, 801::2] = np.arange(
        roll.INDEX_TRAILER_COUNTER0,
        roll.INDEX_TRAILER_COUNTER0 + roll.INDEX_TRAILER_WORDS // 2,
        dtype=np.uint16,
    )
    return blocks.astype(">u2", copy=False).tobytes()


def _live_extent(usable_rows: int) -> bytes:
    records = bytearray()
    for row in range(usable_rows):
        records.extend(struct.pack(">HH", 6 * (row % 18), row // 18))
    total = 8 + len(records)
    return b"\x00\x8e\x00\x00" + total.to_bytes(2, "big") + b"\x00\x00" + bytes(records)


def _synthetic_roll(
    frame_count: int,
    *,
    pitch: int = 143,
    leader: int = 24,
    tail: int = 24,
) -> tuple[np.ndarray, list[int]]:
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
        aperture[max(0, boundary - 3) : min(height, boundary + 3)] = (
            clear_base + clear_noise[max(0, boundary - 3) : min(height, boundary + 3)]
        )
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16), boundaries


def _detect(
    rgb: np.ndarray,
    *,
    expected_frame_count: int | None = None,
) -> roll.RollDetection:
    return roll.detect_roll_frames(
        rgb,
        np.ones_like(rgb, dtype=bool),
        nominal_frame_rows=145,
        expected_frame_count=expected_frame_count,
    )


def test_complete_index_bytes_decode_every_rgb_row_and_validate_sync() -> None:
    rgb = np.arange(20 * 96 * 3, dtype=np.uint16).reshape(20, 96, 3)
    stream = _encode_index(rgb)
    geometry = roll.IndexGeometry(97, 4000, 41, 3946, 20, 96, 20, 2048, len(stream))

    decoded, known, report = roll.decode_full_index_bytes(stream, geometry)

    np.testing.assert_array_equal(decoded, rgb)
    assert known.all()
    assert report["valid_trailers"] == 10
    assert report["odd_housekeeping"] == "canonical-aa55-counter"
    with pytest.raises(roll.IncompleteIndexError, match="exactly"):
        roll.decode_full_index_bytes(stream[:-1], geometry)


def test_complete_index_accepts_the_stable_observed_odd_housekeeping_variant() -> None:
    rgb = np.arange(20 * 96 * 3, dtype=np.uint16).reshape(20, 96, 3)
    rows = np.frombuffer(_encode_index(rgb), dtype=">u2").copy().reshape(20, -1)
    variant = (np.arange(roll.INDEX_TRAILER_WORDS, dtype=np.uint16) * 6 + 8).astype(
        np.uint16
    )
    rows[1::2, roll.INDEX_RGB_WORDS_PER_ROW :] = variant
    stream = rows.astype(">u2", copy=False).tobytes()
    geometry = roll.IndexGeometry(97, 4000, 41, 3946, 20, 96, 20, 2048, len(stream))

    decoded, known, report = roll.decode_full_index_bytes(stream, geometry)

    np.testing.assert_array_equal(decoded, rgb)
    assert known.all()
    assert report["odd_housekeeping"] == "stable-observed"


@pytest.mark.parametrize(
    ("geometry", "message"),
    [
        (
            roll.IndexGeometry(97, 4000, 41, 3946, 20, 95, 20, 2048, 20 * 1024),
            "width must be 96",
        ),
        (
            roll.IndexGeometry(97, 4000, 41, 3946, 20, 96.0, 20, 2048, 20 * 1024),
            "width must be 96",
        ),
        (
            roll.IndexGeometry(97, 4000, 41, 3946, 20, 96, 20, 1024, 20 * 1024),
            "block size must be 2048",
        ),
        (
            roll.IndexGeometry(97, 4000, 41, 3946, 19, 96, 19, 2048, 19 * 1024),
            "positive even row count",
        ),
        (
            roll.IndexGeometry(97, 4000, 41, 3946, 20, 96, 20, 2048, 18 * 1024),
            "allocation mismatch",
        ),
        (
            roll.IndexGeometry(97, 4000, 41, 3946, 20, 96, 20, 2048, float(20 * 1024)),
            "integer byte count",
        ),
    ],
)
def test_exported_index_decoder_refuses_malformed_geometry(
    geometry: roll.IndexGeometry,
    message: str,
) -> None:
    valid_rgb = np.zeros((20, 96, 3), dtype=np.uint16)
    stream = _encode_index(valid_rgb)
    with pytest.raises(roll.IndexDecodeError, match=message):
        roll.decode_full_index_bytes(stream, geometry)


@pytest.mark.parametrize(
    ("leader", "tail", "candidate_slots", "content_ends"),
    [
        (17, 21, 37, (36,)),
        (300, 260, 40, (38, 39)),
        (83, 47, 37, (36,)),
    ],
)
def test_variable_leader_and_trailer_are_visible_without_guessing_roll_count(
    leader: int,
    tail: int,
    candidate_slots: int,
    content_ends: tuple[int, ...],
) -> None:
    rgb, boundaries = _synthetic_roll(36, leader=leader, tail=tail)

    detection = _detect(rgb)

    assert len(detection.intervals) == candidate_slots
    assert len(detection.boundaries) == candidate_slots + 1
    assert detection.content_end_candidates == content_ends
    assert detection.count_confidence == "user-selection-required"
    assert detection.candidate_slot_count == candidate_slots
    assert detection.confidence == "high"
    assert detection.pitch_rows == pytest.approx(143.0, abs=0.25)
    assert all(
        min(abs(item.output_row - expected) for item in detection.boundaries) <= 1
        for expected in boundaries
    )


def test_complete_row_zero_leading_cell_is_not_silently_renumbered() -> None:
    rgb, _boundaries = _synthetic_roll(6, leader=0, tail=3)

    detection = _detect(rgb)

    complete = [
        interval
        for interval in detection.intervals
        if interval.coverage_fraction == 1.0 and interval.count_supported
    ]
    assert [interval.frame for interval in complete] == [1, 2, 3, 4, 5, 6]
    assert complete[0].start_row <= 1
    assert complete[-1].end_row == pytest.approx(858, abs=1)
    # Preserve the existing advisory tail: it remains visible and fail-closed
    # instead of being mistaken for a seventh complete exposure.
    assert detection.intervals[-1].coverage_fraction < 0.50
    assert detection.intervals[-1].manual_review
    assert roll.scanner_addressable_interval_count(detection.intervals) == 6


def test_scanner_addressable_interval_count_keeps_interior_manual_cells() -> None:
    rgb, boundaries = _synthetic_roll(6, leader=0, tail=3)
    # Preserve the final sliver, but make an interior cell require review.
    rgb[boundaries[2] : boundaries[3], 2:92] = np.asarray(
        (34_200, 25_500, 17_800), dtype=np.uint16
    )

    detection = _detect(rgb)

    assert not detection.intervals[2].count_supported
    assert detection.intervals[-1].coverage_fraction < 0.50
    # Only the terminal incomplete suffix is trimmed; a full interior cell is
    # still represented for manual review rather than silently dropping later
    # frames.
    assert roll.scanner_addressable_interval_count(detection.intervals) == 6


def test_clipped_leading_cell_remains_excluded_fail_closed() -> None:
    complete_rgb, _boundaries = _synthetic_roll(6, leader=0, tail=24)
    clipped_rgb = complete_rgb[1:]

    detection = _detect(clipped_rgb)

    # Cropping even one row moves the fitted leading boundary outside the
    # captured raster.  The near-complete leading cell must not be promoted
    # ahead of the first wholly scanner-addressable lattice start.
    assert detection.frame_starts[0] > 100
    complete = [
        interval
        for interval in detection.intervals
        if interval.coverage_fraction == 1.0 and interval.count_supported
    ]
    assert len(complete) == 5


def test_channel_gain_changes_do_not_move_detected_boundaries() -> None:
    rgb, _boundaries = _synthetic_roll(24, leader=41, tail=67)
    baseline = _detect(rgb)
    gained = np.clip(
        rgb.astype(np.float64) * np.asarray((0.70, 1.15, 1.30)), 0, 65_535
    ).astype(np.uint16)
    adjusted = _detect(gained)
    assert [item.output_row for item in adjusted.boundaries] == [
        item.output_row for item in baseline.boundaries
    ]


def test_one_true_interior_blank_cell_is_flagged_without_renumbering() -> None:
    rgb, boundaries = _synthetic_roll(24, leader=17, tail=21)
    baseline = _detect(rgb)
    blank_frame = 12
    rgb[boundaries[blank_frame - 1] : boundaries[blank_frame], 2:92] = np.asarray(
        (34_200, 25_500, 17_800), dtype=np.uint16
    )

    detection = _detect(rgb)

    assert len(detection.intervals) == 25
    assert detection.frame_starts == baseline.frame_starts
    assert detection.bridged_cell_count == 0
    interval = detection.intervals[blank_frame - 1]
    assert not interval.count_supported
    assert not interval.count_bridged
    assert interval.manual_review
    assert "low-content-support" in interval.review_reasons


def test_blank_tail_cells_do_not_bridge_to_a_single_dense_artifact() -> None:
    pitch = 143
    rgb, boundaries = _synthetic_roll(
        36,
        pitch=pitch,
        leader=128,
        tail=3 * pitch + 21,
    )
    terminal = boundaries[-1]
    scene_cell = rgb[boundaries[4] : boundaries[5], 2:92].copy()
    rgb[terminal + 2 * pitch : terminal + 3 * pitch, 2:92] = scene_cell

    detection = _detect(rgb, expected_frame_count=36)

    assert len(detection.intervals) == 40
    assert detection.content_end_candidates == (39,)
    assert detection.bridged_cell_count == 0
    assert detection.confidence == "high"
    assert not detection.expected_frame_count_matches
    matching = _detect(rgb, expected_frame_count=39)
    assert matching.frame_starts == detection.frame_starts
    assert matching.expected_frame_count_matches


def test_missing_terminal_physical_gap_keeps_geometry_for_user_selection() -> None:
    rgb, boundaries = _synthetic_roll(24, leader=17, tail=21)
    terminal = boundaries[-1]
    observed_tail = len(rgb) - (terminal - 3)
    replacement = rgb[terminal - observed_tail - 6 : terminal - 6, 2:92].copy()
    rgb[terminal - 3 :, 2:92] = replacement
    detection = _detect(rgb)
    assert len(detection.intervals) == 25
    assert detection.content_end_candidates == ()
    assert detection.count_confidence == "user-selection-required"
    assert detection.intervals[-1].manual_review


def _erase_terminal_gap(rgb: np.ndarray, boundaries: list[int]) -> np.ndarray:
    altered = rgb.copy()
    terminal = boundaries[-1]
    observed_tail = len(altered) - (terminal - 3)
    replacement = altered[terminal - observed_tail - 6 : terminal - 6, 2:92].copy()
    altered[terminal - 3 :, 2:92] = replacement
    return altered


def test_expected_count_is_informational_when_terminal_is_missing() -> None:
    rgb, boundaries = _synthetic_roll(24, leader=17, tail=21)
    altered = _erase_terminal_gap(rgb, boundaries)

    detection = _detect(altered, expected_frame_count=24)

    assert len(detection.intervals) == 25
    assert detection.confidence == "high"
    assert detection.expected_frame_count == 24
    assert detection.count_confirmation == "candidate-slots-user-selection"
    assert detection.expected_frame_count_matches is False
    assert detection.boundaries[-1].manual_review
    assert 24 in detection.manual_review_frames
    assert (
        detection.diagnostics()["count_confirmation"]
        == "candidate-slots-user-selection"
    )
    for wrong_count in (23, 25):
        warned = _detect(altered, expected_frame_count=wrong_count)
        assert warned.frame_starts == detection.frame_starts
        assert warned.expected_frame_count_matches is False
        assert any("informational" in warning for warning in warned.warnings)


@pytest.mark.parametrize("frame_count,leader,tail", [(8, 91, 47), (36, 300, 21)])
def test_expected_count_never_changes_candidate_geometry(
    frame_count: int,
    leader: int,
    tail: int,
) -> None:
    rgb, boundaries = _synthetic_roll(frame_count, leader=leader, tail=tail)

    detection = _detect(
        _erase_terminal_gap(rgb, boundaries),
        expected_frame_count=frame_count,
    )

    baseline = _detect(_erase_terminal_gap(rgb, boundaries))
    assert detection.frame_starts == baseline.frame_starts
    assert detection.confidence == "high"
    assert detection.count_confirmation == "candidate-slots-user-selection"
    assert detection.expected_frame_count_matches is False


def test_missing_internal_boundary_is_flagged_without_renumbering() -> None:
    rgb, boundaries = _synthetic_roll(24, leader=17, tail=21)
    altered = _erase_terminal_gap(rgb, boundaries)
    internal = boundaries[8]
    altered[internal - 3 : internal + 3, 2:92] = altered[
        internal + 8 : internal + 14, 2:92
    ]

    detection = _detect(altered, expected_frame_count=24)
    assert len(detection.intervals) == 25
    assert 8 in detection.manual_review_frames
    assert 9 in detection.manual_review_frames
    assert detection.expected_frame_count_matches is False


@pytest.mark.parametrize("expected", [True, 1, 41])
def test_expected_count_must_be_an_integer_in_supported_range(expected: int) -> None:
    rgb, _boundaries = _synthetic_roll(8, leader=91, tail=47)
    with pytest.raises(roll.IndexDecodeError, match="integer in 2..40"):
        _detect(rgb, expected_frame_count=expected)


def _boundary(
    index: int,
    row: int,
    *,
    support: str = "direct",
    evidence_run: tuple[int, int] | None = None,
) -> roll.GapBoundary:
    evidence_run = evidence_run or (row - 3, row + 4)
    reasons = () if support == "direct" else ("broad-clear-region",)
    return roll.GapBoundary(
        index=index,
        output_row=row,
        fitted_row=float(row),
        evidence=0.9,
        transmission=0.95,
        nonuniformity=0.08,
        support=support,
        evidence_run=evidence_run,
        manual_review=bool(reasons),
        review_reasons=reasons,
    )


def test_same_traversal_transport_table_maps_dynamic_frame_origins() -> None:
    records = roll.parse_live_transport_records_bytes(
        _live_extent(900), maximum_rows=900
    )
    rows = [20, 163, 306, 449, 592]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    boundaries[2] = _boundary(
        2, rows[2], support="cadence-broad", evidence_run=(286, 326)
    )

    mapping = roll.derive_transport_mapping(boundaries, len(rows), records)

    assert mapping.native_units_per_preview_row == pytest.approx(42.0)
    assert mapping.origins[1].lookup_row == rows[1] + 4
    assert mapping.origins[2].manual_review
    assert "transport-origin-inferred" in mapping.origins[2].review_reasons
    assert mapping.origins[2].native_origin == 42 * (rows[2] + 4)


def test_transport_envelope_and_anchor_residuals_fail_closed() -> None:
    with pytest.raises(roll.IndexDecodeError, match="0x8e"):
        roll.parse_live_transport_records_bytes(_live_extent(50)[:-1], maximum_rows=50)
    records = roll.parse_live_transport_records_bytes(
        _live_extent(1_200), maximum_rows=1_200
    )
    rows = [20, 163, 306, 449, 592, 735]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    boundaries[3] = _boundary(3, rows[3], evidence_run=(rows[3] - 3, rows[3] + 24))
    with pytest.raises(roll.IndexDecodeError, match="transport anchor residual"):
        roll.derive_transport_mapping(boundaries, len(rows), records)


def test_transport_anchor_fit_accepts_bounded_live_leading_anchor_divergence() -> None:
    records = [
        roll.TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(1_500)
    ]
    rows = [8 + index * 143 for index in range(10)]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    first_lookup_row = boundaries[0].evidence_run[1]
    first = records[first_lookup_row]
    records[first_lookup_row] = roll.TransportRecord(
        row=first.row,
        code=first.code,
        selector=first.selector,
        native_origin=first.native_origin + 165,
    )

    mapping = roll.derive_transport_mapping(boundaries, len(rows), records)

    assert mapping.anchor_mae_rows == pytest.approx(0.0)
    assert mapping.anchor_max_error_rows == pytest.approx(0.0)
    assert mapping.origins[0].native_origin == first.native_origin + 165
    assert mapping.origins[0].affine_residual_rows == pytest.approx(-165 / 42)
    assert mapping.origins[0].manual_review
    assert not mapping.origins[0].automatic
    assert roll.LEADING_ANCHOR_REVIEW_REASON in mapping.origins[0].review_reasons


def test_transport_anchor_fit_still_rejects_bounded_mean_with_large_endpoint_error() -> None:
    records = [
        roll.TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(1_500)
    ]
    rows = [8 + index * 143 for index in range(10)]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    first_lookup_row = boundaries[0].evidence_run[1]
    first = records[first_lookup_row]
    records[first_lookup_row] = roll.TransportRecord(
        row=first.row,
        code=first.code,
        selector=first.selector,
        native_origin=first.native_origin + 211,
    )

    with pytest.raises(roll.IndexDecodeError, match="leading transport anchor"):
        roll.derive_transport_mapping(boundaries, len(rows), records)


def test_terminal_high_bit_suffix_cannot_poison_short_strip_mapping() -> None:
    records = [
        roll.TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(720)
    ]
    rows = [143, 286, 428, 571, 715]
    lookup_rows = [146, 289, 430, 574, 718]
    native_origins = [6_188, 12_250, 18_228, 24_332, 43_946]
    for lookup_row, native_origin in zip(
        lookup_rows,
        native_origins,
        strict=True,
    ):
        records[lookup_row] = roll.TransportRecord(
            row=lookup_row,
            code=6 * (lookup_row % 18),
            selector=lookup_row // 18,
            native_origin=native_origin,
        )
    for row in range(718, 720):
        records[row] = roll.TransportRecord(
            row=row,
            code=0x8330,
            selector=31,
            native_origin=43_946,
        )
    boundaries = [
        _boundary(
            index,
            row,
            evidence_run=(row - 3, lookup_row),
        )
        for index, (row, lookup_row) in enumerate(zip(rows, lookup_rows, strict=True))
    ]

    mapping = roll.derive_transport_mapping(boundaries, len(rows), records)

    assert roll.terminal_transport_tail_start(records) == 718
    assert mapping.native_units_per_preview_row == pytest.approx(42.36337707)
    assert [origin.native_origin for origin in mapping.origins[:4]] == native_origins[
        :4
    ]
    terminal = mapping.origins[4]
    # The garbage tail record (native_origin 43_946, a ~24k unit jump beyond
    # the healthy ramp) is never surfaced as this slot's resolved origin: the
    # clamp replaces it with the interior fit's own extrapolation at this
    # boundary's row, so the value is reconstructible from the fit alone.
    expected_clamped_origin = math.floor(
        mapping.native_intercept
        + mapping.native_units_per_preview_row * terminal.boundary_output_row
        + 0.5
    )
    assert terminal.native_origin == expected_clamped_origin
    assert terminal.native_origin != 43_946
    assert terminal.lookup_row == 718
    assert terminal.automatic is False
    assert terminal.manual_review is True
    assert terminal.affine_residual_rows == pytest.approx(0.0, abs=0.02)
    assert "terminal-transport-tail" in terminal.review_reasons
    assert roll.TRANSPORT_ORIGIN_CLAMP_REASON in terminal.review_reasons


def test_terminal_suffix_requires_three_pre_tail_direct_anchors() -> None:
    records = [
        roll.TransportRecord(row=row, code=0, selector=0, native_origin=42 * row)
        for row in range(310)
    ]
    records[-1] = roll.TransportRecord(
        row=309,
        code=0x8330,
        selector=31,
        native_origin=43_946,
    )
    rows = [20, 163, 305]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]

    with pytest.raises(roll.IndexDecodeError, match="three direct physical gaps"):
        roll.derive_transport_mapping(boundaries, len(rows), records)


def test_inferred_boundary_wholly_inside_terminal_suffix_is_truncated() -> None:
    records = [
        roll.TransportRecord(row=row, code=0, selector=0, native_origin=42 * row)
        for row in range(100)
    ]
    for row in range(80, 100):
        records[row] = roll.TransportRecord(
            row=row,
            code=0x8330,
            selector=31,
            native_origin=43_946,
        )
    boundaries = [_boundary(index, row) for index, row in enumerate((10, 30, 50))]
    boundaries.append(_boundary(3, 80, support="cadence-broad", evidence_run=(77, 83)))

    mapping = roll.derive_transport_mapping(boundaries, len(boundaries), records)

    assert roll.terminal_transport_tail_start(records) == 80
    assert [origin.automatic for origin in mapping.origins[:3]] == [True, True, True]
    inferred_tail = mapping.origins[3]
    assert inferred_tail.method == "affine-guided-local-lookup"
    assert inferred_tail.lookup_row >= 80
    assert inferred_tail.automatic is False
    assert "terminal-transport-tail" in inferred_tail.review_reasons


def test_all_high_bit_transport_table_has_no_usable_pre_tail_anchors() -> None:
    records = [
        roll.TransportRecord(
            row=row,
            code=0x8330,
            selector=31,
            native_origin=43_946,
        )
        for row in range(100)
    ]
    boundaries = [_boundary(index, row) for index, row in enumerate((10, 30, 50))]

    with pytest.raises(roll.IndexDecodeError, match="three direct physical gaps"):
        roll.derive_transport_mapping(boundaries, len(boundaries), records)


def test_one_record_terminal_suffix_preserves_prefix_and_truncates_tail() -> None:
    records = [
        roll.TransportRecord(row=row, code=0, selector=0, native_origin=42 * row)
        for row in range(100)
    ]
    records[99] = roll.TransportRecord(
        row=99,
        code=0x8330,
        selector=31,
        native_origin=43_946,
    )
    boundaries = [_boundary(index, row) for index, row in enumerate((20, 40, 60))]
    boundaries.append(_boundary(3, 95, evidence_run=(92, 99)))

    mapping = roll.derive_transport_mapping(boundaries, len(boundaries), records)

    assert roll.terminal_transport_tail_start(records) == 99
    assert [origin.native_origin for origin in mapping.origins[:3]] == [
        42 * 24,
        42 * 44,
        42 * 64,
    ]
    assert [origin.automatic for origin in mapping.origins[:3]] == [True, True, True]
    tail = mapping.origins[3]
    assert tail.lookup_row == 99
    assert tail.automatic is False
    assert "terminal-transport-tail" in tail.review_reasons


def _expected_extrapolated_origin(mapping: roll.TransportMapping, origin) -> int:
    """Recompute the interior fit's own prediction at one origin's boundary
    row, the same way the terminal-tail/residual clamp does internally."""

    return math.floor(
        mapping.native_intercept
        + mapping.native_units_per_preview_row * origin.boundary_output_row
        + 0.5
    )


def test_last_slot_terminal_tail_clamp_extrapolates_instead_of_garbage_record() -> None:
    """Defect 4: a last-frame lookup row inside the terminal transport tail
    must never surface the garbage record's native_origin.  The clamp
    replaces it with the interior fit's own extrapolation and forces manual
    review with a warning that names the clamp, while leaving the earlier,
    healthy slots and the raw lookup_row/code/selector diagnostics alone."""
    records = [
        roll.TransportRecord(row=row, code=0, selector=0, native_origin=42 * row)
        for row in range(600)
    ]
    for row in range(560, 600):
        records[row] = roll.TransportRecord(
            row=row,
            code=0x8330,
            selector=31,
            native_origin=43_946,
        )
    rows = [20, 163, 306, 449]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    # This boundary keeps "direct" physical-gap support; only its transport
    # lookup row happens to land inside the terminal tail, exactly as
    # observed live when the trailing edge clears the drive mid-last-frame.
    boundaries[3] = _boundary(3, rows[3], evidence_run=(rows[3] - 3, 565))

    mapping = roll.derive_transport_mapping(boundaries, len(rows), records)

    assert roll.terminal_transport_tail_start(records) == 560
    assert [origin.native_origin for origin in mapping.origins[:3]] == [
        42 * 24,
        42 * 167,
        42 * 310,
    ]
    assert [origin.automatic for origin in mapping.origins[:3]] == [True, True, True]
    last = mapping.origins[3]
    assert last.method == "direct-gap-trailing-row"
    assert last.lookup_row == 565
    assert last.code == records[565].code
    assert last.selector == records[565].selector
    assert last.native_origin != 43_946
    assert last.native_origin == _expected_extrapolated_origin(mapping, last)
    assert last.native_origin > mapping.origins[2].native_origin
    assert last.automatic is False
    assert last.manual_review is True
    assert last.affine_residual_rows == pytest.approx(0.0, abs=0.01)
    assert "terminal-transport-tail" in last.review_reasons
    assert roll.TRANSPORT_ORIGIN_CLAMP_REASON in last.review_reasons


def test_non_tail_high_residual_record_is_also_clamped() -> None:
    """The residual backstop protects slots the high-bit tail heuristic does
    not catch: an isolated, non-terminal anomaly with no 0x8000 marker at all
    must still be clamped once its resolved record disagrees with the
    interior fit by more than the interior anchor bound."""
    records = [
        roll.TransportRecord(row=row, code=0, selector=0, native_origin=42 * row)
        for row in range(500)
    ]
    for row in range(230, 238):
        records[row] = roll.TransportRecord(
            row=row, code=0, selector=0, native_origin=42 * row + 20_000
        )
    rows = [20, 163, 229, 449]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    # A broad/cut gap is never "direct": resolution falls back to the local
    # affine-guided lookup, whose trailing search window after the fitted
    # centre lands entirely inside the anomalous run.
    boundaries[2] = _boundary(2, rows[2], support="cadence-broad")

    mapping = roll.derive_transport_mapping(boundaries, len(rows), records)

    assert roll.terminal_transport_tail_start(records) is None
    healthy = (mapping.origins[0], mapping.origins[1], mapping.origins[3])
    assert [origin.automatic for origin in healthy] == [True, True, True]
    anomalous = mapping.origins[2]
    assert anomalous.method == "affine-guided-local-lookup"
    assert anomalous.native_origin < 20_000
    assert anomalous.native_origin == _expected_extrapolated_origin(mapping, anomalous)
    assert anomalous.automatic is False
    assert anomalous.manual_review is True
    assert "terminal-transport-tail" not in anomalous.review_reasons
    assert roll.TRANSPORT_ORIGIN_CLAMP_REASON in anomalous.review_reasons
    # Origins must stay strictly increasing across the clamped slot.
    assert (
        mapping.origins[1].native_origin
        < anomalous.native_origin
        < mapping.origins[3].native_origin
    )


def test_leading_anchor_divergence_is_never_clamped() -> None:
    """The leading anchor keeps its own wider, separately reviewed divergence
    allowance (MAXIMUM_LEADING_ANCHOR_ERROR_ROWS); the terminal-tail/residual
    clamp must never re-litigate that already-tolerated case even though its
    residual against the interior fit can exceed the interior anchor bound
    by design."""
    records = [
        roll.TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(1_500)
    ]
    rows = [8 + index * 143 for index in range(10)]
    boundaries = [_boundary(index, row) for index, row in enumerate(rows)]
    first_lookup_row = boundaries[0].evidence_run[1]
    first = records[first_lookup_row]
    records[first_lookup_row] = roll.TransportRecord(
        row=first.row,
        code=first.code,
        selector=first.selector,
        native_origin=first.native_origin + 165,
    )

    mapping = roll.derive_transport_mapping(boundaries, len(rows), records)

    leading = mapping.origins[0]
    assert abs(leading.affine_residual_rows) > roll.MAXIMUM_INTERIOR_ANCHOR_ERROR_ROWS
    assert abs(leading.affine_residual_rows) < roll.MAXIMUM_LEADING_ANCHOR_ERROR_ROWS
    assert leading.native_origin == first.native_origin + 165
    assert roll.LEADING_ANCHOR_REVIEW_REASON in leading.review_reasons
    assert roll.TRANSPORT_ORIGIN_CLAMP_REASON not in leading.review_reasons


@pytest.mark.skipif(
    LIVE_PREVIEW is None
    or LIVE_TABLE is None
    or not LIVE_PREVIEW.is_file()
    or not LIVE_TABLE.is_file(),
    reason=(
        "banked live preview attempt is unavailable; set "
        f"{_LIVE_PREVIEW_DIR_ENV} to its artifact directory"
    ),
)
def test_banked_live_row_zero_strip_retains_all_six_complete_intervals() -> None:
    geometry = roll.IndexGeometry(
        requested_resolution=97,
        native_resolution=4_000,
        pitch=41,
        native_width=3_946,
        native_height=250_278,
        width=96,
        height=6_104,
        block_bytes=2_048,
        expected_stream_bytes=6_250_496,
    )
    table, usable_rows = roll.validate_live_0x8e_bytes(
        LIVE_TABLE.read_bytes(),
        geometry.height,
    )
    rgb, known, _report = roll.decode_full_index_bytes(
        LIVE_PREVIEW.read_bytes(),
        geometry,
        usable_rows=usable_rows,
    )

    detection = roll.detect_roll_frames(
        rgb,
        known,
        nominal_frame_rows=5_959 // geometry.pitch,
    )
    records = roll.parse_live_transport_records_bytes(
        table,
        maximum_rows=geometry.height,
    )
    scanner_frame_count = roll.scanner_addressable_interval_count(detection.intervals)
    mapping = roll.derive_transport_mapping(
        detection.boundaries,
        scanner_frame_count,
        records,
    )

    complete = [
        interval
        for interval in detection.intervals
        if interval.coverage_fraction == 1.0 and interval.count_supported
    ]
    assert [interval.frame for interval in complete] == [1, 2, 3, 4, 5, 6]
    assert [(interval.start_row, interval.end_row) for interval in complete] == [
        (0, 143),
        (143, 286),
        (286, 428),
        (428, 571),
        (571, 715),
        (715, 857),
    ]
    assert scanner_frame_count == 6
    assert detection.confidence == "high"
    assert detection.intervals[-1].coverage_fraction < 0.50
    assert detection.intervals[-1].manual_review
    assert roll.terminal_transport_tail_start(records) == 792
    assert mapping.native_units_per_preview_row == pytest.approx(42.333098275656035)
    assert [origin.native_origin for origin in mapping.origins[1:6]] == [
        6_188,
        12_250,
        18_228,
        24_332,
        30_394,
    ]
    assert mapping.origins[5].automatic


@pytest.mark.skipif(
    LIVE_PREVIEW is None
    or LIVE_TABLE is None
    or not LIVE_PREVIEW.is_file()
    or not LIVE_TABLE.is_file(),
    reason=(
        "banked live preview attempt is unavailable; set "
        f"{_LIVE_PREVIEW_DIR_ENV} to its artifact directory"
    ),
)
def test_banked_live_terminal_sliver_is_not_mapped_as_a_frame() -> None:
    geometry = roll.IndexGeometry(
        97, 4_000, 41, 3_946, 250_278, 96, 6_104, 2_048, 6_250_496
    )
    table, usable_rows = roll.validate_live_0x8e_bytes(
        LIVE_TABLE.read_bytes(), geometry.height
    )
    rgb, known, _report = roll.decode_full_index_bytes(
        LIVE_PREVIEW.read_bytes(), geometry, usable_rows=usable_rows
    )
    detection = roll.detect_roll_frames(
        rgb, known, nominal_frame_rows=5_959 // geometry.pitch
    )
    scanner_frame_count = roll.scanner_addressable_interval_count(detection.intervals)
    mapping = roll.derive_transport_mapping(
        detection.boundaries,
        scanner_frame_count,
        roll.parse_live_transport_records_bytes(table, maximum_rows=geometry.height),
    )

    assert scanner_frame_count == 6
    assert len(mapping.origins) == 6
    assert detection.intervals[-1].coverage_fraction < 0.50


@pytest.mark.skipif(
    CAMPAIGN_WIRE is None or not GOLD36_PREVIEW.is_file() or not GOLD36_TABLE.is_file(),
    reason=(
        "persisted Gold 36 index capture is unavailable; set "
        f"{_WIRE_DIR_ENV} to a directory containing "
        "rgbi4-gold36-frame18-meter2-{preview.bin,008e.bin} to run this "
        "golden-data regression"
    ),
)
def test_persisted_gold36_expected_count_and_frame18_origin() -> None:
    geometry = roll.IndexGeometry(
        requested_resolution=97,
        native_resolution=4_000,
        pitch=41,
        native_width=3_946,
        native_height=250_278,
        width=96,
        height=6_104,
        block_bytes=2_048,
        expected_stream_bytes=6_250_496,
    )
    table, usable_rows = roll.validate_live_0x8e_bytes(
        GOLD36_TABLE.read_bytes(), geometry.height
    )
    rgb, known, _report = roll.decode_full_index_bytes(
        GOLD36_PREVIEW.read_bytes(),
        geometry,
        usable_rows=usable_rows,
    )

    detection = roll.detect_roll_frames(
        rgb,
        known,
        nominal_frame_rows=5_959 // geometry.pitch,
        expected_frame_count=36,
    )
    mapping = roll.derive_transport_mapping(
        detection.boundaries,
        len(detection.intervals),
        roll.parse_live_transport_records_bytes(
            table,
            maximum_rows=geometry.height,
        ),
    )

    assert len(detection.intervals) == 40
    assert len(detection.boundaries) == 41
    assert detection.confidence == "high"
    assert detection.count_confidence == "user-selection-required"
    assert detection.content_end_candidates == (36, 37, 38)
    assert detection.expected_frame_count_matches
    assert (
        detection.boundaries[0].output_row,
        detection.intervals[-1].start_row,
        detection.intervals[-1].end_row,
    ) == (128, 5_687, 5_750)
    assert mapping.origins[17].native_origin == 109_060
    assert mapping.origins[17].automatic
    mismatched = roll.detect_roll_frames(
        rgb,
        known,
        nominal_frame_rows=5_959 // geometry.pitch,
        expected_frame_count=24,
    )
    assert mismatched.frame_starts == detection.frame_starts
    assert not mismatched.expected_frame_count_matches
