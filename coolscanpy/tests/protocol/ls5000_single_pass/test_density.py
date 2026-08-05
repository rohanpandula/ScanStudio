"""Offline contracts for the native LS-5000 density-input seam."""

from __future__ import annotations

import hashlib
import math
import struct
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest

from coolscanpy.exceptions import MeterUnusableError
from coolscanpy.protocol.ls5000_single_pass import density as density_module
from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    _validated_density_evidence,
)
from coolscanpy.protocol.ls5000_single_pass.density import (
    ALGORITHM_ID,
    ARITHMETIC_BACKEND_STATUS,
    EXPOSURE_BINDING_STATUS,
    DENSITY_SOURCE_BYTE_ORDER,
    DENSITY_SOURCE_CHILD_BYTES,
    DENSITY_SOURCE_DENSITY_CHANNELS,
    DENSITY_SOURCE_DISCARDED_ROW_BYTES,
    DENSITY_SOURCE_HEIGHT,
    DENSITY_SOURCE_INPUT_CHANNELS,
    DENSITY_SOURCE_LAYOUT,
    DENSITY_SOURCE_NATIVE_HEIGHT,
    DENSITY_SOURCE_NATIVE_RESOLUTION_DPI,
    DENSITY_SOURCE_NATIVE_WIDTH,
    DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES,
    DENSITY_SOURCE_RESOLUTION_DPI,
    DENSITY_SOURCE_RGB_ROW_BYTES,
    DENSITY_SOURCE_ROW_STRIDE_BYTES,
    DENSITY_SOURCE_SAMPLE_BITS,
    DENSITY_SOURCE_SCALE_DIVISOR,
    DENSITY_SOURCE_SUPPORTED_HEIGHTS,
    DENSITY_SOURCE_WIDTH,
    DENSITY_SOURCE_WIRE_BYTES,
    NIKON_ANALYZER_SHAPE,
    SOURCE_BINDING_STATUS,
    DensityCalibration,
    NikonDensityCalibrationBinding,
    NikonDensityExposureBinding,
    NikonDensityEvidence,
    NikonDensitySourceBinding,
    NikonDensityFrameOwnershipReceipt,
    NikonExactBuilderEvidence,
    assemble_density_calibration,
    bind_nikon_density_source,
    build_nikon_density_evidence,
    build_nikon_density_frame_ownership,
    build_nikon_exact_builder_evidence,
    decode_density_calibration_read,
    decode_nikon_density_source,
    density_source_geometry_for_startup_records,
    evaluate_nikon_density,
    verify_nikon_density_arithmetic_backend,
)


_CDBS = tuple(
    bytes.fromhex(value)
    for value in (
        "28008c00010300000a80",
        "28008c00020300000a80",
        "28008c00030300000a80",
    )
)
_PAYLOADS = tuple(
    bytes.fromhex(value)
    for value in (
        "8c20000000040000df1a",
        "8c20000000040000bba4",
        "8c200000000400007fab",
    )
)
_NUMERATORS = (57_114, 48_036, 32_683)
_DENSITY_F03_DENOMINATORS = (70_307, 136_614, 125_470)


def _calibration(session_id: str = "reservation-7") -> DensityCalibration:
    reads = [
        decode_density_calibration_read(cdb, payload)
        for cdb, payload in zip(_CDBS, _PAYLOADS, strict=True)
    ]
    return assemble_density_calibration(reads, session_id=session_id)


def _calibration_binding(
    session_id: str = "reservation-7",
    *,
    capture_attempt_id: str = "slot-4-attempt-1",
    scan_identity: str = "slot-4-attempt-1-density-97dpi-preview",
) -> NikonDensityCalibrationBinding:
    return NikonDensityCalibrationBinding(
        calibration=_calibration(session_id),
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
    )


def _source_image(*, height: int = DENSITY_SOURCE_HEIGHT) -> np.ndarray:
    image = np.zeros(
        (
            height,
            DENSITY_SOURCE_WIDTH,
            DENSITY_SOURCE_DENSITY_CHANNELS,
        ),
        dtype=np.uint16,
    )
    image[90, :, :] = (44_000, 39_000, 31_000)
    image[100, :, :] = (45_000, 40_000, 32_000)
    image[101, :, :] = (45_000, 40_000, 32_000)
    # Strictly over Nikon's 90% ceiling, so this brighter row is ignored.
    image[102, :, :] = (60_000, 60_000, 60_000)
    # Asymmetric sentinels make planar/channel/order errors visible.
    image[0, 0, :] = (0x0123, 0x4567, 0x89AB)
    image[-1, -1, :] = (0xCDEF, 0x2345, 0x6789)
    return image


def _archived_means_source_image() -> np.ndarray:
    image = np.zeros(
        (
            DENSITY_SOURCE_HEIGHT,
            DENSITY_SOURCE_WIDTH,
            DENSITY_SOURCE_DENSITY_CHANNELS,
        ),
        dtype=np.uint16,
    )
    for channel, (row, total) in enumerate(
        ((129, 3_185_488), (128, 2_795_531), (126, 2_186_679))
    ):
        quotient, remainder = divmod(total, DENSITY_SOURCE_WIDTH)
        image[row, :, channel] = quotient
        image[row, :remainder, channel] += 1
    return image


def _wire_from_image(image: np.ndarray) -> bytes:
    rows: list[bytes] = []
    for row_index in range(image.shape[0]):
        row_planar = np.transpose(image[row_index], (1, 0)).astype(">u2").tobytes()
        assert len(row_planar) == DENSITY_SOURCE_RGB_ROW_BYTES
        # The opaque suffix is nonzero and row-varying so treating it as image
        # data is immediately visible. Nikon discards the entire region.
        opaque_tail = (
            bytes([0x80 | (row_index & 0x7F)]) * DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES
        )
        rows.append(row_planar + opaque_tail)
    wire = b"".join(rows)
    assert len(wire) == image.shape[0] * DENSITY_SOURCE_ROW_STRIDE_BYTES
    return wire


def _child_bytes(image: np.ndarray) -> bytes:
    child = np.transpose(image, (0, 2, 1)).astype("<u2").tobytes()
    assert len(child) == image.shape[0] * DENSITY_SOURCE_RGB_ROW_BYTES
    return child


def _source_binding(
    wire: bytes,
    image: np.ndarray,
    *,
    session_id: str = "reservation-7",
    capture_attempt_id: str = "slot-4-attempt-1",
    scan_identity: str = "slot-4-attempt-1-density-97dpi-preview",
    native_height: int = DENSITY_SOURCE_NATIVE_HEIGHT,
) -> NikonDensitySourceBinding:
    binding = bind_nikon_density_source(
        wire,
        session_id=session_id,
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
        native_height=native_height,
        height=image.shape[0],
    )
    assert (
        binding.child_buffer_sha256 == hashlib.sha256(_child_bytes(image)).hexdigest()
    )
    compact_be = np.transpose(image, (0, 2, 1)).astype(">u2").tobytes()
    assert binding.compact_buffer_be_sha256 == hashlib.sha256(compact_be).hexdigest()
    return binding


def _exposure_binding(
    *,
    session_id: str = "reservation-7",
    capture_attempt_id: str = "slot-4-attempt-1",
    scan_identity: str = "slot-4-attempt-1-density-97dpi-preview",
    exposures: tuple[int, int, int] = _DENSITY_F03_DENOMINATORS,
) -> NikonDensityExposureBinding:
    return NikonDensityExposureBinding(
        session_id=session_id,
        capture_attempt_id=capture_attempt_id,
        scan_identity=scan_identity,
        density_f03_exposures_raw_10ns=exposures,
    )


def test_archived_read_8c_payloads_are_the_descriptor_numerators() -> None:
    calibration = _calibration()

    assert calibration.numerators == _NUMERATORS
    assert calibration.payload_sha256 == tuple(
        hashlib.sha256(payload).hexdigest() for payload in _PAYLOADS
    )
    assert calibration.payload_hex == tuple(payload.hex() for payload in _PAYLOADS)
    assert calibration.to_dict()["numerators_rgb"] == list(_NUMERATORS)
    assert DensityCalibration.from_dict(calibration.to_dict()) == calibration


def test_calibration_journal_record_refuses_missing_provenance() -> None:
    record = _calibration().to_dict()
    del record["payload_sha256_rgb"]

    with pytest.raises(ValueError, match="malformed"):
        DensityCalibration.from_dict(record)


@pytest.mark.parametrize(
    ("field", "replacement", "message"),
    [
        ("numerators_rgb", 1, "decoded value"),
        ("payload_hex_rgb", "00" * 10, "header"),
        ("payload_sha256_rgb", "0" * 64, "SHA-256"),
    ],
)
def test_calibration_journal_record_refuses_inconsistent_raw_provenance(
    field: str,
    replacement: object,
    message: str,
) -> None:
    record = _calibration().to_dict()
    values = record[field]
    assert isinstance(values, list)
    values[0] = replacement

    with pytest.raises(ValueError, match=message):
        DensityCalibration.from_dict(record)


@pytest.mark.parametrize(
    ("cdb", "payload", "message"),
    [
        (_CDBS[0][:-1], _PAYLOADS[0], "exactly 10 bytes"),
        (bytes.fromhex("28008c00040300000a80"), _PAYLOADS[0], "not an RGB"),
        (bytes.fromhex("28008c00010200000a80"), _PAYLOADS[0], "pinned form"),
        (_CDBS[0], _PAYLOADS[0][:-1], "exactly 10 bytes"),
        (_CDBS[0], b"\x00" + _PAYLOADS[0][1:], "header"),
        (_CDBS[0], _PAYLOADS[0][:6] + b"\x00" * 4, "nonzero uint32"),
    ],
)
def test_calibration_decoder_refuses_any_unpinned_command_or_payload(
    cdb: bytes,
    payload: bytes,
    message: str,
) -> None:
    with pytest.raises(ValueError, match=message):
        decode_density_calibration_read(cdb, payload)


def test_calibration_group_requires_ordered_rgb_reads() -> None:
    reads = [
        decode_density_calibration_read(cdb, payload)
        for cdb, payload in zip(_CDBS, _PAYLOADS, strict=True)
    ]

    with pytest.raises(ValueError, match="ordered R, G, B"):
        assemble_density_calibration(reads[::-1], session_id="reservation-7")


def test_proven_source_contract_discards_tail_and_preserves_planar_rgb() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    binding = _source_binding(wire, image)

    decoded = decode_nikon_density_source(wire, binding=binding)

    assert binding.resolution_dpi == DENSITY_SOURCE_RESOLUTION_DPI
    assert binding.input_channels == DENSITY_SOURCE_INPUT_CHANNELS
    assert binding.sample_bits == DENSITY_SOURCE_SAMPLE_BITS
    assert binding.byte_order == DENSITY_SOURCE_BYTE_ORDER
    assert DENSITY_SOURCE_NATIVE_RESOLUTION_DPI == 4_000
    assert DENSITY_SOURCE_NATIVE_WIDTH == 3_946
    assert DENSITY_SOURCE_NATIVE_HEIGHT == 250_278
    assert DENSITY_SOURCE_SCALE_DIVISOR == int(4_000 / 97) == 41
    assert DENSITY_SOURCE_WIDTH == int(3_946 / 41) == 96
    assert DENSITY_SOURCE_HEIGHT == int(250_278 / 41) == 6_104
    assert DENSITY_SOURCE_RGB_ROW_BYTES == 576
    assert DENSITY_SOURCE_OPAQUE_ROW_TAIL_BYTES == 448
    assert DENSITY_SOURCE_DISCARDED_ROW_BYTES == 448
    assert DENSITY_SOURCE_ROW_STRIDE_BYTES == 1_024
    assert DENSITY_SOURCE_WIRE_BYTES == 6_250_496
    assert DENSITY_SOURCE_CHILD_BYTES == 3_515_904
    assert decoded.dtype == np.dtype(np.uint16)
    assert decoded.shape == (6_104, 96, 3)
    assert np.array_equal(decoded, image)
    assert NikonDensitySourceBinding.from_dict(binding.to_dict()) == binding


def test_37_record_source_geometry_replays_with_truthful_receipt() -> None:
    image = _source_image(height=5_668)
    wire = _wire_from_image(image)
    binding = _source_binding(
        wire,
        image,
        native_height=232_401,
    )

    decoded = decode_nikon_density_source(wire, binding=binding)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="slot-4-attempt-1",
        scan_identity="slot-4-attempt-1-density-97dpi-preview",
        source_native_height=232_401,
        source_height=5_668,
    )

    assert len(wire) == 5_804_032
    assert decoded.shape == (5_668, 96, 3)
    assert np.array_equal(decoded, image)
    assert binding.native_height == 232_401
    assert binding.height == 5_668
    assert NikonDensitySourceBinding.from_dict(binding.to_dict()) == binding
    assert evidence.source_binding == binding
    assert evidence.to_dict()["source_payload_bytes"] == 5_804_032
    assert evidence.result.to_dict()["source_native_height"] == 232_401
    assert evidence.result.to_dict()["source_geometry"] == [5_668, 96, 3]


def test_observed_6_record_source_geometry_replays_with_truthful_receipt() -> None:
    native_height, height = density_source_geometry_for_startup_records(6)
    image = _source_image(height=height)
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="preview-7vgsdf1f",
        scan_identity="reservation-7:density-97dpi:observed-six-record",
        source_native_height=native_height,
        source_height=height,
    )

    assert (native_height, height) == (47_672, 1_162)
    assert len(wire) == 1_189_888
    assert evidence.source_binding.native_height == 47_672
    assert evidence.source_binding.height == 1_162
    assert evidence.to_dict()["source_payload_bytes"] == 1_189_888
    assert evidence.result.to_dict()["source_geometry"] == [1_162, 96, 3]


@pytest.mark.parametrize("startup_records", range(2, 41))
def test_density_source_policy_covers_every_validated_startup_count(
    startup_records: int,
) -> None:
    native_height, height = density_source_geometry_for_startup_records(
        startup_records
    )

    assert (native_height, height) in DENSITY_SOURCE_SUPPORTED_HEIGHTS
    assert height % 2 == 0
    assert native_height // DENSITY_SOURCE_SCALE_DIVISOR == height
    assert height * DENSITY_SOURCE_ROW_STRIDE_BYTES > 0


@pytest.mark.parametrize("startup_records", (None, True, 0, 1, 41, 2.0))
def test_density_source_policy_refuses_unvalidated_startup_counts(
    startup_records: object,
) -> None:
    with pytest.raises(ValueError, match="2..40"):
        density_source_geometry_for_startup_records(startup_records)


def test_density_evaluator_uses_first_maximum_and_skips_saturated_rows() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    calibration_binding = _calibration_binding()
    exposure_binding = _exposure_binding()

    result = evaluate_nikon_density(
        wire,
        calibration_binding=calibration_binding,
        source_binding=_source_binding(wire, image),
        exposure_binding=exposure_binding,
    )

    assert result.algorithm_id == ALGORITHM_ID
    assert result.numerators == _NUMERATORS
    assert result.density_f03_denominators == _DENSITY_F03_DENOMINATORS
    assert result.promotable is True
    assert result.exposure_binding_status == EXPOSURE_BINDING_STATUS
    assert result.exposure_binding_status.startswith("proven-")
    assert result.arithmetic_backend_status == ARITHMETIC_BACKEND_STATUS
    assert result.source_binding_status == SOURCE_BINDING_STATUS
    assert result.source_binding_status.startswith("proven-")
    assert result.to_dict()["promotable"] is True
    assert result.to_dict()["calibration_payload_sha256_rgb"] == list(
        _calibration().payload_sha256
    )
    assert result.to_dict()["source_row_stride_bytes"] == 1_024
    assert result.to_dict()["source_opaque_row_tail_bytes"] == 448
    assert result.to_dict()["source_discarded_row_bytes"] == 448
    assert result.to_dict()["source_layout"] == DENSITY_SOURCE_LAYOUT
    assert result.selected_rows == (100, 100, 100)
    assert result.selected_row_means == (45_000.0, 40_000.0, 32_000.0)
    expected = tuple(
        math.log10(65_535.0 / ((float(numerator) * mean) / float(denominator)))
        for numerator, denominator, mean in zip(
            _NUMERATORS,
            _DENSITY_F03_DENOMINATORS,
            result.selected_row_means,
            strict=True,
        )
    )
    assert result.raw_densities == expected
    assert result.densities == expected
    assert result.fallback_applied == (False, False, False)
    assert (
        NikonDensityExposureBinding.from_dict(exposure_binding.to_dict())
        == exposure_binding
    )
    assert (
        NikonDensityCalibrationBinding.from_dict(calibration_binding.to_dict())
        == calibration_binding
    )


def test_archived_density_means_reproduce_all_three_binary64_outputs_exactly() -> None:
    image = _archived_means_source_image()
    wire = _wire_from_image(image)
    result = evaluate_nikon_density(
        wire,
        calibration_binding=_calibration_binding(),
        source_binding=_source_binding(wire, image),
        exposure_binding=_exposure_binding(),
    )

    assert result.selected_rows == (129, 128, 126)
    assert result.selected_row_means == (
        3_185_488 / 96.0,
        2_795_531 / 96.0,
        2_186_679 / 96.0,
    )
    assert tuple(struct.pack(">d", value).hex() for value in result.densities) == (
        "3fd8b159777b9d5f",
        "3fe9cc75f7f6705a",
        "3ff0b0dae0533338",
    )
    assert result.to_dict()["density_binary64_be_hex_rgb"] == [
        "3fd8b159777b9d5f",
        "3fe9cc75f7f6705a",
        "3ff0b0dae0533338",
    ]


def test_preview_evidence_keeps_raw_source_and_requires_explicit_ownership() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="slot-4-attempt-1",
        scan_identity="slot-4-attempt-1-density-97dpi-preview",
    )

    assert isinstance(evidence, NikonDensityEvidence)
    assert evidence.source_payload == wire
    assert evidence.result.promotable is True
    assert evidence.scope == "reservation-preview"
    assert evidence.per_frame_binding_status == (
        "requires-explicit-frame-ownership-receipt"
    )
    receipt = evidence.to_dict()
    assert receipt["source_payload_bytes"] == DENSITY_SOURCE_WIRE_BYTES
    assert receipt["schema_version"] == 1
    assert receipt["preview_identity_sha256"] == evidence.preview_identity_sha256
    assert len(evidence.preview_identity_sha256) == 64
    assert (
        receipt["per_frame_binding_status"]
        == "requires-explicit-frame-ownership-receipt"
    )
    assert "source_payload" not in receipt


def test_frame_ownership_binds_exact_preview_reservation_and_registration() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="slot-4-attempt-1",
        scan_identity="slot-4-attempt-1-density-97dpi-preview",
    )
    ownership = build_nikon_density_frame_ownership(
        evidence,
        reservation_id="reservation-7",
        batch_session_id="reservation-7",
        transport_table_sha256="1" * 64,
        reviewed_fingerprint_sha256="2" * 64,
        fresh_fingerprint_sha256="3" * 64,
        frame_capture_attempt_id="slot-4-attempt-1",
        frame_index=1,
        frame_total=2,
        selected_slots=(4, 5),
        selected_slot=4,
    )

    ownership.validate_evidence(evidence)
    assert ownership.scope == "reservation-preview-frame"
    assert ownership.preview_sha256 == evidence.source_binding.wire_sha256
    assert ownership.preview_identity_sha256 == evidence.preview_identity_sha256
    assert ownership.session_reservation_retained is True
    assert len(ownership.transport_identity_sha256) == 64
    assert NikonDensityFrameOwnershipReceipt.from_dict(ownership.to_dict()) == ownership


def _exact_builder_inputs() -> tuple[
    NikonDensityEvidence,
    NikonDensityFrameOwnershipReceipt,
    np.ndarray,
]:
    image = _source_image()
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="preview-attempt-1",
        scan_identity="reservation-7-density-97dpi-preview",
    )
    ownership = build_nikon_density_frame_ownership(
        evidence,
        reservation_id="reservation-7",
        batch_session_id="reservation-7",
        transport_table_sha256="1" * 64,
        reviewed_fingerprint_sha256="2" * 64,
        fresh_fingerprint_sha256="3" * 64,
        frame_capture_attempt_id="slot-4-attempt-1",
        frame_index=1,
        frame_total=1,
        selected_slots=(4,),
        selected_slot=4,
    )
    analyzer = (
        np.arange(np.prod(NIKON_ANALYZER_SHAPE), dtype=np.uint32)
        .reshape(NIKON_ANALYZER_SHAPE)
        .astype(np.uint16)
    )
    return evidence, ownership, analyzer


def test_exact_builder_evidence_snapshots_and_binds_all_frame_inputs() -> None:
    evidence, ownership, analyzer = _exact_builder_inputs()
    builder = build_nikon_exact_builder_evidence(
        evidence,
        ownership,
        analyzer_rgb=analyzer,
        final_f02_denominators=(100_001, 100_002, 100_003),
    )

    assert isinstance(builder, NikonExactBuilderEvidence)
    assert builder.capture_attempt_id == "slot-4-attempt-1"
    assert builder.scan_identity == "reservation-7-density-97dpi-preview"
    assert builder.slot == 4
    assert builder.final_f02_denominators == (100_001, 100_002, 100_003)
    assert builder.density_f03_denominators == _DENSITY_F03_DENOMINATORS
    assert builder.analyzer_rgb.flags.writeable is False
    original = int(builder.analyzer_rgb[0, 0, 0])
    analyzer[0, 0, 0] = original + 1
    assert int(builder.analyzer_rgb[0, 0, 0]) == original
    builder.validate_bindings(evidence, ownership)


def test_exact_builder_evidence_refuses_analyzer_or_identity_tampering() -> None:
    evidence, ownership, analyzer = _exact_builder_inputs()
    builder = build_nikon_exact_builder_evidence(
        evidence,
        ownership,
        analyzer_rgb=analyzer,
        final_f02_denominators=(100_001, 100_002, 100_003),
    )

    with pytest.raises(ValueError, match="analyzer snapshot SHA-256"):
        replace(builder, analyzer_rgb_sha256="0" * 64)
    changed_analyzer = builder.analyzer_rgb.copy()
    changed_analyzer[0, 0, 0] ^= 1
    with pytest.raises(ValueError, match="analyzer snapshot SHA-256"):
        replace(builder, analyzer_rgb=changed_analyzer)
    changed_ownership = replace(
        ownership,
        frame_capture_attempt_id="slot-4-attempt-2",
    )
    with pytest.raises(ValueError, match="ownership receipt changed"):
        builder.validate_bindings(evidence, changed_ownership)


def test_exact_builder_evidence_refuses_conflated_f03_and_final_f02() -> None:
    evidence, ownership, analyzer = _exact_builder_inputs()

    with pytest.raises(ValueError, match="f03 and final f02"):
        build_nikon_exact_builder_evidence(
            evidence,
            ownership,
            analyzer_rgb=analyzer,
            final_f02_denominators=_DENSITY_F03_DENOMINATORS,
        )


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"reservation_id": "another-reservation"}, "reservation and batch"),
        ({"batch_session_id": "another-reservation"}, "reservation and batch"),
        ({"preview_sha256": "4" * 64}, "preview does not match"),
        ({"preview_identity_sha256": "5" * 64}, "preview identity"),
        ({"frame_capture_attempt_id": ""}, "frame_capture_attempt_id"),
        ({"selected_slot": 5}, "selected_slot"),
    ],
)
def test_frame_ownership_invalidates_on_missing_or_changed_identity(
    changes: dict[str, object],
    message: str,
) -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="slot-4-attempt-1",
        scan_identity="slot-4-attempt-1-density-97dpi-preview",
    )
    ownership = build_nikon_density_frame_ownership(
        evidence,
        reservation_id="reservation-7",
        batch_session_id="reservation-7",
        transport_table_sha256="1" * 64,
        reviewed_fingerprint_sha256="2" * 64,
        fresh_fingerprint_sha256="3" * 64,
        frame_capture_attempt_id="slot-4-attempt-1",
        frame_index=1,
        frame_total=2,
        selected_slots=(4, 5),
        selected_slot=4,
    )

    with pytest.raises(ValueError, match=message):
        changed = replace(ownership, **changes)
        changed.validate_evidence(evidence)


def test_frame_ownership_refuses_transport_digest_tampering() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="slot-4-attempt-1",
        scan_identity="slot-4-attempt-1-density-97dpi-preview",
    )
    receipt = build_nikon_density_frame_ownership(
        evidence,
        reservation_id="reservation-7",
        batch_session_id="reservation-7",
        transport_table_sha256="1" * 64,
        reviewed_fingerprint_sha256="2" * 64,
        fresh_fingerprint_sha256="3" * 64,
        frame_capture_attempt_id="slot-4-attempt-1",
        frame_index=1,
        frame_total=1,
        selected_slots=(4,),
        selected_slot=4,
    ).to_dict()
    receipt["transport_identity_sha256"] = "0" * 64

    with pytest.raises(ValueError, match="transport identity"):
        NikonDensityFrameOwnershipReceipt.from_dict(receipt)


def test_runtime_arithmetic_gate_refuses_one_ulp_log10_drift(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    verify_nikon_density_arithmetic_backend()
    real_log10 = density_module.math.log10

    def drifted_log10(value: float) -> float:
        return math.nextafter(real_log10(value), math.inf)

    monkeypatch.setattr(density_module.math, "log10", drifted_log10)
    with pytest.raises(RuntimeError, match="not bit-exact"):
        verify_nikon_density_arithmetic_backend()


def test_capture_boundary_rebuilds_density_evidence_from_hash_bound_source(
    tmp_path: Path,
) -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    evidence = build_nikon_density_evidence(
        wire,
        calibration=_calibration(),
        density_f03_exposures_raw_10ns=_DENSITY_F03_DENOMINATORS,
        session_id="reservation-7",
        capture_attempt_id="slot-4-attempt-1",
        scan_identity="slot-4-attempt-1-density-97dpi-preview",
    )
    output_path = tmp_path / "capture.bin"
    output_path.with_name("capture-preview.bin").write_bytes(wire)

    rebuilt = _validated_density_evidence(
        {"nikon_density_evidence": evidence.to_dict()},
        output_path=output_path,
    )

    assert rebuilt == evidence


def test_channel_range_gates_apply_the_vendor_fallbacks() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    result = evaluate_nikon_density(
        wire,
        calibration_binding=_calibration_binding(),
        source_binding=_source_binding(wire, image),
        exposure_binding=_exposure_binding(exposures=(1, 1, 1)),
    )

    assert result.densities == (0.316, 0.737, 0.886)
    assert result.fallback_applied == (True, True, True)


@pytest.mark.parametrize(
    ("calibration_binding", "exposure", "message"),
    [
        (_calibration_binding("another-reservation"), _exposure_binding(), "session"),
        (
            _calibration_binding(capture_attempt_id="another-attempt"),
            _exposure_binding(),
            "capture attempt",
        ),
        (
            _calibration_binding(scan_identity="another-scan"),
            _exposure_binding(),
            "scan",
        ),
        (
            _calibration_binding(),
            _exposure_binding(capture_attempt_id="another-attempt"),
            "capture attempt",
        ),
        (
            _calibration_binding(),
            _exposure_binding(scan_identity="another-scan"),
            "scan",
        ),
    ],
)
def test_density_evaluator_refuses_cross_scan_identity_mixups(
    calibration_binding: NikonDensityCalibrationBinding,
    exposure: NikonDensityExposureBinding,
    message: str,
) -> None:
    image = _source_image()
    wire = _wire_from_image(image)

    with pytest.raises(ValueError, match=message):
        evaluate_nikon_density(
            wire,
            calibration_binding=calibration_binding,
            source_binding=_source_binding(wire, image),
            exposure_binding=exposure,
        )


def test_source_decoder_refuses_wrong_wire_or_compact_digest() -> None:
    image = _source_image()
    wire = _wire_from_image(image)
    binding = _source_binding(wire, image)

    with pytest.raises(ValueError, match="meter payload does not match"):
        decode_nikon_density_source(
            wire,
            binding=replace(binding, wire_sha256="0" * 64),
        )
    with pytest.raises(ValueError, match="compact child buffer does not match"):
        decode_nikon_density_source(
            wire,
            binding=replace(binding, child_buffer_sha256="0" * 64),
        )
    with pytest.raises(ValueError, match="compact big-endian buffer does not match"):
        decode_nikon_density_source(
            wire,
            binding=replace(binding, compact_buffer_be_sha256="0" * 64),
        )


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        (b"", "exactly 6250496"),
        (b"\x00" * (6_104 * 96 * 3 * 2), "exactly 6250496"),
        (b"\x00" * 1_088_000, "exactly 6250496"),
        (np.zeros((6_104, 96, 3), dtype=np.uint16), "bytes-like"),
    ],
)
def test_source_decoder_refuses_truncated_compacted_rgb_only_or_decoded_inputs(
    payload: object,
    message: str,
) -> None:
    image = _source_image()
    wire = _wire_from_image(image)

    with pytest.raises((TypeError, ValueError), match=message):
        decode_nikon_density_source(payload, binding=_source_binding(wire, image))


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"resolution_dpi": 4000}, "resolution_dpi"),
        ({"native_resolution_dpi": 3_999}, "native_resolution_dpi"),
        ({"native_width": 3_945}, "native_width"),
        ({"native_height": 250_277}, "native_height"),
        ({"scale_divisor": 40}, "scale_divisor"),
        ({"width": 95}, "width"),
        ({"height": 6_103}, "height"),
        ({"input_channels": 4}, "input_channels"),
        ({"density_channels": 4}, "density_channels"),
        ({"sample_bits": 8}, "sample_bits"),
        ({"rgb_row_bytes": 575}, "rgb_row_bytes"),
        ({"row_stride_bytes": 1_023}, "row_stride_bytes"),
        ({"opaque_row_tail_bytes": 447}, "opaque_row_tail_bytes"),
        ({"discarded_row_bytes": 447}, "discarded_row_bytes"),
        ({"layout": "interleaved-rgbi"}, "layout"),
        ({"byte_order": "little"}, "byte_order"),
        ({"scan_identity": ""}, "scan_identity"),
    ],
)
def test_source_binding_refuses_any_nonvendor_geometry_or_identity(
    changes: dict[str, object],
    message: str,
) -> None:
    image = _source_image()
    wire = _wire_from_image(image)

    with pytest.raises(ValueError, match=message):
        replace(_source_binding(wire, image), **changes)


@pytest.mark.parametrize(
    ("native_height", "height"),
    (
        (232_401, 6_104),
        (250_278, 5_668),
        (232_400, 5_668),
        (47_672, 1_308),
        (47_671, 1_162),
    ),
)
def test_source_binding_refuses_unproven_height_pairs(
    native_height: int,
    height: int,
) -> None:
    wire = _wire_from_image(_source_image())

    with pytest.raises(ValueError, match="proven preview geometry"):
        bind_nikon_density_source(
            wire,
            session_id="reservation-7",
            capture_attempt_id="slot-4-attempt-1",
            scan_identity="slot-4-attempt-1-density-97dpi-preview",
            native_height=native_height,
            height=height,
        )


def test_density_evaluator_refuses_a_zero_signal_source() -> None:
    image = np.zeros((6_104, 96, 3), dtype=np.uint16)
    wire = _wire_from_image(image)

    with pytest.raises(MeterUnusableError, match="channel R"):
        evaluate_nikon_density(
            wire,
            calibration_binding=_calibration_binding(),
            source_binding=_source_binding(wire, image),
            exposure_binding=_exposure_binding(),
        )


def test_density_evaluator_raises_meter_unusable_on_all_zero_g_channel() -> None:
    # #17 reproduced exactly: R/B are usable in the primary meter window but
    # the G rows are all zero (B&W strip / modified SA-21 / dense negative),
    # so neither the primary nor the widened window finds a G mean. This must
    # surface as the typed METER_UNUSABLE error for G, never a bare ValueError.
    image = np.zeros((6_104, 96, 3), dtype=np.uint16)
    image[100, :, 0] = 45_000  # R usable in primary window
    image[101, :, 0] = 45_000
    image[100, :, 2] = 32_000  # B usable in primary window
    image[101, :, 2] = 32_000
    wire = _wire_from_image(image)

    with pytest.raises(MeterUnusableError, match="channel G"):
        evaluate_nikon_density(
            wire,
            calibration_binding=_calibration_binding(),
            source_binding=_source_binding(wire, image),
            exposure_binding=_exposure_binding(),
        )


def test_density_evaluator_raises_meter_unusable_on_saturated_rows() -> None:
    # Every row is at full scale (>= SATURATION_LIMIT), so no row is usable;
    # the extra space outside the primary window is saturated too, so the
    # widened retry also finds nothing and the typed error is raised.
    image = np.full((6_104, 96, 3), 65_535, dtype=np.uint16)
    wire = _wire_from_image(image)

    with pytest.raises(MeterUnusableError, match="channel R"):
        evaluate_nikon_density(
            wire,
            calibration_binding=_calibration_binding(),
            source_binding=_source_binding(wire, image),
            exposure_binding=_exposure_binding(),
        )


def test_density_evaluator_widened_window_retry_succeeds_on_sparse_rows() -> None:
    # G has no usable mean in the primary meter window [75, 225) but a usable
    # mean exists just past it, inside the bounded widened window (3x the
    # primary band's 150-row height, centered on it: [0, 375) for this
    # [75, 225) band -- see _widened_meter_window). R and B are usable in the
    # primary window. Lane B must recover via the widened retry rather than
    # raising -- selecting the G row from outside the primary band but still
    # inside the bounded retry window.
    image = np.zeros((6_104, 96, 3), dtype=np.uint16)
    image[100, :, 0] = 45_000  # R usable in primary window
    image[101, :, 0] = 45_000
    image[100, :, 2] = 32_000  # B usable in primary window
    image[101, :, 2] = 32_000
    image[300, :, 1] = 5_000  # G usable ONLY in the bounded widened window
    wire = _wire_from_image(image)

    result = evaluate_nikon_density(
        wire,
        calibration_binding=_calibration_binding(),
        source_binding=_source_binding(wire, image),
        exposure_binding=_exposure_binding(),
    )
    assert result.selected_rows[1] == 300
    assert result.selected_row_means[1] == pytest.approx(5_000.0)
    # R and B were resolved from the primary window (first occurrence of the
    # greatest mean, row 100).
    assert result.selected_rows[0] == 100
    assert result.selected_rows[2] == 100


def test_density_evaluator_raises_meter_unusable_for_a_row_far_outside_the_bounded_widened_window() -> None:
    # Fail-closed erosion fix: the widened retry is now bounded to 3x the
    # primary band's height ([0, 375) for the [75, 225) band), not the whole
    # 6,104-row frame. A usable row far outside that bound (row 400) was
    # reachable by the old unbounded [0, height) retry and would have been
    # silently selected; it must now raise the typed error instead.
    image = np.zeros((6_104, 96, 3), dtype=np.uint16)
    image[100, :, 0] = 45_000  # R usable in primary window
    image[101, :, 0] = 45_000
    image[100, :, 2] = 32_000  # B usable in primary window
    image[101, :, 2] = 32_000
    image[400, :, 1] = 5_000  # G usable ONLY far outside the bounded window
    wire = _wire_from_image(image)

    with pytest.raises(MeterUnusableError, match="channel G"):
        evaluate_nikon_density(
            wire,
            calibration_binding=_calibration_binding(),
            source_binding=_source_binding(wire, image),
            exposure_binding=_exposure_binding(),
        )


def test_exposure_binding_refuses_out_of_contract_values() -> None:
    with pytest.raises(ValueError, match="R, G, B"):
        NikonDensityExposureBinding(
            session_id="reservation-7",
            capture_attempt_id="slot-4-attempt-1",
            scan_identity="slot-4-attempt-1-density-97dpi-preview",
            density_f03_exposures_raw_10ns=(*_DENSITY_F03_DENOMINATORS, 289_332),
        )
