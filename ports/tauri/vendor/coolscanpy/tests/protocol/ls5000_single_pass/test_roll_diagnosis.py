"""Contracts for the read-only roll-refusal diagnosis pass.

Reuses the synthetic raster builders from test_roll_index.py (the one
cross-file test dependency documented in tests/conftest.py) instead of
duplicating them, so a change to the builders' conventions cannot silently
drift the two test files apart.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass import roll_diagnosis as diagnosis
from coolscanpy.protocol.ls5000_single_pass import roll_index as roll
from tests.protocol.ls5000_single_pass.test_roll_index import (
    _synthetic_roll,
    _synthetic_roll_with_gap_rows,
)

NOMINAL_FRAME_ROWS = 145


def _low_contrast_roll() -> np.ndarray:
    """A healthy roll whose interior inter-frame gaps read ~0.83-0.86 relative
    transmission instead of the usual ~0.95+.

    Scaling only the *interior* gap bands (never the leader/tail) keeps the
    clear-film p99 reference anchored to unscaled film, so the scaled gaps
    genuinely read as dim rather than silently re-normalizing away (the
    detector's own clear-film reference is the raster's own p99 -- scaling
    every clear-film row uniformly, leader and tail included, changes
    nothing, per FEEDING-ROBUSTNESS-20260805.md Sec 0 finding 3).
    """

    rgb, boundaries = _synthetic_roll(8, leader=60, tail=60, pitch=143)
    scaled = rgb.astype(np.float64)
    for boundary in boundaries[1:-1]:
        lo, hi = max(0, boundary - 3), min(len(rgb), boundary + 3)
        scaled[lo:hi, 2:92] *= 0.85
    return np.clip(scaled, 0, 65_535).astype(np.uint16)


def _obstructed_roll() -> np.ndarray:
    """A healthy roll with its leading ~18 aperture columns dimmed to 70%.

    70% clears the measured obstruction cliff (15/96 columns @ 70% fails
    detection with string A per FEEDING-ROBUSTNESS-20260805.md Sec 3.3) with
    a wide margin, exactly like the field mechanism it stands in for: a
    carrier mask edge or curl shadow depressing one side of the window.
    """

    rgb, _boundaries = _synthetic_roll(10, leader=30, tail=30)
    dimmed = rgb.astype(np.float64)
    dimmed[:, 2:20] *= 0.70
    return np.clip(dimmed, 0, 65_535).astype(np.uint16)


def _known(rgb: np.ndarray) -> np.ndarray:
    return np.ones_like(rgb, dtype=bool)


# ---------------------------------------------------------------------------
# Structural guarantee: str | None, always -- never RollDetection/GapBoundary/
# a raised exception, no matter what the input looks like.


def _structural_scenarios() -> list[tuple[str, np.ndarray, np.ndarray, int]]:
    healthy_rgb, _ = _synthetic_roll(24, leader=17, tail=21)
    half_frame_rgb, _ = _synthetic_roll(20, pitch=71, leader=30, tail=30)
    panorama_rgb, _ = _synthetic_roll(8, pitch=259, leader=30, tail=30)
    narrow_boundary_rows = [200 + index * 143 for index in range(6)]
    narrow_rgb = _synthetic_roll_with_gap_rows(
        narrow_boundary_rows, height=6 * 145 + 200, band_halfwidth=1
    )
    wide_rgb = _synthetic_roll_with_gap_rows(
        narrow_boundary_rows, height=6 * 145 + 200, band_halfwidth=13
    )
    low_contrast_rgb = _low_contrast_roll()
    obstructed_rgb = _obstructed_roll()
    too_short_rgb, _ = _synthetic_roll(2, leader=5, tail=5)
    garbage_rgb = np.zeros((10, 96, 3), dtype=np.uint16)

    return [
        ("healthy", healthy_rgb, _known(healthy_rgb), NOMINAL_FRAME_ROWS),
        ("half_frame", half_frame_rgb, _known(half_frame_rgb), NOMINAL_FRAME_ROWS),
        ("panorama", panorama_rgb, _known(panorama_rgb), NOMINAL_FRAME_ROWS),
        ("narrow_gaps", narrow_rgb, _known(narrow_rgb), NOMINAL_FRAME_ROWS),
        ("wide_gaps", wide_rgb, _known(wide_rgb), NOMINAL_FRAME_ROWS),
        (
            "low_contrast",
            low_contrast_rgb,
            _known(low_contrast_rgb),
            NOMINAL_FRAME_ROWS,
        ),
        ("obstructed", obstructed_rgb, _known(obstructed_rgb), NOMINAL_FRAME_ROWS),
        (
            "too_short_for_pitch_detection",
            too_short_rgb,
            _known(too_short_rgb),
            NOMINAL_FRAME_ROWS,
        ),
        ("all_zero_garbage", garbage_rgb, _known(garbage_rgb), NOMINAL_FRAME_ROWS),
        (
            "mismatched_known_shape",
            garbage_rgb,
            np.ones((5, 96, 3), dtype=bool),
            NOMINAL_FRAME_ROWS,
        ),
        (
            "all_incomplete_known",
            healthy_rgb,
            np.zeros_like(healthy_rgb, dtype=bool),
            NOMINAL_FRAME_ROWS,
        ),
        ("nominal_below_floor", healthy_rgb, _known(healthy_rgb), 5),
        ("nominal_zero", healthy_rgb, _known(healthy_rgb), 0),
        (
            "one_dimensional_raster",
            np.zeros(10, dtype=np.uint16),
            np.ones(10, dtype=bool),
            NOMINAL_FRAME_ROWS,
        ),
    ]


_SCENARIOS = _structural_scenarios()


@pytest.mark.parametrize(
    ("label", "rgb16", "known", "nominal_frame_rows"),
    _SCENARIOS,
    ids=[scenario[0] for scenario in _SCENARIOS],
)
def test_diagnose_roll_refusal_always_returns_str_or_none(
    label: str,
    rgb16: np.ndarray,
    known: np.ndarray,
    nominal_frame_rows: int,
) -> None:
    result = diagnosis.diagnose_roll_refusal(
        rgb16, known, nominal_frame_rows=nominal_frame_rows
    )
    assert result is None or isinstance(result, str)


def test_module_never_references_detection_result_types_or_the_wrapper() -> None:
    """Grep-level guarantee: this module cannot construct or even name a
    detection result. Source-text check, not an import-time property, so a
    future ``from .roll_index import RollDetection`` (even if unused) still
    fails this the same way a real violation would.
    """

    source = Path(diagnosis.__file__).read_text()
    for forbidden in ("RollDetection", "GapBoundary", "detect_roll_frames"):
        assert forbidden not in source, (
            f"{forbidden!r} must never appear in roll_diagnosis.py"
        )


# ---------------------------------------------------------------------------
# One test per diagnosis class (priority order 1-4; half-frame and panorama
# are both the alternate-pitch check, class 1).


def test_half_frame_pitch_is_recognized() -> None:
    rgb = _synthetic_roll(20, pitch=71, leader=30, tail=30)[0]
    sentence = diagnosis.diagnose_roll_refusal(
        rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert sentence is not None
    assert "half-frame film" in sentence
    assert "19 mm" in sentence
    assert "standard 35 mm spacing" in sentence


def test_panoramic_pitch_is_recognized() -> None:
    rgb = _synthetic_roll(8, pitch=259, leader=30, tail=30)[0]
    sentence = diagnosis.diagnose_roll_refusal(
        rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert sentence is not None
    assert "panoramic film" in sentence
    assert "69 mm" in sentence
    assert "standard 35 mm spacing" in sentence


def test_narrow_gaps_are_recognized() -> None:
    boundary_rows = [200 + index * 143 for index in range(6)]
    rgb = _synthetic_roll_with_gap_rows(
        boundary_rows, height=6 * 145 + 200, band_halfwidth=1
    )
    sentence = diagnosis.diagnose_roll_refusal(
        rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert sentence is not None
    assert "blank strips between your frames" in sentence
    assert "0.5 mm" in sentence
    assert "0.8 mm" in sentence


def test_wide_gaps_are_recognized() -> None:
    boundary_rows = [200 + index * 143 for index in range(6)]
    rgb = _synthetic_roll_with_gap_rows(
        boundary_rows, height=6 * 145 + 200, band_halfwidth=13
    )
    # Confirm the fixture actually exceeds the recovery ceiling, so this
    # test is exercising "too wide", not some other accepted width.
    aperture = roll._active_aperture(rgb)
    _evidence, _transmission, _nonuniformity, direct = roll._physical_gap_evidence(
        rgb, aperture
    )
    widths = [end - start for start, end in roll._true_runs(direct)]
    assert all(width > roll.WIDE_GAP_CEILING_ROWS for width in widths)

    sentence = diagnosis.diagnose_roll_refusal(
        rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert sentence is not None
    assert "a blank region measures" in sentence
    assert "wider than anything the detector accepts" in sentence


def test_low_contrast_gaps_are_recognized() -> None:
    rgb = _low_contrast_roll()
    sentence = diagnosis.diagnose_roll_refusal(
        rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert sentence is not None
    assert "only slightly clearer than the frames themselves" in sentence
    assert "fog or a dense film base" in sentence


def test_aperture_obstruction_is_recognized() -> None:
    rgb = _obstructed_roll()
    sentence = diagnosis.diagnose_roll_refusal(
        rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert sentence is not None
    assert "partly blocked" in sentence
    assert "leading side" in sentence
    assert "film holder seating and film curl" in sentence


# ---------------------------------------------------------------------------
# Wiring: detect_roll_frames's failure paths attach diagnostics["probable_
# cause"] when (and only when) a diagnosis fires, without touching the
# error id, message prefix, or any pre-existing diagnostics key.


def test_wiring_attaches_probable_cause_without_changing_error_id_or_existing_keys() -> (
    None
):
    boundary_rows = [200 + index * 143 for index in range(6)]
    rgb = _synthetic_roll_with_gap_rows(
        boundary_rows, height=6 * 145 + 200, band_halfwidth=1
    )
    known = _known(rgb)

    # The undecorated pass-1 error -- exactly what today's behavior is
    # without any diagnosis wired in.
    with pytest.raises(roll.IndexDecodeError) as baseline_excinfo:
        roll._detect_roll_frames_single(
            rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS
        )
    baseline = baseline_excinfo.value

    with pytest.raises(roll.IndexDecodeError) as wired_excinfo:
        roll.detect_roll_frames(rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS)
    wired = wired_excinfo.value

    assert wired.error_id == baseline.error_id == roll.GAP_COUNT_FLOOR_ERROR_ID
    assert str(wired).split(" [")[0] == str(baseline).split(" [")[0]
    for key, value in (baseline.diagnostics or {}).items():
        assert wired.diagnostics[key] == value
    assert set(wired.diagnostics) - set(baseline.diagnostics or {}) == {
        "wide_gap_recovery",
        "probable_cause",
    }

    expected_sentence = diagnosis.diagnose_roll_refusal(
        rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert expected_sentence is not None
    assert wired.diagnostics["probable_cause"] == expected_sentence


def test_wiring_adds_no_probable_cause_key_when_no_check_fires() -> None:
    """A raster whose actual failure mode (one gap 30 rows off-lattice) does
    not match any of the four diagnosis classes must raise exactly today's
    error -- diagnosis returning ``None`` must never add the key.
    """

    # Matches test_roll_index.py's own off-lattice-gap fixture: three narrow
    # gaps clear the count floor, but the third is 30 rows off the pitch the
    # other two establish.
    boundary_rows = [200, 345, 520]
    rgb = _synthetic_roll_with_gap_rows(boundary_rows, height=6 * 145, band_halfwidth=3)
    known = _known(rgb)

    assert (
        diagnosis.diagnose_roll_refusal(
            rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS
        )
        is None
    )

    with pytest.raises(roll.IndexDecodeError) as excinfo:
        roll.detect_roll_frames(rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS)
    error = excinfo.value
    assert error.error_id == roll.GAP_LATTICE_ANCHOR_ERROR_ID
    assert "probable_cause" not in error.diagnostics


def test_incomplete_index_error_never_carries_probable_cause() -> None:
    """IncompleteIndexError re-raises untouched (task boundary: this is not
    a roll-geometry refusal the diagnosis pass has any business commenting
    on -- the raster is simply missing rows).
    """

    rgb, _boundaries = _synthetic_roll(5)
    known = _known(rgb)
    known[: rgb.shape[0] // 10] = False

    with pytest.raises(roll.IncompleteIndexError) as excinfo:
        roll.detect_roll_frames(rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS)
    error = excinfo.value
    assert error.diagnostics is None
    assert "probable_cause" not in str(error)


# ---------------------------------------------------------------------------
# No false positives: healthy film must never receive an invented cause.
# Belt-and-braces -- diagnose_roll_refusal never runs on healthy film in
# production (it is only ever called from a failure path), but the
# structural contract holds regardless of what a caller hands it.


@pytest.mark.parametrize(
    ("frame_count", "pitch", "leader", "tail"),
    [
        (24, 143, 17, 21),
        (8, 143, 91, 47),
        (36, 143, 300, 21),
        (6, 143, 0, 3),
        (10, 143, 300, 260),
        (4, 123, 30, 30),
        (4, 167, 30, 30),
        (20, 145, 30, 30),
    ],
    ids=[
        "typical_leader_trailer",
        "short_leader_long_trailer",
        "long_leader_short_trailer",
        "no_leader_minimal_trailer",
        "very_long_leader_and_trailer",
        "pitch_at_low_edge_of_standard_band",
        "pitch_at_high_edge_of_standard_band",
        "pitch_equals_nominal",
    ],
)
def test_healthy_roll_never_invents_a_cause(
    frame_count: int, pitch: int, leader: int, tail: int
) -> None:
    rgb, _boundaries = _synthetic_roll(
        frame_count, pitch=pitch, leader=leader, tail=tail
    )
    assert (
        diagnosis.diagnose_roll_refusal(
            rgb, _known(rgb), nominal_frame_rows=NOMINAL_FRAME_ROWS
        )
        is None
    )


def test_healthy_roll_succeeds_normally_through_the_wrapper_with_no_probable_cause() -> (
    None
):
    """End-to-end sanity: wiring diagnosis into the failure paths must not
    perturb the success path at all."""

    rgb, _boundaries = _synthetic_roll(24, leader=17, tail=21)
    known = _known(rgb)
    detection = roll.detect_roll_frames(
        rgb, known, nominal_frame_rows=NOMINAL_FRAME_ROWS
    )
    assert detection.confidence == "high"
