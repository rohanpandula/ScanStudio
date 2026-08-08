"""Tests for scanstudio_bridge.transport.mock: MockTransport, a
deterministic, hardware-free Transport implementation with scripted
retry/fault injection. See BRIDGE.md (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md) for the wire-level contract this
transport mirrors; CoolscanPyTransport (transport/coolscanpy_transport.py,
Task 3) satisfies the identical contract against real hardware.
"""

from __future__ import annotations

import dataclasses
import threading
from pathlib import Path

import numpy as np
import pytest
import tifffile

from scanstudio_bridge import domain, safety
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport import FrameRetryExhausted
from scanstudio_bridge.transport import mock as mock_transport_module
from scanstudio_bridge.transport.mock import MockTransport
from scanstudio_bridge.transport.output_reservation import (
    OutputReservations,
    output_group_for_slot,
)

_DEVICE_ID = "mock-ls5000-0"


def _opened(**kwargs: object) -> MockTransport:
    transport = MockTransport(**kwargs)
    transport.open_device(_DEVICE_ID)
    return transport


def _output(destination: Path, filename_template: str = "frame-####.tif") -> domain.OutputSpec:
    return domain.OutputSpec(destination=str(destination), filename_template=filename_template)


# -- list_devices ---------------------------------------------------------------


def test_list_devices_returns_exactly_one_device() -> None:
    devices = MockTransport().list_devices()
    assert len(devices) == 1
    assert devices[0].device_id == _DEVICE_ID


def test_slot_templates_reserve_distinct_paths_and_reject_bad_maps(tmp_path: Path) -> None:
    transport = _opened(enforce_fixed_recipe=False)
    other_destination = tmp_path / "other"
    output = domain.OutputSpec(
        destination=str(tmp_path), filename_template="fallback-####.tif",
        slot_outputs={"1": domain.SlotOutputSpec(str(tmp_path), "CanonA-####.tif"), "2": domain.SlotOutputSpec(str(other_destination), "CanonB-####.tif")},
    )
    frames: list[domain.ScanReceipt] = []
    transport.start_scan([1, 2], domain.CaptureRecipe(4000, 16, 4, domain.Channels.RGBI, True, True), output, lambda _: None, lambda *_: None, lambda _, receipt: frames.append(receipt))
    assert frames[0].rgb_path.endswith("CanonA-0001.tif")
    assert frames[1].rgb_path.endswith("CanonB-0002.tif")
    assert Path(frames[1].rgb_path).parent == other_destination
    bad = dataclasses.replace(output, slot_outputs={"1": domain.SlotOutputSpec(str(tmp_path), "only-####.tif")})
    with pytest.raises(BridgeError) as exc:
        transport.start_scan([1, 2], domain.CaptureRecipe(4000, 16, 4, domain.Channels.RGBI, True, True), bad, lambda _: None, lambda *_: None, lambda *_: None)
    assert exc.value.code is ErrorCode.INVALID_PARAMS


def test_archive_name_resolution_matches_hash_runs_extensions_and_dotted_metadata(
    tmp_path: Path,
) -> None:
    recipe = domain.CaptureRecipe(
        4000, 16, 4, domain.Channels.RGBI, True, True
    )
    cases = [
        ("frame-####", 7, "frame-0007.tif"),
        ("frame-#.tiff", 7, "frame-7.tiff"),
        ("ScanStudio$ScanStudioSequence(3).tif", 39, "ScanStudio3.tif"),
        ("frame.TiF", 7, "frame_7.TiF"),
        ("Kodak-EF50mmF1.8STM", 7, "Kodak-EF50mmF1.8STM_7.tif"),
    ]
    for template, slot, expected in cases:
        group = output_group_for_slot(_output(tmp_path, template), recipe, slot)
        assert group.rgb_path.name == expected


def test_reservation_rejects_cross_slot_casefolded_and_sidecar_aliases_before_write(
    tmp_path: Path,
) -> None:
    recipe = domain.CaptureRecipe(
        4000, 16, 4, domain.Channels.RGBI, True, True
    )
    cross_slot = domain.OutputSpec(
        destination=str(tmp_path),
        filename_template="fallback-####.tif",
        slot_outputs={
            "1": domain.SlotOutputSpec(str(tmp_path), "x_#_2"),
            "2": domain.SlotOutputSpec(str(tmp_path), "x_1_#"),
        },
    )
    with pytest.raises(BridgeError) as exc:
        OutputReservations.reserve([1, 2], recipe, cross_slot)
    assert exc.value.code is ErrorCode.INVALID_PARAMS
    assert not (tmp_path / "x_1_2.tif").exists()

    case_only = dataclasses.replace(
        cross_slot,
        slot_outputs={
            "1": domain.SlotOutputSpec(str(tmp_path), "Output_#_2"),
            "2": domain.SlotOutputSpec(str(tmp_path), "output_1_#"),
        },
    )
    with pytest.raises(BridgeError) as exc:
        OutputReservations.reserve([1, 2], recipe, case_only)
    assert exc.value.code is ErrorCode.INVALID_PARAMS

    sidecar_alias = dataclasses.replace(
        cross_slot,
        slot_outputs={
            "1": domain.SlotOutputSpec(str(tmp_path), "frame_#_2"),
            "2": domain.SlotOutputSpec(str(tmp_path), "frame_1_#_IR"),
        },
    )
    with pytest.raises(BridgeError) as exc:
        OutputReservations.reserve([1, 2], recipe, sidecar_alias)
    assert exc.value.code is ErrorCode.INVALID_PARAMS


def test_reservation_rejects_existing_symlink_leaf_without_touching_target(
    tmp_path: Path,
) -> None:
    victim = tmp_path / "victim.bin"
    victim.write_bytes(b"do-not-touch")
    leaf = tmp_path / "frame-0001.tif"
    leaf.symlink_to(victim)
    with pytest.raises(BridgeError) as exc:
        OutputReservations.reserve(
            [1],
            domain.CaptureRecipe(
                4000, 16, 4, domain.Channels.RGBI, True, True
            ),
            _output(tmp_path),
        )
    assert exc.value.code is ErrorCode.INVALID_PARAMS
    assert victim.read_bytes() == b"do-not-touch"
    assert leaf.is_symlink()


# -- capabilities / film presence --------------------------------------------------


def test_device_info_reports_fixed_supported_multisample_passes() -> None:
    assert MockTransport()._device_info().capabilities.supported_multisample_passes == (4,)


def test_status_film_present_defaults_to_true() -> None:
    transport = _opened()
    assert transport.status().film_present is True


def test_status_film_present_none_when_configured() -> None:
    transport = _opened(film_present=None)
    assert transport.status().film_present is None


# -- preview ----------------------------------------------------------------------


def test_preview_calls_on_thumbnail_slot_count_times_in_order_only_last_needs_approval() -> None:
    transport = _opened(slot_count=4)
    thumbnails: list[domain.Thumbnail] = []
    result = transport.preview(domain.Material.COLOR_NEGATIVE, None, thumbnails.append)

    assert [t.slot for t in thumbnails] == [1, 2, 3, 4]
    assert [t.needs_approval for t in thumbnails] == [False, False, False, True]
    assert thumbnails[-1].warnings == ("ambiguous-content-tail-boundary",)
    assert result.count == 4


def test_preview_writes_image_path_tiles_into_preview_dir(tmp_path: Path) -> None:
    transport = _opened(slot_count=4, preview_dir=tmp_path)
    thumbnails: list[domain.Thumbnail] = []
    transport.preview(domain.Material.COLOR_NEGATIVE, None, thumbnails.append)

    assert len(thumbnails) == 4
    for thumbnail in thumbnails:
        tile_path = Path(thumbnail.image_path)
        assert tile_path.exists()
        assert tile_path.parent == tmp_path


def test_set_spacing_offset_returns_fresh_thumbnail_at_unique_path(
    tmp_path: Path,
) -> None:
    transport = _opened(slot_count=4, preview_dir=tmp_path)
    initial: list[domain.Thumbnail] = []
    transport.preview(domain.Material.COLOR_NEGATIVE, None, initial.append)

    adjusted = transport.set_spacing_offset(4, -5)
    adjusted_again = transport.set_spacing_offset(4, 2)

    assert adjusted.slot == 4
    assert adjusted.boundary_rows == (3600, 4800)
    assert adjusted.spacing_offset == -5
    assert adjusted.needs_approval is True
    assert adjusted.warnings == ("ambiguous-content-tail-boundary",)
    paths = {
        initial[-1].image_path,
        adjusted.image_path,
        adjusted_again.image_path,
    }
    assert len(paths) == 3
    assert all(Path(path).is_file() for path in paths)
    assert (
        tifffile.imread(initial[-1].image_path).tobytes()
        != tifffile.imread(adjusted.image_path).tobytes()
    )


def test_set_spacing_offset_without_mock_device_is_not_connected() -> None:
    transport = MockTransport()

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 0)

    assert excinfo.value.code is ErrorCode.NOT_CONNECTED


def test_set_spacing_offset_without_mock_preview_is_no_preview() -> None:
    transport = _opened(slot_count=1)

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 0)

    assert excinfo.value.code is ErrorCode.NO_PREVIEW


def test_adjusted_mock_tile_is_landscape_and_moves_content_left_without_flip(
    tmp_path: Path,
) -> None:
    transport = _opened(slot_count=2, preview_dir=tmp_path)
    initial: list[domain.Thumbnail] = []
    transport.preview(domain.Material.COLOR_NEGATIVE, None, initial.append)

    adjusted = transport.set_spacing_offset(2, 1)
    initial_pixels = tifffile.imread(initial[1].image_path)
    adjusted_pixels = tifffile.imread(adjusted.image_path)

    assert initial_pixels.shape == adjusted_pixels.shape == (48, 64, 3)
    assert np.array_equal(adjusted_pixels[:, :-1], initial_pixels[:, 1:])
    assert np.array_equal(adjusted_pixels[0, :-1], initial_pixels[0, 1:])
    assert np.array_equal(adjusted_pixels[-1, :-1], initial_pixels[-1, 1:])


def test_set_spacing_offset_rejects_while_mock_scan_is_active(
    tmp_path: Path,
) -> None:
    preview_dir = tmp_path / "preview"
    preview_dir.mkdir()
    transport = _opened(slot_count=1, preview_dir=preview_dir)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    scan_entered = threading.Event()
    release_scan = threading.Event()
    scan_errors: list[BaseException] = []

    def run_scan() -> None:
        try:
            transport.start_scan(
                slots=[1],
                recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
                output=_output(tmp_path / "output"),
                on_progress=lambda _p: (
                    scan_entered.set(),
                    release_scan.wait(timeout=2),
                ),
                on_retry=lambda *_a: None,
                on_frame=lambda *_a: None,
            )
        except BaseException as exc:
            scan_errors.append(exc)

    worker = threading.Thread(target=run_scan)
    worker.start()
    assert scan_entered.wait(timeout=2)
    try:
        with pytest.raises(BridgeError) as excinfo:
            transport.set_spacing_offset(1, 1)
        assert excinfo.value.code is ErrorCode.HARDWARE_LANE_BUSY
    finally:
        release_scan.set()
        worker.join(timeout=2)

    assert not worker.is_alive()
    assert scan_errors == []


def test_set_spacing_offset_tile_write_failure_invalidates_mock_preview(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    preview_dir = tmp_path / "preview"
    preview_dir.mkdir()
    transport = _opened(slot_count=1, preview_dir=preview_dir)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    actual_imwrite = mock_transport_module.tifffile.imwrite

    def fail_adjusted_tile_write(*_args: object, **_kwargs: object) -> None:
        raise OSError("mock preview volume became read-only")

    monkeypatch.setattr(
        mock_transport_module.tifffile,
        "imwrite",
        fail_adjusted_tile_write,
    )

    with pytest.raises(BridgeError) as excinfo:
        transport.set_spacing_offset(1, 1)

    assert excinfo.value.code is ErrorCode.INTERNAL
    assert "alignment was applied" in str(excinfo.value)
    assert transport.status().preview_established is False

    monkeypatch.setattr(mock_transport_module.tifffile, "imwrite", actual_imwrite)
    with pytest.raises(BridgeError) as scan_excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path / "output"),
            on_progress=lambda _p: None,
            on_retry=lambda *_a: None,
            on_frame=lambda *_a: None,
        )
    assert scan_excinfo.value.code is ErrorCode.NO_PREVIEW


def test_set_spacing_offset_is_preserved_in_mock_scan_receipt(
    tmp_path: Path,
) -> None:
    transport = _opened(slot_count=4, preview_dir=tmp_path)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    transport.set_spacing_offset(2, 6)
    receipts: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[2],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path / "output"),
        on_progress=lambda _p: None,
        on_retry=lambda *_a: None,
        on_frame=lambda _slot, receipt: receipts.append(receipt),
    )

    assert receipts[0].spacing_offset == 6


# -- start_scan: fault_script / permanent_fault_slots -----------------------------


def test_start_scan_with_fault_script_retries_once_then_succeeds(tmp_path: Path) -> None:
    transport = _opened(slot_count=6, fault_script={2: 1})
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    retries: list[tuple[int, int, str]] = []
    frames: list[tuple[int, domain.ScanReceipt]] = []

    summary = transport.start_scan(
        slots=[2],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda slot, attempt, reason: retries.append((slot, attempt, reason)),
        on_frame=lambda slot, receipt: frames.append((slot, receipt)),
    )

    assert len(retries) == 1
    assert retries[0][0] == 2
    assert retries[0][1] == 1
    assert isinstance(retries[0][2], str) and retries[0][2]
    assert len(frames) == 1
    assert frames[0][0] == 2
    assert summary.completed == (2,)
    assert summary.failed == ()
    assert summary.stopped is False


def test_start_scan_with_two_leading_failures_then_succeeds_on_third_attempt(
    tmp_path: Path,
) -> None:
    """Direct MockTransport counterpart to the analogous CoolscanPyTransport
    test (tests/test_transport_coolscanpy.py) -- proves the exact "fails
    twice, succeeds on the third attempt" scenario identically through
    either transport (see this plan's must_haves.truths)."""
    transport = _opened(slot_count=6, fault_script={2: 2})
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    retries: list[tuple[int, int]] = []
    frames: list[tuple[int, domain.ScanReceipt]] = []

    summary = transport.start_scan(
        slots=[2],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda slot, attempt, reason: retries.append((slot, attempt)),
        on_frame=lambda slot, receipt: frames.append((slot, receipt)),
    )

    assert retries == [(2, 1), (2, 2)]
    assert len(frames) == 1
    assert summary.completed == (2,)
    assert summary.stopped is False


def test_start_scan_with_permanent_fault_raises_frame_retry_exhausted_after_three_attempts(
    tmp_path: Path,
) -> None:
    transport = _opened(slot_count=6, permanent_fault_slots={5})
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    retries: list[tuple[int, int, str]] = []

    with pytest.raises(FrameRetryExhausted) as excinfo:
        transport.start_scan(
            slots=[5],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda slot, attempt, reason: retries.append((slot, attempt, reason)),
            on_frame=lambda slot, receipt: None,
        )

    assert excinfo.value.slot == 5
    assert len(retries) == safety.MAX_FRAME_RETRIES
    assert list(tmp_path.iterdir()) == []


def test_start_scan_write_failure_keeps_rgb_and_releases_unwritten_sidecars(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = _opened(slot_count=1)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    actual_write_tiff = mock_transport_module.write_tiff

    def fail_ir_write(reservations, path, data, **kwargs):
        if path.name.endswith("_IR.tif"):
            raise RuntimeError("injected mock IR writer failure")
        return actual_write_tiff(reservations, path, data, **kwargs)

    monkeypatch.setattr(mock_transport_module, "write_tiff", fail_ir_write)

    with pytest.raises(RuntimeError, match="injected mock IR writer failure"):
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
        )

    rgb_path = tmp_path / "frame-0001.tif"
    assert tifffile.imread(rgb_path).shape == (64, 64, 3)
    assert not (tmp_path / "frame-0001_IR.tif").exists()
    assert not (tmp_path / "frame-0001_METER.tif").exists()


# -- start_scan: recipe / path-traversal rejection --------------------------------


def test_start_scan_rejects_wrong_recipe_before_any_slot_attempted(tmp_path: Path) -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    bad_recipe = dataclasses.replace(domain.FIXED_COLOR_NEGATIVE_RECIPE, resolution_dpi=2400)
    frames_called: list[object] = []

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=bad_recipe,
            output=_output(tmp_path),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: frames_called.append(a),
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert frames_called == []
    assert list(tmp_path.iterdir()) == []


def test_start_scan_rejects_path_traversal_before_any_file_written(tmp_path: Path) -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    destination = tmp_path / "out"

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(destination, "../escape-####.tif"),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert not (tmp_path / "escape-0001.tif").exists()


def test_start_scan_rejects_absolute_path_override_in_template(tmp_path: Path) -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    destination = tmp_path / "out"
    escape_target = tmp_path / "escape-abs-0001.tif"

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(destination, str(tmp_path / "escape-abs-####.tif")),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *a: None,
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert not escape_target.exists()


@pytest.mark.parametrize("sidecar_suffix", ["", "_IR", "_METER"])
def test_start_scan_refuses_existing_output_group_before_mock_scan(
    tmp_path: Path, sidecar_suffix: str
) -> None:
    transport = _opened(slot_count=1)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    output_root = tmp_path / "out"
    target = output_root / f"frame-0001{sidecar_suffix}.tif"
    target.parent.mkdir()
    original = b"do-not-replace-existing-artifact"
    target.write_bytes(original)
    calls: list[tuple] = []

    with pytest.raises(BridgeError) as excinfo:
        transport.start_scan(
            slots=[1],
            recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
            output=_output(output_root),
            on_progress=lambda _p: None,
            on_retry=lambda *a: None,
            on_frame=lambda *_a: None,
            on_call=lambda *args: calls.append(args),
        )

    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert target.read_bytes() == original
    assert calls == []
    assert list(output_root.iterdir()) == [target]


# -- start_scan: successful write path, IR sidecar --------------------------------


def test_start_scan_writes_rgb_and_ir_sidecar_for_rgbi_recipe(tmp_path: Path) -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    rgb_path = tmp_path / "frame-0001.tif"
    ir_path = tmp_path / "frame-0001_IR.tif"
    assert rgb_path.exists()
    assert ir_path.exists()
    assert frames[0].rgb_path == str(rgb_path)
    assert frames[0].ir_path == str(ir_path)
    assert frames[0].transport_smear.verdict == "clean"
    assert frames[0].clipping.warning is False
    assert frames[0].focus_detail.verdict == "measured"
    assert frames[0].split_alignment is None
    assert frames[0].attempts_root is None
    assert tifffile.imread(rgb_path).shape == (64, 64, 3)


def test_start_scan_writes_meter_rgbi_sidecar_for_rgbi_recipe(tmp_path: Path) -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    frames: list[domain.ScanReceipt] = []

    transport.start_scan(
        slots=[1],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=lambda _slot, receipt: frames.append(receipt),
    )

    meter_path = tmp_path / "frame-0001_METER.tif"
    assert frames[0].meter_rgbi_path == str(meter_path)
    assert meter_path.exists()
    assert tifffile.imread(meter_path).shape == (64, 64, 4)


# -- request_stop -----------------------------------------------------------------


def test_request_stop_finishes_in_flight_slot_then_skips_remaining(tmp_path: Path) -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    def on_frame(slot: int, _receipt: domain.ScanReceipt) -> None:
        if slot == 1:
            transport.request_stop()

    summary = transport.start_scan(
        slots=[1, 2, 3],
        recipe=domain.FIXED_COLOR_NEGATIVE_RECIPE,
        output=_output(tmp_path),
        on_progress=lambda _p: None,
        on_retry=lambda *a: None,
        on_frame=on_frame,
    )

    assert summary.completed == (1,)
    assert summary.failed == ()
    assert summary.stopped is True


# -- device lifecycle / approve / eject --------------------------------------------


def test_open_device_rejects_second_open_with_already_connected() -> None:
    transport = _opened()
    with pytest.raises(BridgeError) as excinfo:
        transport.open_device(_DEVICE_ID)
    assert excinfo.value.code == ErrorCode.ALREADY_CONNECTED


def test_open_device_rejects_unknown_device_id() -> None:
    transport = MockTransport()
    with pytest.raises(BridgeError) as excinfo:
        transport.open_device("not-a-real-device")
    assert excinfo.value.code == ErrorCode.DEVICE_NOT_FOUND


def test_status_raises_not_connected_before_open() -> None:
    transport = MockTransport()
    with pytest.raises(BridgeError) as excinfo:
        transport.status()
    assert excinfo.value.code == ErrorCode.NOT_CONNECTED


def test_status_reflects_preview_established_and_slot_count() -> None:
    transport = _opened(slot_count=6)
    assert transport.status().preview_established is False
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    status = transport.status()
    assert status.preview_established is True
    assert status.slot_count == 6
    assert status.connected is True
    assert status.device_id == _DEVICE_ID


def test_approve_rejects_out_of_range_slot() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    with pytest.raises(BridgeError) as excinfo:
        transport.approve(99)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


def test_approve_rejects_slot_that_does_not_need_approval() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    with pytest.raises(BridgeError) as excinfo:
        transport.approve(1)  # slot 1 is not the last slot
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


def test_approve_accepts_the_last_slot_which_needs_approval() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    transport.approve(4)  # must not raise


def test_close_device_then_reopen_resets_preview_state() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    transport.close_device()
    with pytest.raises(BridgeError):
        transport.status()
    transport.open_device(_DEVICE_ID)
    assert transport.status().preview_established is False


def test_eject_always_returns_true() -> None:
    assert MockTransport().eject() is True


# -- manual frame placement (Rung 4) -----------------------------------------------


def test_manual_frames_without_any_preview_is_no_preview() -> None:
    transport = _opened(slot_count=4)
    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([100, 300])
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def test_manual_frames_rejects_fewer_than_two_rows() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([100])
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "at least 2 boundary rows" in str(excinfo.value)


def test_manual_frames_rejects_non_increasing_rows() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)
    with pytest.raises(BridgeError) as excinfo:
        transport.manual_frames([300, 100, 500])
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "strictly increasing" in str(excinfo.value)


def test_manual_frames_happy_path_replaces_slot_lattice_and_rearms_approve() -> None:
    transport = _opened(slot_count=6)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    # None of these rows is a multiple of 100 -- the mock's deterministic
    # "snap" trigger (see test_manual_frames_reports_deterministic_snap_notes
    # below) never fires, so this is the plain no-snap happy path.
    result, thumbnails, snaps, material = transport.manual_frames([101, 301, 501])

    assert material is domain.Material.COLOR_NEGATIVE
    assert result.count == 2
    assert [t.slot for t in thumbnails] == [1, 2]
    assert thumbnails[0].boundary_rows == (101, 301)
    assert thumbnails[1].boundary_rows == (301, 501)
    assert all(t.needs_approval for t in thumbnails)
    assert all("user-picked" in t.warnings for t in thumbnails)
    assert snaps == ()

    # The manual placement replaces the roll's own slot lattice: status now
    # reports the manual frame count, and approve()/set_spacing_offset() work
    # unchanged against the new 1-based slot numbering.
    assert transport.status().slot_count == 2
    transport.approve(1)
    transport.approve(2)
    adjusted = transport.set_spacing_offset(1, 0)
    assert adjusted.slot == 1


def test_manual_frames_reports_deterministic_snap_notes() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    _result, _thumbnails, snaps, _material = transport.manual_frames([100, 250])

    assert snaps == (
        domain.BoundarySnap(
            boundary_index=0,
            requested_row=100,
            snapped_row=99,
            evidence_run=(96, 104),
        ),
    )


def test_preview_strip_without_any_preview_is_no_preview() -> None:
    transport = _opened(slot_count=4)
    with pytest.raises(BridgeError) as excinfo:
        transport.preview_strip()
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def test_preview_strip_happy_path_returns_row_count_and_image() -> None:
    transport = _opened(slot_count=4)
    transport.preview(domain.Material.COLOR_NEGATIVE, None, lambda _t: None)

    strip = transport.preview_strip()

    assert strip.row_count == min(4 * 1200, 4_096)  # honest cap: width == rows
    import tifffile as _tifffile

    written = _tifffile.imread(strip.image_path)
    assert written.shape[1] == strip.row_count  # width axis == reported rows
    assert strip.pixels_per_row == 1
    assert Path(strip.image_path).is_file()
