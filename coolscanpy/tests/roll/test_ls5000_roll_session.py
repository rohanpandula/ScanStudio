"""Offline contracts for an LS-5000 whole-roll preview session."""

from __future__ import annotations

import hashlib
import json
import struct
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass import roll_index
from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    AttemptPaths,
    CaptureAttemptResult,
    CaptureMode,
    CaptureOutcome,
    CaptureRequest,
)
from coolscanpy.protocol.ls5000_single_pass.plan import CANONICAL_PLAN_SHA256
from coolscanpy.protocol.ls5000_single_pass.density import (
    DensityCalibration,
    build_nikon_density_evidence,
)
from coolscanpy.roll.preview_session import (
    CaptureRoute,
    RollSessionIntegrityError,
    _preview_binding_contract,
    build_roll_preview_session,
    reload_thumbnail,
)
from coolscanpy.roll.controls import ScanMaterial


_DENSITY_CALIBRATION_PAYLOADS = tuple(
    bytes.fromhex(value)
    for value in (
        "8c20000000040000df1a",
        "8c20000000040000bba4",
        "8c200000000400007fab",
    )
)
_DENSITY_CALIBRATION_NUMERATORS = (57_114, 48_036, 32_683)


def _density_calibration(session_id: str) -> DensityCalibration:
    return DensityCalibration(
        session_id=session_id,
        numerators=_DENSITY_CALIBRATION_NUMERATORS,
        payload_hex=tuple(payload.hex() for payload in _DENSITY_CALIBRATION_PAYLOADS),
        payload_sha256=tuple(
            hashlib.sha256(payload).hexdigest()
            for payload in _DENSITY_CALIBRATION_PAYLOADS
        ),
    )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _encode_index(rgb16: np.ndarray) -> bytes:
    """Encode the compact RGB96 index rows used by the scanner."""

    blocks = np.zeros(
        (rgb16.shape[0] // 2, roll_index.INDEX_BLOCK_WORDS),
        dtype=np.uint16,
    )
    blocks[:, 0:96] = rgb16[0::2, :, 0]
    blocks[:, 96:192] = rgb16[0::2, :, 1]
    blocks[:, 192:288] = rgb16[0::2, :, 2]
    blocks[:, 512:608] = rgb16[1::2, :, 0]
    blocks[:, 608:704] = rgb16[1::2, :, 1]
    blocks[:, 704:800] = rgb16[1::2, :, 2]
    blocks[:, 800::2] = roll_index.INDEX_TRAILER_MARK
    blocks[:, 801::2] = np.arange(
        roll_index.INDEX_TRAILER_COUNTER0,
        roll_index.INDEX_TRAILER_COUNTER0 + roll_index.INDEX_TRAILER_WORDS // 2,
        dtype=np.uint16,
    )
    return blocks.astype(">u2", copy=False).tobytes()


def _synthetic_index(
    *,
    height: int = 6_104,
    frame_count: int = 40,
    content_frames: int = 40,
    leader: int = 128,
) -> np.ndarray:
    """Make textured cells separated by physical clear-film gaps."""

    pitch = 143
    boundaries = [leader + index * pitch for index in range(frame_count + 1)]
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
    if content_frames < frame_count:
        clear_start = boundaries[content_frames]
        aperture[clear_start:] = clear_base + clear_noise[clear_start:]
    rgb = np.empty((height, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16)


def _transport_table(rows: int) -> bytes:
    records = bytearray()
    for row in range(rows):
        records.extend(struct.pack(">HH", 6 * (row % 18), row // 18))
    total = 8 + len(records)
    return b"\x00\x8e\x00\x00" + total.to_bytes(2, "big") + b"\x00\x00" + bytes(records)


@dataclass(frozen=True)
class PreviewFixture:
    result: CaptureAttemptResult
    rgb: np.ndarray


def _preview_fixture(
    tmp_path: Path,
    *,
    content_frames: int = 40,
    slot_capacity_hint: int = 40,
    active_rgb: np.ndarray | None = None,
    density_capture_attempt_id: str | None = None,
    density_scan_identity: str | None = None,
) -> PreviewFixture:
    contract = _preview_binding_contract(slot_capacity_hint)
    native_height = contract["native_height"]
    decoded_height = contract["decoded_height"]
    startup_status = contract["startup_status"]
    preview_binding = {
        key: value for key, value in contract.items() if key != "startup_status"
    }
    assert isinstance(native_height, int)
    assert isinstance(decoded_height, int)
    assert isinstance(startup_status, str)
    attempt = tmp_path / "preview-attempt"
    attempt.mkdir()
    output = attempt / "capture.bin"
    output.write_bytes(b"")
    preview_path = attempt / "capture-preview.bin"
    table_path = attempt / "capture-008e.bin"
    mapping_path = attempt / "capture-frame-map.json"
    if active_rgb is None:
        rgb = _synthetic_index(
            height=decoded_height,
            content_frames=content_frames,
        )
        usable_rows = len(rgb)
        preview = _encode_index(rgb)
    else:
        if active_rgb.ndim != 3 or active_rgb.shape[1:] != (96, 3):
            raise ValueError("active preview RGB must have shape (rows, 96, 3)")
        if not 0 < len(active_rgb) < decoded_height:
            raise ValueError("active preview RGB must fit inside the allocation")
        usable_rows = len(active_rgb)
        rgb = np.zeros((decoded_height, 96, 3), dtype=np.uint16)
        rgb[:usable_rows] = active_rgb
        rows = np.frombuffer(_encode_index(rgb), dtype=">u2").copy().reshape(
            decoded_height,
            roll_index.INDEX_ROW_WORDS,
        )
        rows[usable_rows:] = rows[usable_rows]
        preview = rows.astype(">u2", copy=False).tobytes()
    table = _transport_table(usable_rows)
    preview_path.write_bytes(preview)
    table_path.write_bytes(table)
    density_session_id = "single-reservation-roll-preview"
    density_exposures = (71_373, 137_524, 126_126)
    preview_sha256 = _sha256(preview)
    density_attempt_id = density_capture_attempt_id or attempt.name
    density_identity = density_scan_identity or (
        f"{density_session_id}:density-97dpi:{preview_sha256}"
    )
    density_evidence = build_nikon_density_evidence(
        preview,
        calibration=_density_calibration(density_session_id),
        density_f03_exposures_raw_10ns=density_exposures,
        session_id=density_session_id,
        capture_attempt_id=density_attempt_id,
        scan_identity=density_identity,
        source_native_height=native_height,
        source_height=decoded_height,
    )
    receipt = {
        "status": "preview-only-complete",
        "slot_capacity_hint": slot_capacity_hint,
        "slot_capacity_semantics": (
            "scanner-addressable preview slots; not an exposure count"
        ),
        "preview_bytes": len(preview),
        "preview_sha256": preview_sha256,
        "table_bytes": len(table),
        "table_sha256": _sha256(table),
        "frame_detection": "deferred-offline",
        "startup_table": {
            "count": slot_capacity_hint,
            "sha256": "a" * 64,
            "status": startup_status,
        },
        "preview_binding": preview_binding,
    }
    mapping_path.write_text(json.dumps(receipt), encoding="utf-8")
    journal_path = attempt / "journal.json"
    engine_sha256 = "b" * 64
    journal = {
        "status": "complete",
        "capture_mode": "preview-only",
        "requested_frame": None,
        "requested_boundary_offset_rows": 0,
        "expected_frame_count": None,
        "expected_reads": 0,
        "completed_reads": 0,
        "expected_bytes": 0,
        "completed_bytes": 0,
        "disk_bytes": 0,
        "unit_released": True,
        "output": str(output.resolve()),
        "output_sha256": _sha256(b""),
        "plan_sha256": CANONICAL_PLAN_SHA256,
        "capture_engine_sha256": engine_sha256,
        "scanner_identity": "Nikon LS-5000 ED 1.03",
        "expected_usb_bus": 1,
        "expected_usb_address": 2,
        "actual_usb_bus": 1,
        "actual_usb_address": 2,
        "preview_geometry_validated_before_reads": True,
        "preview_windows": [
            {
                "color_id": color,
                "resolution": [97, 97],
                "origin": [0, 0],
                "size": [3_946, native_height],
                "bit_depth": 16,
                "density_f03_exposure_raw_10ns": exposure,
            }
            for color, exposure in zip(
                (1, 2, 3),
                density_exposures,
                strict=True,
            )
        ],
        "density_calibration_session_id": density_session_id,
        "nikon_density_evidence": density_evidence.to_dict(),
        "live_startup_0x8f": {
            "count": slot_capacity_hint,
            "sha256": "a" * 64,
        },
        "live_startup_0x8f_status": startup_status,
        "live_preview_binding": preview_binding,
        "live_index_artifacts": {
            "mapping": str(mapping_path.resolve()),
            "preview": str(preview_path.resolve()),
            "table": str(table_path.resolve()),
        },
        "live_index_evidence": {
            "status": "persisted-before-frame-detection",
            "preview_bytes": len(preview),
            "preview_sha256": _sha256(preview),
            "table_bytes": len(table),
            "table_sha256": _sha256(table),
        },
        "preview_only_receipt": receipt,
    }
    journal_path.write_text(json.dumps(journal), encoding="utf-8")
    paths = AttemptPaths(
        directory=attempt,
        output=output,
        journal=journal_path,
        plan=attempt / "plan.jsonl",
        manifest=attempt / "manifest.json",
        bootstrap_status=attempt / "worker-bootstrap.json",
        stdout=attempt / "stdout.txt",
        stderr=attempt / "stderr.txt",
    )
    result = CaptureAttemptResult(
        outcome=CaptureOutcome.COMPLETE,
        request=CaptureRequest(mode=CaptureMode.PREVIEW),
        paths=paths,
        argv=("worker", "--preview-only"),
        returncode=0,
        stdout="",
        stderr="",
        journal=journal,
    )
    return PreviewFixture(result=result, rgb=rgb)


def test_complete_preview_builds_fixed_order_session_with_exact_transport_origins(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(tmp_path)

    session = build_roll_preview_session(
        fixture.result,
        material=ScanMaterial.COLOR_NEGATIVE,
    )

    assert session.geometry == roll_index.IndexGeometry(
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
    assert [slot.slot_id for slot in session.slots] == list(range(1, 41))
    assert all(slot.boundary_offset_rows == 0 for slot in session.slots)
    assert all(slot.thumbnail.shape[1:] == (96, 3) for slot in session.slots)
    assert all(slot.thumbnail.dtype == np.uint16 for slot in session.slots)
    assert session.selected_slots == ()
    assert session.preview.usb_topology == (1, 2)
    origin = session.resolve_origin(18, 0)
    assert origin.native_origin == 42 * origin.lookup_row
    assert origin is session.slots[17].base_origin


def test_37_record_preview_builds_dynamic_geometry_and_slots(tmp_path: Path) -> None:
    fixture = _preview_fixture(
        tmp_path,
        content_frames=37,
        slot_capacity_hint=37,
    )

    session = build_roll_preview_session(
        fixture.result,
        material=ScanMaterial.COLOR_NEGATIVE,
    )

    assert session.geometry == roll_index.IndexGeometry(
        requested_resolution=97,
        native_resolution=4_000,
        pitch=41,
        native_width=3_946,
        native_height=232_401,
        width=96,
        height=5_668,
        block_bytes=2_048,
        expected_stream_bytes=5_804_032,
    )
    assert [slot.slot_id for slot in session.slots] == list(range(1, 38))
    assert session.preview.preview_artifact.byte_length == 5_804_032


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("expected_usb_bus", None, "expected USB topology is invalid"),
        ("actual_usb_address", 0, "actual USB topology is invalid"),
        (
            "actual_usb_address",
            3,
            "actual USB topology differs from the expected device",
        ),
    ],
)
def test_preview_refuses_invalid_or_mismatched_usb_topology(
    tmp_path: Path,
    field: str,
    value: object,
    message: str,
) -> None:
    fixture = _preview_fixture(tmp_path)
    journal = json.loads(json.dumps(fixture.result.journal))
    journal[field] = value
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(RollSessionIntegrityError, match=message):
        build_roll_preview_session(replace(fixture.result, journal=journal))


@pytest.mark.parametrize("value", [None, True, 0, -1, 0x1_0000_0000])
def test_preview_refuses_invalid_density_f03_window_exposure(
    tmp_path: Path,
    value: object,
) -> None:
    fixture = _preview_fixture(tmp_path)
    journal = json.loads(json.dumps(fixture.result.journal))
    journal["preview_windows"][0]["density_f03_exposure_raw_10ns"] = value
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(
        RollSessionIntegrityError,
        match="density f03 exposure.*nonzero uint32",
    ):
        build_roll_preview_session(replace(fixture.result, journal=journal))


def test_preview_refuses_old_window_schema_without_density_f03_exposure(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(tmp_path)
    journal = json.loads(json.dumps(fixture.result.journal))
    del journal["preview_windows"][0]["density_f03_exposure_raw_10ns"]
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(
        RollSessionIntegrityError,
        match="preview window has an unexpected schema",
    ):
        build_roll_preview_session(replace(fixture.result, journal=journal))


def test_preview_refuses_density_f03_exposure_that_disagrees_with_evidence(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(tmp_path)
    journal = json.loads(json.dumps(fixture.result.journal))
    journal["preview_windows"][0]["density_f03_exposure_raw_10ns"] += 1
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(
        RollSessionIntegrityError,
        match="density f03 exposures disagree with their evidence",
    ):
        build_roll_preview_session(replace(fixture.result, journal=journal))


@pytest.mark.parametrize(
    "exposure_binding",
    [
        None,
        {},
        {
            "session_id": "single-reservation-roll-preview",
            "capture_attempt_id": "preview-attempt",
            "scan_identity": "scan",
            "density_f03_exposures_raw_10ns_rgb": [71_373, 137_524],
        },
    ],
)
def test_preview_refuses_malformed_density_exposure_evidence(
    tmp_path: Path,
    exposure_binding: object,
) -> None:
    fixture = _preview_fixture(tmp_path)
    journal = json.loads(json.dumps(fixture.result.journal))
    journal["nikon_density_evidence"]["exposure_binding"] = exposure_binding
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(
        RollSessionIntegrityError,
        match="preview density exposure evidence is malformed",
    ):
        build_roll_preview_session(replace(fixture.result, journal=journal))


@pytest.mark.parametrize("slot_capacity_hint", range(2, 41))
def test_preview_binding_contract_accepts_scanner_derived_startup_table_capacity(
    slot_capacity_hint: int,
) -> None:
    contract = _preview_binding_contract(slot_capacity_hint)

    assert contract["startup_records"] == slot_capacity_hint
    assert contract["decoded_height"] % 2 == 0
    assert contract["expected_stream_bytes"] == contract["decoded_height"] * 1_024
    assert contract["active_read_sequence_range"][0] == 118
    assert contract["active_read_sequence_range"][1] <= 165
    if slot_capacity_hint == 40:
        assert contract["startup_status"] == "0000000000000000"
    else:
        assert contract["startup_status"] == "022b4b0000000000"


def test_preview_session_accepts_the_observed_six_record_short_strip(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(
        tmp_path,
        content_frames=6,
        slot_capacity_hint=6,
    )

    session = build_roll_preview_session(fixture.result)

    assert session.geometry.native_height == _preview_binding_contract(6)["native_height"]
    assert len(session.slots) == 6
    assert fixture.result.density_evidence is not None
    assert fixture.result.density_evidence.source_binding.height == 1_162


def test_preview_session_keeps_one_row_clipped_first_frame_for_review(
    tmp_path: Path,
) -> None:
    complete = _synthetic_index(
        height=882,
        frame_count=6,
        content_frames=6,
        leader=0,
    )
    fixture = _preview_fixture(
        tmp_path,
        slot_capacity_hint=6,
        active_rgb=complete[1:],
    )

    session = build_roll_preview_session(
        fixture.result,
        material=ScanMaterial.COLOR_NEGATIVE,
    )

    assert session.preview.usable_rows == 881
    assert [slot.slot_id for slot in session.slots] == [1, 2, 3, 4, 5, 6]
    assert [
        (slot.start_boundary_row, slot.end_boundary_row) for slot in session.slots
    ] == [
        (0, 142),
        (142, 285),
        (285, 428),
        (428, 571),
        (571, 714),
        (714, 857),
    ]
    leading = session.slots[0]
    assert leading.manual_review
    assert {
        "start-outside-index-raster",
        "partial-index-coverage",
        "outside-index-raster",
        "transport-origin-inferred",
    }.issubset(leading.warnings)
    assert leading.base_origin.method == "affine-guided-local-lookup"
    assert leading.base_origin.manual_review
    assert not leading.base_origin.automatic
    np.testing.assert_array_equal(leading.thumbnail, fixture.rgb[:142])
    assert all(
        first.base_origin.native_origin < second.base_origin.native_origin
        for first, second in zip(session.slots, session.slots[1:])
    )

    approval = session.approve_manual_origin(1, 0)
    assert session.validate_manual_approval(
        approval,
        slot_id=1,
        boundary_offset_rows=0,
    )


def test_preview_refuses_density_source_geometry_from_another_startup_count(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(
        tmp_path,
        content_frames=6,
        slot_capacity_hint=6,
    )
    journal = json.loads(json.dumps(fixture.result.journal))
    source_binding = journal["nikon_density_evidence"]["source_binding"]
    other_contract = _preview_binding_contract(7)
    source_binding["native_height"] = other_contract["native_height"]
    source_binding["height"] = other_contract["decoded_height"]
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(
        RollSessionIntegrityError,
        match="density source geometry disagrees",
    ):
        build_roll_preview_session(replace(fixture.result, journal=journal))


@pytest.mark.parametrize(
    "fixture_kwargs",
    (
        {"density_capture_attempt_id": "another-preview-attempt"},
        {"density_scan_identity": "another-valid-density-scan-identity"},
    ),
)
def test_preview_refuses_internally_valid_density_provenance_from_another_capture(
    tmp_path: Path,
    fixture_kwargs: dict[str, str],
) -> None:
    fixture = _preview_fixture(
        tmp_path,
        content_frames=6,
        slot_capacity_hint=6,
        **fixture_kwargs,
    )

    with pytest.raises(RollSessionIntegrityError, match="density provenance disagrees"):
        build_roll_preview_session(fixture.result)


def test_preview_refuses_tampered_density_source_digest(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(
        tmp_path,
        content_frames=6,
        slot_capacity_hint=6,
    )
    journal = json.loads(json.dumps(fixture.result.journal))
    journal["nikon_density_evidence"]["source_binding"]["wire_sha256"] = "0" * 64
    fixture.result.paths.journal.write_text(json.dumps(journal), encoding="utf-8")

    with pytest.raises(
        RollSessionIntegrityError,
        match="density evidence does not replay",
    ):
        build_roll_preview_session(replace(fixture.result, journal=journal))


@pytest.mark.parametrize("slot_capacity_hint", (0, 1, 41))
def test_preview_refuses_startup_table_outside_scanner_derived_range(
    tmp_path: Path,
    slot_capacity_hint: int,
) -> None:
    with pytest.raises(RollSessionIntegrityError, match="2..40"):
        _preview_fixture(tmp_path, slot_capacity_hint=slot_capacity_hint)


def test_reload_thumbnail_recrops_the_saved_full_width_preview_at_exact_offset(
    tmp_path: Path,
) -> None:
    fixture = _preview_fixture(tmp_path)
    session = build_roll_preview_session(fixture.result)
    slot = session.slots[17]

    reloaded = reload_thumbnail(session.preview, slot, -21)

    np.testing.assert_array_equal(
        reloaded,
        fixture.rgb[
            slot.start_boundary_row - 21 : slot.end_boundary_row - 21,
            :,
            :,
        ],
    )
    assert reloaded.shape[1:] == (96, 3)
    assert reloaded.flags.writeable is False


def test_material_change_uses_explicit_rgb4_routes_without_claiming_bw_ir(
    tmp_path: Path,
) -> None:
    color = build_roll_preview_session(_preview_fixture(tmp_path).result)

    bw = color.with_material(ScanMaterial.BLACK_AND_WHITE_NEGATIVE)

    assert color.recipe.capture_route is CaptureRoute.SINGLE_PASS_RGBI4
    assert color.recipe.capture_ir is True
    assert color.recipe.repair_with_ir_after_import is True
    assert bw.recipe.capture_route is CaptureRoute.SANE_RGB4
    assert bw.recipe.dpi == 4_000
    assert bw.recipe.bit_depth == 16
    assert bw.recipe.rgb_samples == 4
    assert bw.recipe.capture_ir is False
    assert bw.recipe.repair_with_ir_after_import is False


def test_selected_slots_are_an_immutable_ordered_operator_choice(
    tmp_path: Path,
) -> None:
    session = build_roll_preview_session(_preview_fixture(tmp_path).result)

    selected = session.with_selected_slots((3, 7, 18))

    assert session.selected_slots == ()
    assert selected.selected_slots == (3, 7, 18)


def test_boundary_offset_reloads_only_that_slot_and_resolves_exact_table_record(
    tmp_path: Path,
) -> None:
    session = build_roll_preview_session(_preview_fixture(tmp_path).result)
    base = session.slots[17]

    adjusted = session.with_boundary_offset(18, -21)

    assert session.slots[17].boundary_offset_rows == 0
    assert adjusted.slots[17].boundary_offset_rows == -21
    assert adjusted.slots[16] is session.slots[16]
    resolved = adjusted.resolve_origin(18, -21)
    assert resolved.lookup_row == base.base_origin.lookup_row - 21
    assert resolved.native_origin == 42 * resolved.lookup_row
    np.testing.assert_array_equal(
        adjusted.slots[17].thumbnail,
        reload_thumbnail(session.preview, base, -21),
    )


def test_session_json_round_trip_revalidates_sources_and_restores_operator_state(
    tmp_path: Path,
) -> None:
    session = (
        build_roll_preview_session(_preview_fixture(tmp_path).result)
        .with_material(ScanMaterial.BLACK_AND_WHITE_NEGATIVE)
        .with_selected_slots((3, 7, 18))
        .with_boundary_offset(18, -21)
    )

    restored = type(session).from_json(session.to_json())

    assert restored.material is ScanMaterial.BLACK_AND_WHITE_NEGATIVE
    assert restored.recipe.capture_route is CaptureRoute.SANE_RGB4
    assert restored.selected_slots == (3, 7, 18)
    assert restored.slots[17].boundary_offset_rows == -21
    assert restored.preview.preview_artifact == session.preview.preview_artifact
    np.testing.assert_array_equal(
        restored.slots[17].thumbnail,
        session.slots[17].thumbnail,
    )


def test_preview_journal_alias_is_rejected_before_decoding(tmp_path: Path) -> None:
    fixture = _preview_fixture(tmp_path)
    original = fixture.result.paths.journal
    durable = original.with_name("durable-journal.json")
    original.rename(durable)
    original.symlink_to(durable.name)
    aliased = replace(
        fixture.result,
        paths=replace(fixture.result.paths, journal=original),
    )

    with np.testing.assert_raises_regex(
        RollSessionIntegrityError,
        "journal.*alias|regular file",
    ):
        build_roll_preview_session(aliased)


def test_blank_tail_remains_selectable_fixed_slots_with_manual_review_warnings(
    tmp_path: Path,
) -> None:
    session = build_roll_preview_session(
        _preview_fixture(tmp_path, content_frames=36).result,
        expected_frame_count=36,
    )

    assert len(session.slots) == 40
    assert session.detection.expected_frame_count_matches is True
    for slot in session.slots[36:]:
        assert slot.manual_review is True
        assert {
            "ambiguous-content-tail-boundary",
            "beyond-advisory-content-end",
        }.intersection(slot.warnings)


def test_manual_origin_approval_is_bound_to_exact_reviewed_thumbnail_and_roll(
    tmp_path: Path,
) -> None:
    session = build_roll_preview_session(
        _preview_fixture(tmp_path, content_frames=36).result,
        expected_frame_count=36,
    )

    fingerprint = session.reviewed_fingerprint()
    approval = session.approve_manual_origin(37, 0)

    assert fingerprint.source_preview_sha256 == session.preview.preview_artifact.sha256
    assert fingerprint.source_table_sha256 == session.preview.table_artifact.sha256
    assert len(fingerprint.frame_visual_hashes) == len(session.slots) == 40
    assert approval.reviewed_fingerprint_sha256 == fingerprint.binding_sha256
    assert approval.slot == 37
    assert approval.boundary_offset_rows == 0
    assert approval.review_reasons
    assert session.validate_manual_approval(
        approval, slot_id=37, boundary_offset_rows=0
    )

    with pytest.raises(ValueError, match="does not require manual review"):
        session.approve_manual_origin(2, 0)


def test_boundary_only_review_with_automatic_origin_can_be_approved(
    tmp_path: Path,
) -> None:
    session = build_roll_preview_session(
        _preview_fixture(tmp_path, content_frames=36).result,
        expected_frame_count=36,
    )
    slot = session.slots[35]
    assert slot.slot_id == 36
    assert slot.manual_review is True
    assert slot.base_origin.automatic is True
    assert slot.base_origin.manual_review is False
    assert "end-broad-clear-region" in slot.warnings

    approval = session.approve_manual_origin(36, 0)

    assert approval.reviewed_lookup_row == slot.base_origin.lookup_row
    assert approval.reviewed_native_origin == slot.base_origin.native_origin
    assert "end-broad-clear-region" in approval.review_reasons
    assert session.validate_manual_approval(
        approval,
        slot_id=36,
        boundary_offset_rows=0,
    )


def test_session_pixel_arrays_cannot_be_made_writeable(tmp_path: Path) -> None:
    session = build_roll_preview_session(_preview_fixture(tmp_path).result)

    with pytest.raises(ValueError):
        session.preview.rgb.setflags(write=True)
    with pytest.raises(ValueError):
        session.slots[0].thumbnail.setflags(write=True)
