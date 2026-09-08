"""Regression contracts for fail-closed LS-5000 exposure metering."""

import json

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass.meter import (
    CHANNELS,
    DEFAULT_EXPOSURES,
    LINEARITY_CORRELATION_MIN,
    LINEARITY_CORRELATION_MIN_IR,
    LINEARITY_MIN_AGGREGATES,
    LINEARITY_MIN_SAMPLES,
    METER_PASS_BYTES,
    METER_ROWS,
    METER_TAIL_SAMPLES,
    METER_WIDTH,
    DecodedMeterPass,
    MeterObservation,
    NIKON_PARITY_REVIEWED_HIGH_THRESHOLD,
    NIKON_PARITY_TARGET_FRACTIONS,
    NikonParityShadowResult,
    calculate_nikon_parity_shadow,
    decode_meter_pass,
    evaluate_meter_sequence,
    observe_meter_pass,
    propose_next_exposures,
    verify_final_convergence,
)


def _payload(image: np.ndarray, *, tail_seed: int = 0) -> bytes:
    rows = np.zeros((METER_ROWS, 1280), dtype=">u2")
    rows[:, :1124] = image.transpose(0, 2, 1).reshape(METER_ROWS, 1124)
    tails = (np.arange(METER_ROWS * METER_TAIL_SAMPLES, dtype=np.uint32) + tail_seed) % 65536
    rows[:, 1124:] = tails.reshape(METER_ROWS, METER_TAIL_SAMPLES)
    return rows.tobytes()


def _textured(peaks: tuple[int, int, int, int] = (32_000, 30_000, 34_000, 29_000)) -> np.ndarray:
    yy, xx = np.mgrid[0:METER_ROWS, 0:METER_WIDTH]
    field = 0.06 + 0.94 * (0.53 * xx / (METER_WIDTH - 1) + 0.47 * yy / (METER_ROWS - 1))
    image = np.empty((METER_ROWS, METER_WIDTH, 4), dtype=np.uint16)
    for channel, peak in enumerate(peaks):
        image[:, :, channel] = np.round(900 + peak * field).astype(np.uint16)
    return image


def _rescale(
    image: np.ndarray,
    old: dict[str, int],
    new: dict[str, int],
    *,
    pedestal: float = 900.0,
) -> np.ndarray:
    result = np.empty_like(image)
    for index, channel in enumerate(CHANNELS):
        gain = new[channel] / old[channel]
        result[:, :, index] = np.clip(
            pedestal + (image[:, :, index].astype(np.float64) - pedestal) * gain,
            0,
            65_535,
        ).astype(np.uint16)
    return result


def _observations_with_bounded_linearity_pairs() -> tuple[
    MeterObservation, MeterObservation
]:
    """Pass pair with R below the raw floor and G below only the aggregate floor."""

    first_image = _textured((31_000, 30_000, 32_000, 29_000))
    first = observe_meter_pass(_payload(first_image), DEFAULT_EXPOSURES)
    second_exposures = {
        channel: int(exposure * 1.1)
        for channel, exposure in DEFAULT_EXPOSURES.items()
    }
    second_image = _rescale(first_image, DEFAULT_EXPOSURES, second_exposures)
    second = observe_meter_pass(_payload(second_image), second_exposures)

    row_inset = round(METER_ROWS * 0.10)
    column_inset = round(METER_WIDTH * 0.10)
    central_rows = METER_ROWS - 2 * row_inset
    central_columns = METER_WIDTH - 2 * column_inset

    first_sparse = first.decoded.image.copy()
    second_sparse = second.decoded.image.copy()
    for channel_index, channel in enumerate(("R", "G")):
        first_sparse[:, :, channel_index] = round(
            first.channel_statistics[channel].black
        )
        second_sparse[:, :, channel_index] = round(
            second.channel_statistics[channel].black
        )

    raw_mask = np.zeros((central_rows, central_columns), dtype=bool)
    raw_mask.flat[: LINEARITY_MIN_SAMPLES - 1] = True
    aggregate_mask = np.zeros_like(raw_mask)
    # Eight valid values per 9-wide block gives abundant raw pairs while no
    # aggregate is admissible (aggregates require all nine raw pairs).
    aggregate_mask[:, :] = True
    aggregate_mask[:, ::9] = False

    for channel_index, mask in enumerate((raw_mask, aggregate_mask)):
        first_plane = first_sparse[
            row_inset : METER_ROWS - row_inset,
            column_inset : METER_WIDTH - column_inset,
            channel_index,
        ]
        second_plane = second_sparse[
            row_inset : METER_ROWS - row_inset,
            column_inset : METER_WIDTH - column_inset,
            channel_index,
        ]
        first_plane[mask] = 12_000
        second_plane[mask] = 13_200

    return (
        MeterObservation(
            decoded=DecodedMeterPass(first_sparse, first.decoded.row_tail),
            exposures=dict(first.exposures),
            channel_statistics=dict(first.channel_statistics),
        ),
        MeterObservation(
            decoded=DecodedMeterPass(second_sparse, second.decoded.row_tail),
            exposures=dict(second.exposures),
            channel_statistics=dict(second.channel_statistics),
        ),
    )


def _channel_noise_pair(
    channel: str,
    *,
    noise_std: float,
    seed: int = 20260907,
    row_std: float = 1050.0,
    col_amp: float = 180.0,
    exposure_gain: float = 1.1,
) -> tuple[MeterObservation, MeterObservation]:
    """Pass pair with pixel-scale noise eroding only one channel's correlation.

    Mirrors HW-08 (2026-09-07 LS-5000 ED frame 10): row-to-row and
    column-periodic structure survives an exposure-gain rescale, but added
    per-pixel noise degrades the width-aggregated pass-to-pass correlation
    the linearity gate checks, same as a dark frame's low-texture IR plane.
    """

    channel_index = CHANNELS.index(channel)
    rng = np.random.default_rng(seed)
    _yy, xx = np.mgrid[0:METER_ROWS, 0:METER_WIDTH]
    row_structure = rng.normal(0.0, row_std, size=(METER_ROWS, 1))
    column_structure = col_amp * np.sin(xx * 2.0 * np.pi / 37.0)
    underlying = 32_000.0 + row_structure + column_structure
    first_noisy = 1_000.0 + underlying + rng.normal(0.0, noise_std, size=underlying.shape)
    second_noisy = (
        1_000.0
        + underlying * exposure_gain
        + rng.normal(0.0, noise_std, size=underlying.shape)
    )

    first_image = _textured((30_000,) * 4)
    first_image[:, :, channel_index] = np.clip(first_noisy, 0, 65_535).astype(np.uint16)
    second_exposures = {
        ch: int(exposure * exposure_gain) for ch, exposure in DEFAULT_EXPOSURES.items()
    }
    second_image = _rescale(first_image, DEFAULT_EXPOSURES, second_exposures)
    second_image[:, :, channel_index] = np.clip(second_noisy, 0, 65_535).astype(np.uint16)

    first = observe_meter_pass(_payload(first_image), DEFAULT_EXPOSURES)
    second = observe_meter_pass(_payload(second_image), second_exposures)
    return first, second


def test_meter_decode_preserves_channel_order_and_opaque_row_tail() -> None:
    payload = _payload(_textured(), tail_seed=123)

    decoded = decode_meter_pass(payload)

    assert len(payload) == METER_PASS_BYTES
    assert decoded.image.shape == (METER_ROWS, METER_WIDTH, 4)
    assert decoded.row_tail.shape == (METER_ROWS, METER_TAIL_SAMPLES)
    assert decoded.channels == CHANNELS
    assert decoded.to_bytes() == payload


def test_nikon_parity_shadow_is_rgb_only_and_has_no_scanner_route() -> None:
    observation = observe_meter_pass(
        _payload(_textured(), tail_seed=321),
        DEFAULT_EXPOSURES,
    )
    active_metered = {"R": 97_000, "G": 194_000, "B": 177_000, "IR": 283_000}

    shadow = calculate_nikon_parity_shadow(
        observation,
        current_metered_exposures=active_metered,
    )

    assert isinstance(shadow, NikonParityShadowResult)
    record = shadow.to_journal_dict(routing="journal-only")
    assert record["profile"] == "nikon-parity"
    assert record["armed"] is False
    assert record["scanner_route"] == "none"
    assert tuple(record["channels"]) == ("R", "G", "B")
    assert record["infrared"] == {
        "policy": "active-controller-unchanged",
        "current_metered_exposure_raw_10ns": active_metered["IR"],
        "candidate_exposure_raw_10ns": None,
    }
    for channel in ("R", "G", "B"):
        assert record["channels"][channel]["target_fraction"] == pytest.approx(
            NIKON_PARITY_TARGET_FRACTIONS[channel]
        )
        assert (
            record["channels"][channel]["predicted_full_high_q99_99"]
            <= NIKON_PARITY_REVIEWED_HIGH_THRESHOLD
        )
    assert not hasattr(shadow, "proposed_exposures")
    assert not hasattr(shadow, "final_exposures")


def test_nikon_parity_journal_routing_literal_is_mandatory_and_closed() -> None:
    observation = observe_meter_pass(
        _payload(_textured(), tail_seed=321),
        DEFAULT_EXPOSURES,
    )
    shadow = calculate_nikon_parity_shadow(
        observation,
        current_metered_exposures={
            "R": 97_000,
            "G": 194_000,
            "B": 177_000,
            "IR": 283_000,
        },
    )

    with pytest.raises(TypeError):
        shadow.to_journal_dict()  # routing intent must be stated explicitly
    with pytest.raises(ValueError, match="routing"):
        shadow.to_journal_dict(routing="armed")  # only the two known literals


def test_nikon_parity_active_authority_routing_is_truthful() -> None:
    observation = observe_meter_pass(
        _payload(_textured(), tail_seed=321),
        DEFAULT_EXPOSURES,
    )
    shadow = calculate_nikon_parity_shadow(
        observation,
        current_metered_exposures={
            "R": 97_000,
            "G": 194_000,
            "B": 177_000,
            "IR": 283_000,
        },
    )

    record = shadow.to_journal_dict(routing="active-rgb-authority")
    assert record["mode"] == "active-rgb-authority"
    assert record["armed"] is True
    assert record["scanner_route"] == "fine-rgb-set-window"
    # The higher diagnostic value stays journal-only under BOTH routings.
    for channel in ("R", "G", "B"):
        assert record["channels"][channel]["uncapped_candidate_is_journal_only"] is True
    # Infrared remains the active controller's, with no parity candidate.
    assert record["infrared"]["policy"] == "active-controller-unchanged"
    assert record["infrared"]["candidate_exposure_raw_10ns"] is None


@pytest.mark.parametrize("delta", [-2, -1, 2])
def test_meter_decode_rejects_any_length_corruption(delta: int) -> None:
    payload = _payload(_textured())
    corrupt = payload[:delta] if delta < 0 else payload + b"\x00" * delta
    with pytest.raises(ValueError, match="expected 1088000"):
        decode_meter_pass(corrupt)


def test_proposal_is_bounded_and_uses_a_lower_ir_target() -> None:
    proposal = propose_next_exposures(observe_meter_pass(_payload(_textured()), DEFAULT_EXPOSURES))

    assert proposal.accepted, proposal.to_dict()
    for channel in CHANNELS:
        assert DEFAULT_EXPOSURES[channel] < proposal.proposed_exposures[channel] <= 2 * DEFAULT_EXPOSURES[channel]
    assert proposal.channel_diagnostics["IR"]["target_fraction"] < proposal.channel_diagnostics["R"]["target_fraction"]


def test_width_only_ir_correlation_accepts_noise_but_refuses_one_transport_row_shift() -> None:
    rng = np.random.default_rng(20260713)
    _yy, xx = np.mgrid[0:METER_ROWS, 0:METER_WIDTH]
    row_structure = rng.normal(0.0, 1_050.0, size=(METER_ROWS, 1))
    column_structure = 180.0 * np.sin(xx * 2.0 * np.pi / 37.0)
    underlying_ir = 44_000.0 + row_structure + column_structure
    first_ir = 1_000.0 + underlying_ir + rng.normal(0.0, 195.0, size=underlying_ir.shape)
    exposure_gain = 1.1
    second_ir = 1_000.0 + underlying_ir * exposure_gain + rng.normal(0.0, 195.0, size=underlying_ir.shape)

    first_image = _textured((30_000,) * 4)
    first_image[:, :, 3] = np.clip(first_ir, 0, 65_535).astype(np.uint16)
    second_exposures = {channel: int(exposure * exposure_gain) for channel, exposure in DEFAULT_EXPOSURES.items()}
    second_image = _rescale(first_image, DEFAULT_EXPOSURES, second_exposures)
    second_image[:, :, 3] = np.clip(second_ir, 0, 65_535).astype(np.uint16)
    first = observe_meter_pass(_payload(first_image), DEFAULT_EXPOSURES)
    second = observe_meter_pass(_payload(second_image), second_exposures)

    aligned = propose_next_exposures(second, previous=first)
    assert aligned.accepted, aligned.to_dict()
    assert aligned.channel_diagnostics["IR"]["linearity"]["correlation_aggregation"] == {
        "axis": "width",
        "size": 9,
        "requires_all_raw_valid": True,
    }

    shifted_image = second_image.copy()
    shifted_image[:, :, 3] = np.roll(second_image[:, :, 3], 1, axis=0)
    shifted = propose_next_exposures(
        observe_meter_pass(_payload(shifted_image), second_exposures),
        previous=first,
    )
    assert ("low_correlation", "IR") in {(item.code, item.channel) for item in shifted.refusals}


def test_hw08_ir_correlation_matching_dark_frame_evidence_is_not_refused() -> None:
    """HW-08: a real LS-5000 ED batch aborted at frame 10 on IR 0.9727 alone.

    R/G/B were 0.9995/0.9999/0.9999. IR is not an exposure-driving channel
    for C-41 negatives, so its own floor (0.95) must accept this frame.
    """

    first, second = _channel_noise_pair("IR", noise_std=500.0)

    proposal = propose_next_exposures(second, previous=first)

    ir_linearity = proposal.channel_diagnostics["IR"]["linearity"]
    assert LINEARITY_CORRELATION_MIN_IR <= ir_linearity["correlation"] < LINEARITY_CORRELATION_MIN
    for channel in ("R", "G", "B"):
        assert proposal.channel_diagnostics[channel]["linearity"]["correlation"] >= 0.999
    assert ("low_correlation", "IR") not in {(item.code, item.channel) for item in proposal.refusals}
    assert proposal.accepted, proposal.to_dict()


def test_rgb_correlation_below_shared_floor_still_refuses() -> None:
    """The 0.98 floor is untouched for R/G/B -- only IR got a looser gate."""

    first, second = _channel_noise_pair("R", noise_std=700.0)

    proposal = propose_next_exposures(second, previous=first)

    assert proposal.channel_diagnostics["R"]["linearity"]["correlation"] < LINEARITY_CORRELATION_MIN
    assert not proposal.accepted
    assert ("low_correlation", "R") in {(item.code, item.channel) for item in proposal.refusals}


def test_ir_correlation_below_its_own_floor_still_refuses() -> None:
    """IR keeps a hard floor -- it is relaxed, not removed."""

    first, second = _channel_noise_pair("IR", noise_std=900.0)

    proposal = propose_next_exposures(second, previous=first)

    assert proposal.channel_diagnostics["IR"]["linearity"]["correlation"] < LINEARITY_CORRELATION_MIN_IR
    assert not proposal.accepted
    assert ("low_correlation", "IR") in {(item.code, item.channel) for item in proposal.refusals}


def test_linearity_diagnostic_records_the_applied_correlation_floor_per_channel() -> None:
    """The journal must keep recording the correlation and which floor decided it."""

    first, second = _channel_noise_pair("IR", noise_std=500.0)

    proposal = propose_next_exposures(second, previous=first)
    record = proposal.to_dict()

    assert record["channels"]["IR"]["linearity"]["correlation_min"] == LINEARITY_CORRELATION_MIN_IR
    assert record["channels"]["IR"]["linearity"]["correlation"] == pytest.approx(0.9723, abs=5e-3)
    for channel in ("R", "G", "B"):
        assert record["channels"][channel]["linearity"]["correlation_min"] == LINEARITY_CORRELATION_MIN
    json.dumps(record, allow_nan=False)  # journal payload must stay serializable


def test_three_pass_sequence_converges_and_requires_exact_exposure_history() -> None:
    first_image = np.roll(_textured((31_000, 30_000, 32_000, 29_000)), shift=(141, 93), axis=(0, 1))
    first = observe_meter_pass(_payload(first_image), DEFAULT_EXPOSURES)
    first_proposal = propose_next_exposures(first)
    second_image = _rescale(first_image, DEFAULT_EXPOSURES, first_proposal.proposed_exposures)
    second = observe_meter_pass(_payload(second_image), first_proposal.proposed_exposures)
    second_proposal = propose_next_exposures(second, previous=first)
    third_image = _rescale(second_image, first_proposal.proposed_exposures, second_proposal.proposed_exposures)
    third = observe_meter_pass(_payload(third_image), second_proposal.proposed_exposures)

    final = verify_final_convergence(third, previous=second)
    result = evaluate_meter_sequence(
        [_payload(first_image), _payload(second_image), _payload(third_image)],
        [DEFAULT_EXPOSURES, first_proposal.proposed_exposures, second_proposal.proposed_exposures],
    )
    assert final.accepted, final.to_dict()
    assert result.accepted, result.to_dict()
    assert result.final_exposures == final.final_exposures
    json.dumps(result.to_dict(), allow_nan=False)

    mismatched = [dict(item) for item in [DEFAULT_EXPOSURES, first_proposal.proposed_exposures, second_proposal.proposed_exposures]]
    mismatched[1]["IR"] += 1
    refused = evaluate_meter_sequence(
        [_payload(first_image), _payload(second_image), _payload(third_image)],
        mismatched,
    )
    assert "exposure_history_mismatch" in {item.code for item in refused.refusals}


def test_final_acceptance_requires_fresh_previous_pass_linearity() -> None:
    observation = observe_meter_pass(_payload(_textured((24_000,) * 4)), DEFAULT_EXPOSURES)
    result = verify_final_convergence(observation)
    assert not result.accepted
    assert "missing_previous_linearity" in {item.code for item in result.refusals}


def test_pass_two_refusal_preserves_all_channels_and_raw_aggregate_counts() -> None:
    first, second = _observations_with_bounded_linearity_pairs()

    proposal = propose_next_exposures(second, previous=first)
    refusal_by_channel = {
        refusal.channel: refusal.to_dict()
        for refusal in proposal.refusals
        if refusal.code == "linearity_insufficient"
    }

    assert set(refusal_by_channel) == {"R", "G"}
    assert refusal_by_channel["R"]["valid_raw_samples"] == LINEARITY_MIN_SAMPLES - 1
    assert refusal_by_channel["R"]["required_raw_samples"] == LINEARITY_MIN_SAMPLES
    assert refusal_by_channel["G"]["valid_raw_samples"] > LINEARITY_MIN_SAMPLES
    assert refusal_by_channel["G"]["valid_aggregate_samples"] == 0
    assert (
        refusal_by_channel["G"]["required_aggregate_samples"]
        == LINEARITY_MIN_AGGREGATES
    )


def test_final_pass_refusal_preserves_the_same_bounded_diagnostics() -> None:
    first, second = _observations_with_bounded_linearity_pairs()

    result = verify_final_convergence(second, previous=first)
    refusal_by_channel = {
        refusal.channel: refusal.to_dict()
        for refusal in result.refusals
        if refusal.code == "linearity_insufficient"
    }

    assert set(refusal_by_channel) == {"R", "G"}
    assert refusal_by_channel["R"]["valid_raw_samples"] == LINEARITY_MIN_SAMPLES - 1
    assert refusal_by_channel["G"]["valid_aggregate_samples"] == 0


def test_predictive_ceiling_hold_is_not_refused_as_clipped_increase() -> None:
    image = _textured((50_000,) * 4)
    image[:2, :25, :] = 64_000

    proposal = propose_next_exposures(
        observe_meter_pass(_payload(image), DEFAULT_EXPOSURES)
    )

    assert proposal.proposed_exposures == DEFAULT_EXPOSURES
    for channel in CHANNELS:
        diagnostics = proposal.channel_diagnostics[channel]
        assert diagnostics["full_high_q99_99"] >= diagnostics["ceiling_value"]
        assert diagnostics["bounded_by_predictive_ceiling"] is True
        assert diagnostics["effective_update_ratio"] == 1.0
    assert proposal.accepted, proposal.to_dict()
