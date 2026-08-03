"""Tests for scanstudio_bridge.domain: wire types round-tripping through
protocol.to_wire/from_wire, and recipe validation.

BRIDGE.md (nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md)
is the canonical spec these tests hold domain.py to.
"""

from __future__ import annotations

import dataclasses

import pytest

from scanstudio_bridge.domain import (
    DEBUG_COLOR_NEGATIVE_RECIPE,
    DEBUG_RECIPE_ENV_VAR,
    FIXED_COLOR_NEGATIVE_RECIPE,
    ApprovalReceipt,
    ArtifactEvidence,
    Capabilities,
    CaptureRecipe,
    Channels,
    ClippingTelemetry,
    DeviceStatus,
    ExposureAuthority,
    ExposureVector,
    FocusDetailTelemetry,
    Material,
    OutputSpec,
    SlotOutputSpec,
    ScanReceipt,
    Thumbnail,
    TransportSmearAssessment,
    validate_capture_recipe,
)
from scanstudio_bridge.protocol import BridgeError, ErrorCode, from_wire, to_wire


def test_output_spec_slot_templates_are_backward_compatible_and_round_trip() -> None:
    legacy = from_wire({"destination": "/tmp/scans", "filenameTemplate": "frame-####.tif"}, OutputSpec)
    assert legacy.slot_outputs is None
    output = OutputSpec(
        destination="/tmp/scans", filename_template="frame-####.tif",
        slot_outputs={"1": SlotOutputSpec("/tmp/scans", "CanonA-####.tif"), "2": SlotOutputSpec("/tmp/scans", "CanonB-####.tif")},
    )
    assert from_wire(to_wire(output), OutputSpec) == output


def _make_scan_receipt() -> ScanReceipt:
    return ScanReceipt(
        version=1,
        slot=1,
        spacing_offset=3,
        dpi=4000,
        depth=16,
        device_id="ls5000-usb-0",
        device_model="SUPER COOLSCAN 5000 ED",
        reviewed_fingerprint_sha256="a" * 32,
        fresh_fingerprint_sha256="a" * 32,
        manual_approval=None,
        exposure=ExposureVector(
            focus_position=812,
            exposure_multiplier=1.0,
            red_exposure_us=1200.0,
            green_exposure_us=950.0,
            blue_exposure_us=1400.0,
        ),
        split_alignment=None,
        clipping=ClippingTelemetry(
            fractions=(0.001, 0.0, 0.0),
            clip_level=0.995,
            warning_fraction=0.02,
            warning=False,
        ),
        focus_detail=FocusDetailTelemetry(
            method="laplacian-variance",
            verdict="measured",
            score=184.2,
            texture_span=0.71,
        ),
        transport_smear=TransportSmearAssessment(
            verdict="clean",
            start_row=None,
            suffix_rows=0,
            minimum_matches=0,
            tail_median_rms=None,
            tail_min_corr=None,
            pre_tail_median_rms=None,
            texture_span=None,
            reason="no repeated tail rows detected",
        ),
        artifacts={
            "rgb": ArtifactEvidence(
                sha256="b" * 32,
                byte_length=25165824,
                shape=(2954, 4429, 3),
                dtype="uint16",
            ),
        },
        storage_transform="swapaxes01-scanner-native-to-nikon-render-parity-v2",
        rgb_path="/tmp/scans/frame-0001.tif",
        ir_path=None,
        meter_rgbi_path="/tmp/scans/frame-0001_METER.tif",
    )


def test_to_wire_scan_receipt_uses_camel_case_at_every_nesting_level() -> None:
    wire = to_wire(_make_scan_receipt())
    assert wire["deviceId"] == "ls5000-usb-0"
    assert wire["spacingOffset"] == 3
    assert wire["reviewedFingerprintSha256"] == "a" * 32
    assert wire["exposure"]["redExposureUs"] == 1200.0
    assert wire["exposure"]["focusPosition"] == 812
    assert wire["focusDetail"]["textureSpan"] == 0.71
    assert wire["transportSmear"]["tailMedianRms"] is None
    assert wire["artifacts"]["rgb"]["byteLength"] == 25165824
    assert wire["storageTransform"] == "swapaxes01-scanner-native-to-nikon-render-parity-v2"
    assert wire["rgbPath"] == "/tmp/scans/frame-0001.tif"
    assert wire["irPath"] is None
    assert wire["meterRgbiPath"] == "/tmp/scans/frame-0001_METER.tif"
    assert wire["attemptsRoot"] is None
    assert wire["splitAlignment"] is None
    assert wire["manualApproval"] is None


def test_scan_receipt_round_trips_through_wire() -> None:
    original = dataclasses.replace(
        _make_scan_receipt(), attempts_root="/var/lib/scanstudio/coolscanpy-attempts/roll-abc"
    )
    restored = from_wire(to_wire(original), ScanReceipt)
    assert restored == original


def test_scan_receipt_accepts_an_older_wire_payload_without_attempts_root() -> None:
    wire = to_wire(_make_scan_receipt())
    del wire["attemptsRoot"]

    restored = from_wire(wire, ScanReceipt)

    assert restored.attempts_root is None


def test_scan_receipt_timing_round_trips_through_wire() -> None:
    original = dataclasses.replace(
        _make_scan_receipt(),
        started_at="2026-08-02T20:05:00+00:00",
        capture_duration_ms=1900,
    )
    wire = to_wire(original)
    assert wire["startedAt"] == "2026-08-02T20:05:00+00:00"
    assert wire["captureDurationMs"] == 1900

    restored = from_wire(wire, ScanReceipt)
    assert restored.started_at == original.started_at
    assert restored.capture_duration_ms == original.capture_duration_ms


def test_scan_receipt_accepts_legacy_wire_without_timing() -> None:
    wire = to_wire(_make_scan_receipt())
    del wire["startedAt"]
    del wire["captureDurationMs"]

    restored = from_wire(wire, ScanReceipt)

    assert restored.started_at is None
    assert restored.capture_duration_ms is None


def _make_exposure_authority() -> ExposureAuthority:
    return ExposureAuthority(
        rgb_source="nikon-parity-guarded-v2",
        ir_source="active-controller",
        commanded_channels_raw_10ns={"R": 107262, "G": 276334, "B": 336777, "IR": 311725},
        active_controller_channels_raw_10ns={
            "R": 121500,
            "G": 276334,
            "B": 340200,
            "IR": 311725,
        },
        device_bound_clamped_channels_raw_10ns={"B": 340200},
        device_exposure_bounds_raw_10ns=(50_000, 400_000),
    )


def test_exposure_authority_round_trips_with_documented_camel_case_shape() -> None:
    original = dataclasses.replace(
        _make_scan_receipt(), exposure_authority=_make_exposure_authority()
    )
    wire = to_wire(original)
    block = wire["exposureAuthority"]
    assert block["rgbSource"] == "nikon-parity-guarded-v2"
    assert block["commandedChannelsRaw10ns"]["IR"] == 311725
    assert block["deviceBoundClampedChannelsRaw10ns"] == {"B": 340200}
    assert block["deviceExposureBoundsRaw10ns"] == [50_000, 400_000]
    assert from_wire(wire, ScanReceipt) == original


def test_scan_receipt_accepts_legacy_wire_without_exposure_authority() -> None:
    wire = to_wire(_make_scan_receipt())
    del wire["exposureAuthority"]
    assert from_wire(wire, ScanReceipt).exposure_authority is None


def test_manual_approval_round_trips_when_present() -> None:
    approval = ApprovalReceipt(
        reviewed_fingerprint_sha256="c" * 32,
        slot=5,
        spacing_offset=2,
        thumbnail_sha256="d" * 32,
        reviewed_lookup_row=100,
        reviewed_native_origin=98,
        review_reasons=("low-confidence auto-origin",),
    )
    receipt = dataclasses.replace(_make_scan_receipt(), manual_approval=approval)
    restored = from_wire(to_wire(receipt), ScanReceipt)
    assert restored == receipt
    assert restored.manual_approval == approval


def test_capture_recipe_round_trips_through_wire() -> None:
    restored = from_wire(to_wire(FIXED_COLOR_NEGATIVE_RECIPE), CaptureRecipe)
    assert restored == FIXED_COLOR_NEGATIVE_RECIPE


def test_thumbnail_round_trips_through_wire() -> None:
    original = Thumbnail(
        slot=1,
        boundary_rows=(12, 884),
        spacing_offset=3,
        needs_approval=False,
        warnings=("low contrast",),
        image_path="/tmp/previews/session-abc/slot-0001.tif",
    )
    wire = to_wire(original)
    assert wire["imagePath"] == "/tmp/previews/session-abc/slot-0001.tif"
    restored = from_wire(wire, Thumbnail)
    assert restored == original


def test_capabilities_round_trips_through_wire() -> None:
    original = Capabilities(
        ir_channel=True,
        supported_dpi=(4000,),
        supported_depths=(16,),
        multi_sample=False,
        adapter_frame_capacity=None,
        adapter_frame_control=True,
        auto_exposure=True,
        registered_geometry=True,
        can_eject=True,
        supported_multisample_passes=(4,),
    )
    wire = to_wire(original)
    assert wire["supportedMultisamplePasses"] == [4]
    restored = from_wire(wire, Capabilities)
    assert restored == original


def test_device_status_round_trips_through_wire() -> None:
    original = DeviceStatus(
        connected=True,
        device_id="ls5000-usb-0",
        preview_established=True,
        slot_count=36,
        active_job_id=None,
        lane_held=False,
        motion_armed=True,
        film_present=None,
    )
    wire = to_wire(original)
    assert wire["filmPresent"] is None
    restored = from_wire(wire, DeviceStatus)
    assert restored == original


def test_material_and_channels_wire_values() -> None:
    assert Material.COLOR_NEGATIVE == "colorNegative"
    assert Material.BLACK_AND_WHITE_NEGATIVE == "blackAndWhiteNegative"
    assert Channels.RGB == "rgb"
    assert Channels.RGBI == "rgbi"


def test_fixed_color_negative_recipe_matches_bridge_md_recipe_constraints() -> None:
    assert FIXED_COLOR_NEGATIVE_RECIPE == CaptureRecipe(
        resolution_dpi=4000,
        bit_depth=16,
        multisample_passes=4,
        channels=Channels.RGBI,
        autofocus=True,
        auto_exposure=True,
    )


def test_validate_capture_recipe_accepts_the_fixed_recipe() -> None:
    assert (
        validate_capture_recipe(FIXED_COLOR_NEGATIVE_RECIPE, Material.COLOR_NEGATIVE)
        is None
    )


def test_validate_capture_recipe_rejects_wrong_multisample_passes() -> None:
    bad_recipe = dataclasses.replace(FIXED_COLOR_NEGATIVE_RECIPE, multisample_passes=1)
    with pytest.raises(BridgeError) as excinfo:
        validate_capture_recipe(bad_recipe, Material.COLOR_NEGATIVE)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "multisamplePasses" in excinfo.value.message


def test_validate_capture_recipe_rejects_black_and_white_as_not_implemented() -> None:
    with pytest.raises(BridgeError) as excinfo:
        validate_capture_recipe(
            FIXED_COLOR_NEGATIVE_RECIPE, Material.BLACK_AND_WHITE_NEGATIVE
        )
    assert excinfo.value.code == ErrorCode.NOT_IMPLEMENTED


# -- debug recipe gate (Plan 10-09, lab-only) ---------------------------------------


def test_debug_color_negative_recipe_matches_the_documented_diagnostic_shape() -> None:
    assert DEBUG_COLOR_NEGATIVE_RECIPE.resolution_dpi == 1000
    assert DEBUG_COLOR_NEGATIVE_RECIPE.bit_depth == 8
    assert DEBUG_COLOR_NEGATIVE_RECIPE.multisample_passes == 1
    assert DEBUG_COLOR_NEGATIVE_RECIPE.channels == Channels.RGB


def test_validate_capture_recipe_rejects_debug_recipe_when_env_unset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Default behavior (env unset) must be byte-identical to before this
    override existed: the debug recipe is still rejected exactly like any
    other non-matching recipe, naming resolutionDpi as the first
    mismatched field (the same message shape the pre-existing
    test_validate_capture_recipe_rejects_wrong_multisample_passes above
    pins for a different mismatch)."""
    monkeypatch.delenv(DEBUG_RECIPE_ENV_VAR, raising=False)
    with pytest.raises(BridgeError) as excinfo:
        validate_capture_recipe(DEBUG_COLOR_NEGATIVE_RECIPE, Material.COLOR_NEGATIVE)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "resolutionDpi" in excinfo.value.message


def test_validate_capture_recipe_rejects_debug_recipe_when_env_is_not_exactly_one(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "true")
    with pytest.raises(BridgeError):
        validate_capture_recipe(DEBUG_COLOR_NEGATIVE_RECIPE, Material.COLOR_NEGATIVE)
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "0")
    with pytest.raises(BridgeError):
        validate_capture_recipe(DEBUG_COLOR_NEGATIVE_RECIPE, Material.COLOR_NEGATIVE)


def test_validate_capture_recipe_accepts_debug_recipe_when_env_armed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "1")
    assert (
        validate_capture_recipe(DEBUG_COLOR_NEGATIVE_RECIPE, Material.COLOR_NEGATIVE)
        is None
    )


def test_validate_capture_recipe_still_accepts_fixed_recipe_when_debug_env_armed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Additive, not a replacement: the primary fixed recipe is accepted
    whether or not the debug env var is set."""
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "1")
    assert (
        validate_capture_recipe(FIXED_COLOR_NEGATIVE_RECIPE, Material.COLOR_NEGATIVE)
        is None
    )


def test_validate_capture_recipe_debug_recipe_ignores_autofocus_and_auto_exposure_when_armed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """autofocus/autoExposure are explicitly unconstrained under the debug
    override -- any bool combination for either must be accepted."""
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "1")
    for autofocus in (True, False):
        for auto_exposure in (True, False):
            recipe = dataclasses.replace(
                DEBUG_COLOR_NEGATIVE_RECIPE,
                autofocus=autofocus,
                auto_exposure=auto_exposure,
            )
            assert validate_capture_recipe(recipe, Material.COLOR_NEGATIVE) is None, (
                autofocus,
                auto_exposure,
            )


def test_validate_capture_recipe_rejects_a_recipe_matching_neither_shape_even_when_armed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "1")
    neither = dataclasses.replace(DEBUG_COLOR_NEGATIVE_RECIPE, resolution_dpi=2400)
    with pytest.raises(BridgeError) as excinfo:
        validate_capture_recipe(neither, Material.COLOR_NEGATIVE)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


def test_validate_capture_recipe_debug_env_does_not_relax_black_and_white(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "1")
    with pytest.raises(BridgeError) as excinfo:
        validate_capture_recipe(
            DEBUG_COLOR_NEGATIVE_RECIPE, Material.BLACK_AND_WHITE_NEGATIVE
        )
    assert excinfo.value.code == ErrorCode.NOT_IMPLEMENTED


def test_validate_capture_recipe_rejects_wrong_multisample_passes_still_works_when_armed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Regression: arming the debug env must never weaken the FIXED
    recipe's own validation for a recipe that matches neither shape --
    this is byte-for-byte the same pre-existing rejection test above, run
    a second time with the debug gate armed."""
    monkeypatch.setenv(DEBUG_RECIPE_ENV_VAR, "1")
    bad_recipe = dataclasses.replace(FIXED_COLOR_NEGATIVE_RECIPE, multisample_passes=1)
    with pytest.raises(BridgeError) as excinfo:
        validate_capture_recipe(bad_recipe, Material.COLOR_NEGATIVE)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "multisamplePasses" in excinfo.value.message
