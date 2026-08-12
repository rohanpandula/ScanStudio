"""Tests for scanstudio_bridge.service: BridgeService's method dispatch, the
hello-first gate, and SAFE-02 gate wiring. Every test uses a small
hand-written stub Transport (not MockTransport, which is exercised
end-to-end in test_end_to_end.py) so this suite tests BridgeService's own
dispatch logic in isolation. Every test passes tmp_path as base_dir -- none
of these tests are permitted to touch the real ~/.scanstudio (see BRIDGE.md,
nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md).
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from scanstudio_bridge import domain, safety, service
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport import FrameRetryExhausted

_DEVICE_ID = "stub-ls5000-0"


def _device_info() -> domain.DeviceInfo:
    return domain.DeviceInfo(
        device_id=_DEVICE_ID,
        vendor="Nikon",
        model="SUPER COOLSCAN 5000 ED (stub)",
        capabilities=domain.Capabilities(
            ir_channel=True,
            supported_dpi=(4000,),
            supported_depths=(16,),
            multi_sample=True,
            adapter_frame_capacity=40,
            adapter_frame_control=True,
            auto_exposure=True,
            registered_geometry=True,
            can_eject=True,
            supported_multisample_passes=(4,),
        ),
    )


def _thumbnail(slot: int) -> domain.Thumbnail:
    return domain.Thumbnail(
        slot=slot,
        boundary_rows=(0, 100),
        spacing_offset=0,
        needs_approval=False,
        warnings=(),
        image_path=f"/tmp/stub-preview/slot-{slot:04d}.tif",
    )


def test_thumbnail_wire_is_byte_absent_for_full_frames() -> None:
    # Lane C (D2), guardrail: the partial key must be ABSENT -- not null -- on
    # a full-cover frame's wire thumbnail, so the additive field never changes
    # existing wire bytes.
    wire = service._thumbnail_to_wire(_thumbnail(1))
    assert "partial" not in wire, wire


def test_thumbnail_wire_carries_partial_true_only_when_partial() -> None:
    # Lane C (D2): a partial frame emits exactly ``partial: true`` -- and only
    # that one additive key; nothing else about the payload changes.
    full = service._thumbnail_to_wire(_thumbnail(1))
    partial = service._thumbnail_to_wire(
        domain.Thumbnail(
            slot=1,
            boundary_rows=(0, 100),
            spacing_offset=0,
            needs_approval=False,
            warnings=(),
            image_path="/tmp/stub-preview/slot-0001.tif",
            partial=True,
        )
    )
    assert partial["partial"] is True
    # The only difference vs the full-frame payload is the added key.
    expected = dict(full)
    expected["partial"] = True
    assert partial == expected
    assert "\"partial\": null" not in str(full)

def _stub_receipt(slot: int) -> domain.ScanReceipt:
    """Minimal valid receipt for a transport double's on_frame callback."""
    return domain.ScanReceipt(
        version=1,
        slot=slot,
        spacing_offset=0,
        dpi=4000,
        depth=16,
        device_id=_DEVICE_ID,
        device_model="SUPER COOLSCAN 5000 ED (stub)",
        reviewed_fingerprint_sha256="0" * 64,
        fresh_fingerprint_sha256="0" * 64,
        manual_approval=None,
        exposure=domain.ExposureVector(
            focus_position=0,
            exposure_multiplier=1.0,
            red_exposure_us=0.0,
            green_exposure_us=0.0,
            blue_exposure_us=0.0,
        ),
        split_alignment=None,
        clipping=domain.ClippingTelemetry(
            fractions=(0.0, 0.0, 0.0),
            clip_level=0.995,
            warning_fraction=0.02,
            warning=False,
        ),
        focus_detail=domain.FocusDetailTelemetry(
            method="laplacian-variance",
            verdict="measured",
            score=0.0,
            texture_span=0.0,
        ),
        transport_smear=domain.TransportSmearAssessment(
            verdict="clean",
            start_row=None,
            suffix_rows=0,
            minimum_matches=0,
            tail_median_rms=None,
            tail_min_corr=None,
            pre_tail_median_rms=None,
            texture_span=None,
            reason="stub frame, no transport read performed",
        ),
        artifacts={},
        storage_transform="swapaxes01-scanner-native-to-nikon-render-parity-v2",
        rgb_path=f"/tmp/stub-out/frame-{slot:04d}.tif",
        ir_path=None,
        meter_rgbi_path=None,
    )


class _StubTransport:
    """Hand-written Transport double: deterministic, no I/O, scriptable
    start_scan outcome. Satisfies transport.Transport structurally."""

    def __init__(
        self,
        *,
        preview_thumbnails: int = 2,
        start_scan_raises: Exception | None = None,
        manual_frames_raises: Exception | None = None,
    ) -> None:
        self.device_open = False
        self.approved: list[int] = []
        self.spacing_offsets: list[tuple[int, int]] = []
        self.stop_requested = False
        self.eject_called = False
        self.close_called = False
        self._preview_thumbnails = preview_thumbnails
        self._start_scan_raises = start_scan_raises
        self.manual_frames_calls: list[tuple[int, ...]] = []
        self.preview_strip_calls = 0
        self._manual_frames_raises = manual_frames_raises

    def list_devices(self) -> list[domain.DeviceInfo]:
        return [_device_info()]

    def open_device(self, device_id: str) -> domain.DeviceInfo:
        self.device_open = True
        return _device_info()

    def status(self) -> domain.DeviceStatus:
        return domain.DeviceStatus(
            connected=self.device_open,
            device_id=_DEVICE_ID if self.device_open else None,
            preview_established=False,
            slot_count=None,
            active_job_id=None,
            lane_held=False,
            motion_armed=False,
            film_present=None,
        )

    def close_device(self) -> None:
        self.close_called = True
        self.device_open = False

    def preview(self, material, slots, on_thumbnail):
        for i in range(self._preview_thumbnails):
            on_thumbnail(_thumbnail(i + 1))
        return domain.PreviewResult(count=self._preview_thumbnails, fingerprint="stub-fp")

    def approve(self, slot: int) -> None:
        self.approved.append(slot)

    def set_spacing_offset(self, slot: int, offset_rows: int) -> domain.Thumbnail:
        self.spacing_offsets.append((slot, offset_rows))
        return domain.Thumbnail(
            slot=slot,
            boundary_rows=(100, 200),
            spacing_offset=offset_rows,
            needs_approval=True,
            warnings=("manual-review-required",),
            image_path=f"/tmp/stub-preview/adjusted-slot-{slot:04d}-{offset_rows}.tif",
        )

    def manual_frames(
        self, rows: list[int]
    ) -> tuple[
        domain.PreviewResult,
        tuple[domain.Thumbnail, ...],
        tuple[domain.BoundarySnap, ...],
        domain.Material,
    ]:
        self.manual_frames_calls.append(tuple(rows))
        if self._manual_frames_raises is not None:
            raise self._manual_frames_raises
        thumbnails = tuple(
            domain.Thumbnail(
                slot=i + 1,
                boundary_rows=(rows[i], rows[i + 1]),
                spacing_offset=0,
                needs_approval=True,
                warnings=("user-picked",),
                image_path=f"/tmp/stub-preview/manual-slot-{i + 1:04d}.tif",
            )
            for i in range(len(rows) - 1)
        )
        snaps = (
            domain.BoundarySnap(
                boundary_index=0,
                requested_row=rows[0],
                snapped_row=rows[0],
                evidence_run=(max(0, rows[0] - 2), rows[0] + 2),
            ),
        )
        return (
            domain.PreviewResult(count=len(thumbnails), fingerprint="stub-manual-fp"),
            thumbnails,
            snaps,
            domain.Material.COLOR_NEGATIVE,
        )

    def preview_strip(self) -> domain.PreviewStrip:
        self.preview_strip_calls += 1
        return domain.PreviewStrip(
            image_path="/tmp/stub-preview/strip.tif", row_count=4800, pixels_per_row=1
        )

    def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
        if self._start_scan_raises is not None:
            raise self._start_scan_raises
        return domain.ScanSummary(completed=tuple(slots), failed=(), stopped=False)

    def request_stop(self) -> None:
        self.stop_requested = True

    def eject(self) -> bool:
        self.eject_called = True
        return True


class _BlockingStartScanTransport(_StubTransport):
    """Like _StubTransport, but start_scan blocks until .release is set --
    lets a test observe "job active, not yet terminal" deterministically."""

    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.started = threading.Event()
        self.release = threading.Event()

    def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
        self.started.set()
        self.release.wait(timeout=2.0)
        return domain.ScanSummary(completed=tuple(slots), failed=(), stopped=False)


def _wire_recipe() -> dict:
    """The one fixed material=colorNegative recipe (domain.FIXED_COLOR_NEGATIVE_RECIPE)
    in wire (camelCase) shape."""
    return {
        "resolutionDpi": 4000,
        "bitDepth": 16,
        "multisamplePasses": 4,
        "channels": "rgbi",
        "autofocus": True,
        "autoExposure": True,
    }


def _wait_for(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pytest.fail("condition not met within timeout")


def _wait_for_preview_complete_and_lane_free(
    svc: service.BridgeService, emit: "_RecordingEmit"
) -> None:
    """Waits for roll.previewComplete, then also waits for `svc._lane_held`
    to be False before returning. Since the 2026-07-25 lane-release-
    ordering fix (see service.py's `_handle_roll_preview` worker), the lane
    is always already free by the time roll.previewComplete is emitted --
    the second wait is now a fast no-op, kept as a defensive belt-and-
    suspenders check (rather than a raw assert) so a future regression here
    fails at the actual next `HardwareLane.__enter__()` contention below
    instead of silently passing on a lucky scheduling."""
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for(lambda: not svc._lane_held)
    # The worker intentionally keeps this reporting gate true until the
    # terminal callback returns. A test that immediately dispatches the next
    # operation must wait for that handoff too, just like a real client
    # retries a transient HARDWARE_LANE_BUSY response.
    _wait_for(lambda: not svc._motion_op_active)


def _arm(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_text("junk-roll")


def _make_service(tmp_path: Path, transport: object | None = None) -> service.BridgeService:
    transport = transport if transport is not None else _StubTransport()
    svc = service.BridgeService(transport, safety.TelemetryLog(tmp_path), base_dir=tmp_path)
    svc.dispatch(
        {"id": 0, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
        lambda *_a: None,
    )
    return svc


def _opened_service(tmp_path: Path, transport: object | None = None) -> service.BridgeService:
    svc = _make_service(tmp_path, transport)
    svc.dispatch(
        {"id": 1, "method": "device.open", "params": {"deviceId": _DEVICE_ID}}, lambda *_a: None
    )
    return svc


def test_shutdown_refuses_to_acknowledge_a_still_live_owned_worker(tmp_path: Path) -> None:
    class _StillAliveThread:
        def join(self, timeout: float | None = None) -> None:
            del timeout

        def is_alive(self) -> bool:
            return True

    transport = _StubTransport()
    svc = _make_service(tmp_path, transport)
    svc._last_job = {
        "job_id": "owned-job",
        "terminal": False,
        "thread": _StillAliveThread(),
    }

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 7, "method": "bridge.shutdown", "params": {}}, lambda *_a: None)

    assert excinfo.value.code == ErrorCode.HARDWARE_LANE_BUSY
    assert "not acknowledged" in excinfo.value.message
    assert transport.stop_requested is True


class _RecordingEmit:
    """Thread-safe emit() collector shared between the dispatching test
    thread and BridgeService's worker threads."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._events: list[tuple[str, dict]] = []

    def __call__(self, event: str, payload: dict) -> None:
        with self._lock:
            self._events.append((event, payload))

    def names(self) -> list[str]:
        with self._lock:
            return [e for e, _p in self._events]

    def payload_of(self, event: str) -> dict:
        with self._lock:
            return next(p for e, p in self._events if e == event)

    def payloads_of(self, event: str) -> list[dict]:
        with self._lock:
            return [p for e, p in self._events if e == event]

    def has(self, event: str) -> bool:
        return event in self.names()


# -- reject_before_hello (pure function) -----------------------------------------


def test_reject_before_hello_rejects_non_hello_before_hello_received() -> None:
    err = service.reject_before_hello(False, "device.list")
    assert err is not None
    assert err.code == ErrorCode.INVALID_PARAMS


def test_reject_before_hello_allows_hello_itself_before_hello_received() -> None:
    assert service.reject_before_hello(False, "bridge.hello") is None


def test_reject_before_hello_allows_any_method_after_hello_received() -> None:
    assert service.reject_before_hello(True, "device.list") is None


# -- hello gate at the BridgeService level -----------------------------------------


def test_dispatch_before_hello_raises_invalid_params(tmp_path: Path) -> None:
    svc = service.BridgeService(
        _StubTransport(), safety.TelemetryLog(tmp_path), base_dir=tmp_path
    )
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 1, "method": "device.list"}, lambda *_a: None)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


def test_dispatch_unknown_method_after_hello_raises_unknown_method(tmp_path: Path) -> None:
    svc = _make_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 2, "method": "unknown.method"}, lambda *_a: None)
    assert excinfo.value.code == ErrorCode.UNKNOWN_METHOD


# -- device.* ---------------------------------------------------------------------


def test_device_list_returns_wired_stub_device(tmp_path: Path) -> None:
    svc = _make_service(tmp_path)
    result = svc.dispatch({"id": 1, "method": "device.list"}, lambda *_a: None)
    assert result["devices"][0]["deviceId"] == _DEVICE_ID


def test_device_open_twice_raises_already_connected(tmp_path: Path) -> None:
    svc = _opened_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 2, "method": "device.open", "params": {"deviceId": _DEVICE_ID}},
            lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.ALREADY_CONNECTED


def test_device_status_before_open_raises_not_connected(tmp_path: Path) -> None:
    svc = _make_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 1, "method": "device.status"}, lambda *_a: None)
    assert excinfo.value.code == ErrorCode.NOT_CONNECTED


def test_no_film_status_retires_service_preview_gate(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The service must not keep its cached preview material after the
    transport's fresh no-film verdict has invalidated physical registration.
    """

    class _NoFilmAfterPreviewTransport(_StubTransport):
        def status(self) -> domain.DeviceStatus:
            return domain.DeviceStatus(
                connected=self.device_open,
                device_id=_DEVICE_ID if self.device_open else None,
                preview_established=True,
                slot_count=1,
                active_job_id=None,
                lane_held=False,
                motion_armed=False,
                film_present=False,
            )

    transport = _NoFilmAfterPreviewTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    _arm(monkeypatch, tmp_path)
    emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    status = svc.dispatch({"id": 3, "method": "device.status"}, emit)
    assert status["filmPresent"] is False

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 4,
                "method": "scan.start",
                "params": {
                    "slots": [1],
                    "recipe": _wire_recipe(),
                    "output": {
                        "destination": str(tmp_path / "out"),
                        "filenameTemplate": "frame-####.tif",
                    },
                },
            },
            emit,
        )
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def test_device_close_emits_connected_false_status(tmp_path: Path) -> None:
    svc = _opened_service(tmp_path)
    emit = _RecordingEmit()
    result = svc.dispatch({"id": 2, "method": "device.close"}, emit)
    assert result == {}
    assert emit.payload_of("device.status")["status"]["connected"] is False


def test_device_eject_without_open_device_raises_not_connected(tmp_path: Path) -> None:
    svc = _make_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 1, "method": "device.eject"}, lambda *_a: None)
    assert excinfo.value.code == ErrorCode.NOT_CONNECTED


def _telemetry_entries(tmp_path: Path) -> list[dict]:
    telemetry_files = list((tmp_path / "hw-telemetry").glob("*.jsonl"))
    assert len(telemetry_files) == 1
    return [json.loads(line) for line in telemetry_files[0].read_text().splitlines()]


def test_device_eject_false_from_transport_is_eject_failed_never_silent_success(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The wire-level guarantee behind INCIDENT-20260719-eject-from-park:
    a transport reporting not-ejected must surface as a typed EJECT_FAILED
    error (with an error telemetry line carrying code AND message), never
    as device.eject's `{}` success."""

    class _NoEjectTransport(_StubTransport):
        def eject(self) -> bool:
            self.eject_called = True
            return False

    transport = _NoEjectTransport()
    svc = _opened_service(tmp_path, transport)
    _arm(monkeypatch, tmp_path)
    emit = _RecordingEmit()

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 2, "method": "device.eject"}, emit)

    assert excinfo.value.code == ErrorCode.EJECT_FAILED
    assert transport.eject_called is True
    # No success status event on a failed eject.
    assert not emit.has("device.status")
    outcomes = [(e["method"], e["outcome"]) for e in _telemetry_entries(tmp_path)]
    assert ("device.eject", "started") in outcomes
    assert ("device.eject", "error") in outcomes
    assert ("device.eject", "ok") not in outcomes
    error_entry = next(
        e
        for e in _telemetry_entries(tmp_path)
        if e["method"] == "device.eject" and e["outcome"] == "error"
    )
    assert error_entry["code"] == ErrorCode.EJECT_FAILED.value
    assert "not ejected" in error_entry["message"]


def test_device_eject_bridge_error_from_transport_records_error_telemetry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A typed stall (FEEDER_PARKED from the driver's traced eject)
    propagates verbatim and leaves a code+message error telemetry line --
    the 2026-07-25 lesson that a bare code is undiagnosable later."""

    class _ParkedTransport(_StubTransport):
        def eject(self) -> bool:
            raise BridgeError(
                ErrorCode.FEEDER_PARKED,
                "eject accepted without confirmed clear; power cycle required",
            )

    svc = _opened_service(tmp_path, _ParkedTransport())
    _arm(monkeypatch, tmp_path)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 2, "method": "device.eject"}, lambda *_a: None)

    assert excinfo.value.code == ErrorCode.FEEDER_PARKED
    error_entry = next(
        e
        for e in _telemetry_entries(tmp_path)
        if e["method"] == "device.eject" and e["outcome"] == "error"
    )
    assert error_entry["code"] == ErrorCode.FEEDER_PARKED.value
    assert "power cycle" in error_entry["message"]


def test_device_eject_success_clears_preview_material_so_scan_start_is_no_preview(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """After a confirmed eject the film is out: scan.start must be back
    behind NO_PREVIEW (the service-side `_preview_material` gate), and the
    post-eject device.status event fires after the lane is released."""
    svc = _opened_service(tmp_path)
    _arm(monkeypatch, tmp_path)
    emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    result = svc.dispatch({"id": 3, "method": "device.eject"}, emit)
    assert result == {}
    assert emit.payload_of("device.status")["status"]["laneHeld"] is False

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 4,
                "method": "scan.start",
                "params": {
                    "slots": [1],
                    "recipe": _wire_recipe(),
                    "output": {"destination": str(tmp_path), "filenameTemplate": "f-####.tif"},
                },
            },
            emit,
        )
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


# -- roll.preview: SAFE-02 gate ------------------------------------------------------


def test_roll_preview_without_open_device_raises_not_connected(tmp_path: Path) -> None:
    svc = _make_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}},
            lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.NOT_CONNECTED


def test_roll_preview_disarmed_raises_hw_motion_not_armed_synchronously(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv(safety.HW_MOTION_ENV_VAR, raising=False)
    svc = _opened_service(tmp_path)
    emit = _RecordingEmit()
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
        )
    assert excinfo.value.code == ErrorCode.HW_MOTION_NOT_ARMED
    assert emit.names() == []


def test_roll_preview_armed_streams_thumbnails_then_preview_complete_in_order(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(preview_thumbnails=2)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    result = svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    assert result == {"accepted": True}

    _wait_for(lambda: emit.has("roll.previewComplete"))
    assert emit.names() == ["roll.thumbnail", "roll.thumbnail", "roll.previewComplete"]


def test_roll_set_spacing_offset_returns_fresh_thumbnail_without_motion_gate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()
    svc.dispatch(
        {
            "id": 2,
            "method": "roll.preview",
            "params": {"material": "colorNegative"},
        },
        emit,
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)
    _wait_for(lambda: not svc._motion_op_active)
    monkeypatch.delenv(safety.HW_MOTION_ENV_VAR, raising=False)

    result = svc.dispatch(
        {
            "id": 2,
            "method": "roll.setSpacingOffset",
            "params": {"slot": 2, "offsetRows": -3},
        },
        lambda *_a: None,
    )

    assert transport.spacing_offsets == [(2, -3)]
    assert result == {
        "thumbnail": {
            "slot": 2,
            "boundaryRows": [100, 200],
            "spacingOffset": -3,
            "needsApproval": True,
            "warnings": ["manual-review-required"],
            "imagePath": "/tmp/stub-preview/adjusted-slot-0002--3.tif",
        }
    }


def test_roll_set_spacing_offset_missing_offset_rows_is_invalid_params(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()
    svc.dispatch(
        {
            "id": 2,
            "method": "roll.preview",
            "params": {"material": "colorNegative"},
        },
        emit,
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)
    _wait_for(lambda: not svc._motion_op_active)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 3,
                "method": "roll.setSpacingOffset",
                "params": {"slot": 1},
            },
            lambda *_a: None,
        )

    assert excinfo.value.code is ErrorCode.INVALID_PARAMS
    assert "offsetRows" in str(excinfo.value)
    assert transport.spacing_offsets == []


def test_roll_set_spacing_offset_without_open_device_is_not_connected(
    tmp_path: Path,
) -> None:
    transport = _StubTransport()
    svc = _make_service(tmp_path, transport)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 2,
                "method": "roll.setSpacingOffset",
                "params": {"slot": 1, "offsetRows": 0},
            },
            lambda *_a: None,
        )

    assert excinfo.value.code is ErrorCode.NOT_CONNECTED
    assert transport.spacing_offsets == []


def test_roll_set_spacing_offset_without_completed_preview_is_no_preview(
    tmp_path: Path,
) -> None:
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 2,
                "method": "roll.setSpacingOffset",
                "params": {"slot": 1, "offsetRows": 0},
            },
            lambda *_a: None,
        )

    assert excinfo.value.code is ErrorCode.NO_PREVIEW
    assert transport.spacing_offsets == []


def test_roll_set_spacing_offset_is_refused_while_scan_job_is_active(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _BlockingStartScanTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()
    svc.dispatch(
        {
            "id": 2,
            "method": "roll.preview",
            "params": {"material": "colorNegative"},
        },
        emit,
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)
    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    assert transport.started.wait(timeout=2)

    try:
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch(
                {
                    "id": 4,
                    "method": "roll.setSpacingOffset",
                    "params": {"slot": 1, "offsetRows": 1},
                },
                lambda *_a: None,
            )
        assert excinfo.value.code is ErrorCode.HARDWARE_LANE_BUSY
        assert transport.spacing_offsets == []
    finally:
        transport.release.set()
        _wait_for(lambda: emit.has("scan.completed"))


# -- roll.manualFrames / roll.previewStrip (Rung 4) --------------------------------


def test_roll_manual_frames_dispatch_routes_rows_and_rearms_scan_gate(
    tmp_path: Path,
) -> None:
    """Proves the dispatch shape end to end: roll.manualFrames reaches
    transport.manual_frames() with the exact rows requested, the wire result
    carries count/fingerprint/thumbnails/snaps, and -- since manual_frames()
    arms a usable session without ever calling roll.preview -- a following
    scan.start is no longer refused with NO_PREVIEW (BridgeService's
    self._preview_material must have been re-armed from the transport's
    returned material, not from a roll.preview request that never
    happened)."""
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)

    result = svc.dispatch(
        {
            "id": 2,
            "method": "roll.manualFrames",
            "params": {"rows": [100, 300, 500]},
        },
        lambda *_a: None,
    )

    assert transport.manual_frames_calls == [(100, 300, 500)]
    assert result["count"] == 2
    assert result["fingerprint"] == "stub-manual-fp"
    assert [t["slot"] for t in result["thumbnails"]] == [1, 2]
    assert result["thumbnails"][0]["boundaryRows"] == [100, 300]
    assert result["thumbnails"][0]["needsApproval"] is True
    assert result["snaps"] == [
        {
            "boundaryIndex": 0,
            "requestedRow": 100,
            "snappedRow": 100,
            "evidenceRun": [98, 102],
        }
    ]

    # The real proof this armed a usable session: scan.start no longer
    # raises NO_PREVIEW, even though roll.preview was never called this
    # session.
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 3,
                "method": "scan.start",
                "params": {
                    "slots": [1],
                    "recipe": _wire_recipe(),
                    "output": {
                        "destination": str(tmp_path / "out"),
                        "filenameTemplate": "frame-####.tif",
                    },
                },
            },
            lambda *_a: None,
        )
    # HW_MOTION_NOT_ARMED (the latch was never armed in this test) proves
    # scan.start got PAST its NO_PREVIEW gate -- the one thing this test is
    # pinning -- and was refused for an unrelated, later reason instead.
    assert excinfo.value.code is ErrorCode.HW_MOTION_NOT_ARMED


def test_roll_manual_frames_without_open_device_is_not_connected(
    tmp_path: Path,
) -> None:
    transport = _StubTransport()
    svc = _make_service(tmp_path, transport)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 2,
                "method": "roll.manualFrames",
                "params": {"rows": [100, 300]},
            },
            lambda *_a: None,
        )

    assert excinfo.value.code is ErrorCode.NOT_CONNECTED
    assert transport.manual_frames_calls == []


def test_roll_manual_frames_missing_rows_is_invalid_params(tmp_path: Path) -> None:
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 2, "method": "roll.manualFrames", "params": {}},
            lambda *_a: None,
        )

    assert excinfo.value.code is ErrorCode.INVALID_PARAMS
    assert "rows" in str(excinfo.value)
    assert transport.manual_frames_calls == []


def test_roll_manual_frames_propagates_transport_validation_error_unmodified(
    tmp_path: Path,
) -> None:
    """service.py must not truncate or reshape a validation-failure
    BridgeError raised from the transport -- the plain-English sentence
    manual_frames.py's own gates produce is what the operator needs to see,
    unmodified, at the dispatch boundary."""
    sentence = (
        "the 1st frame you placed is about 8 mm tall (between rows 10 and "
        "40), outside the 15-75 mm range this driver accepts for manual "
        "placement"
    )
    transport = _StubTransport(
        manual_frames_raises=BridgeError(ErrorCode.INVALID_PARAMS, sentence)
    )
    svc = _opened_service(tmp_path, transport)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 2,
                "method": "roll.manualFrames",
                "params": {"rows": [10, 40]},
            },
            lambda *_a: None,
        )

    assert excinfo.value.code is ErrorCode.INVALID_PARAMS
    assert str(excinfo.value) == sentence


def test_roll_preview_strip_dispatch_returns_wire_shape(tmp_path: Path) -> None:
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)

    result = svc.dispatch(
        {"id": 2, "method": "roll.previewStrip", "params": {}}, lambda *_a: None
    )

    assert transport.preview_strip_calls == 1
    assert result == {
        "imagePath": "/tmp/stub-preview/strip.tif",
        "rowCount": 4800,
        "pixelsPerRow": 1,
    }


def test_roll_preview_strip_without_open_device_is_not_connected(
    tmp_path: Path,
) -> None:
    transport = _StubTransport()
    svc = _make_service(tmp_path, transport)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 2, "method": "roll.previewStrip", "params": {}}, lambda *_a: None
        )

    assert excinfo.value.code is ErrorCode.NOT_CONNECTED
    assert transport.preview_strip_calls == 0


def test_roll_preview_error_telemetry_includes_message(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """BRIDGE.md's SAFE-02 telemetry guardrail records a `code` for every
    roll.preview failure, but historically dropped the human-readable
    message entirely -- live 2026-07-25, an INTERNAL roll.preview failure's
    real coolscanpy exception text (an IndexDecodeError diagnosing a
    non-affine transport table) never reached hw-telemetry, only the bare
    code. The recorded "error" entry must also carry `message`."""
    _arm(monkeypatch, tmp_path)

    class _PreviewRaisingTransport(_StubTransport):
        def preview(self, material, slots, on_thumbnail):
            raise BridgeError(ErrorCode.FEEDER_PARKED, "power cycle required")

    svc = _opened_service(tmp_path, _PreviewRaisingTransport())
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for(lambda: emit.has("roll.previewError"))

    telemetry_files = list((tmp_path / "hw-telemetry").glob("*.jsonl"))
    assert len(telemetry_files) == 1
    entries = [json.loads(line) for line in telemetry_files[0].read_text().splitlines()]
    error_entry = next(
        e for e in entries if e["method"] == "roll.preview" and e["outcome"] == "error"
    )
    assert error_entry["message"] == "power cycle required"


# -- roll.preview: lane released before the terminal event reaches anyone -----------
#
# Live 2026-07-25: the GUI engine reacts to roll.previewComplete /
# roll.previewError by immediately dispatching device.status -- and the old
# worker emitted that terminal event (and recorded its telemetry) BEFORE its
# own `finally` block released the hardware lane (`self._lane_held = False`;
# `lane.__exit__()`). A device.status landing in that window reported the
# lane still held even though `flock` on the lane lockfile proved it free,
# and the app rendered "Scanner busy" forever with no later re-poll to
# correct it. Each test below dispatches device.status SYNCHRONOUSLY from
# inside the emit callback, at the exact instant the terminal event is
# emitted -- deterministic, no sleep/timing guess: whatever `self._lane_held`
# is AT THAT MOMENT is exactly what a real racing GUI poll would observe.
#
# The assertion itself lives in the test body, never inside the callback: an
# AssertionError raised from inside the callback would be caught by the
# worker's own broad `except Exception` handler (the callback is called from
# directly inside that worker's try-block), which would silently convert a
# real test failure into a spurious roll.previewError event/telemetry entry
# instead of failing the test. So the callback only records what it saw,
# thread-safely, and the test body asserts on the recording afterward.


def test_roll_preview_complete_device_status_polled_from_callback_sees_lane_not_held(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)

    lock = threading.Lock()
    lane_held_snapshots: list[bool] = []

    def emit(event: str, payload: dict) -> None:
        if event == "roll.previewComplete":
            status = svc.dispatch(
                {"id": 98, "method": "device.status"}, lambda *_a: None
            )
            with lock:
                lane_held_snapshots.append(status["laneHeld"])

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for(lambda: len(lane_held_snapshots) == 1)

    assert lane_held_snapshots == [False]


def test_roll_preview_error_device_status_polled_from_callback_sees_lane_not_held(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Same race as the previewComplete test above, on the failure path."""
    _arm(monkeypatch, tmp_path)

    class _PreviewRaisingTransport(_StubTransport):
        def preview(self, material, slots, on_thumbnail):
            raise BridgeError(ErrorCode.FEEDER_PARKED, "power cycle required")

    svc = _opened_service(tmp_path, _PreviewRaisingTransport())

    lock = threading.Lock()
    lane_held_snapshots: list[bool] = []

    def emit(event: str, payload: dict) -> None:
        if event == "roll.previewError":
            status = svc.dispatch(
                {"id": 98, "method": "device.status"}, lambda *_a: None
            )
            with lock:
                lane_held_snapshots.append(status["laneHeld"])

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for(lambda: len(lane_held_snapshots) == 1)

    assert lane_held_snapshots == [False]


# -- scan.stop --------------------------------------------------------------------


def test_scan_stop_unknown_job_id_raises_unknown_job(tmp_path: Path) -> None:
    svc = _opened_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 5, "method": "scan.stop", "params": {"jobId": "never-issued"}},
            lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.UNKNOWN_JOB


def test_scan_start_without_preview_raises_no_preview(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    svc = _opened_service(tmp_path)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 2,
                "method": "scan.start",
                "params": {
                    "slots": [1],
                    "recipe": _wire_recipe(),
                    "output": {
                        "destination": str(tmp_path / "out"),
                        "filenameTemplate": "frame-####.tif",
                    },
                },
            },
            lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def test_scan_stop_on_already_terminal_job_returns_acknowledged_false(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    start_result = svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    job_id = start_result["jobId"]
    _wait_for(lambda: emit.has("scan.completed"))

    result = svc.dispatch({"id": 4, "method": "scan.stop", "params": {"jobId": job_id}}, emit)
    assert result == {"acknowledged": False}


def test_scan_start_echoes_engine_operation_token_and_refuses_reuse(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    token = "0123456789abcdef0123456789abcdef"
    params = {
        "jobId": token,
        "slots": [1],
        "recipe": _wire_recipe(),
        "output": {
            "destination": str(tmp_path / "out"),
            "filenameTemplate": "frame-####.tif",
        },
    }
    assert svc.dispatch({"id": 3, "method": "scan.start", "params": params}, emit) == {
        "jobId": token
    }
    _wait_for(lambda: emit.has("scan.completed"))
    _wait_for(lambda: not svc._motion_op_active)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch({"id": 4, "method": "scan.start", "params": params}, emit)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "already used" in excinfo.value.message


def test_scan_start_ingress_rejects_coercible_nonfinite_missing_and_unknown_values(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    svc = _opened_service(tmp_path, _StubTransport())
    svc._preview_material = domain.Material.COLOR_NEGATIVE
    output = {
        "destination": str(tmp_path / "out"),
        "filenameTemplate": "frame-####.tif",
    }
    missing_recipe_field = _wire_recipe()
    del missing_recipe_field["bitDepth"]
    bad_params = [
        {"slots": [True], "recipe": _wire_recipe(), "output": output},
        {"slots": ["1"], "recipe": _wire_recipe(), "output": output},
        {
            "slots": [1],
            "recipe": {**_wire_recipe(), "resolutionDpi": "4000"},
            "output": output,
        },
        {
            "slots": [1],
            "recipe": {**_wire_recipe(), "resolutionDpi": True},
            "output": output,
        },
        {
            "slots": [1],
            "recipe": {**_wire_recipe(), "resolutionDpi": float("nan")},
            "output": output,
        },
        {"slots": [1], "recipe": missing_recipe_field, "output": output},
        {
            "slots": [1],
            "recipe": {**_wire_recipe(), "unexpected": 1},
            "output": output,
        },
        {
            "slots": [1],
            "recipe": _wire_recipe(),
            "output": output,
            "unexpected": 1,
        },
        {"slots": [1], "recipe": _wire_recipe()},
    ]

    for request_id, params in enumerate(bad_params, start=20):
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch(
                {"id": request_id, "method": "scan.start", "params": params},
                lambda *_a: None,
            )
        assert excinfo.value.code == ErrorCode.INVALID_PARAMS
        assert svc._lane_held is False
        assert svc._motion_op_active is False


def test_other_hardware_ingress_rejects_bool_strings_and_unknown_fields(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)

    bad_preview_requests = [
        {"material": True},
        {"material": "1"},
        {"material": "colorNegative", "slots": [True]},
        {"material": "colorNegative", "slots": ["1"]},
        {"material": "colorNegative", "unexpected": 1},
        {},
    ]
    for request_id, params in enumerate(bad_preview_requests, start=40):
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch(
                {"id": request_id, "method": "roll.preview", "params": params},
                lambda *_a: None,
            )
        assert excinfo.value.code == ErrorCode.INVALID_PARAMS

    svc._preview_material = domain.Material.COLOR_NEGATIVE
    for request_id, params in enumerate(
        [
            {"slot": True, "offsetRows": 0},
            {"slot": "1", "offsetRows": 0},
            {"slot": 1, "offsetRows": "0"},
            {"slot": 1, "offsetRows": 0, "unexpected": False},
        ],
        start=50,
    ):
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch(
                {
                    "id": request_id,
                    "method": "roll.setSpacingOffset",
                    "params": params,
                },
                lambda *_a: None,
            )
        assert excinfo.value.code == ErrorCode.INVALID_PARAMS

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 60, "method": "device.eject", "params": {"force": True}},
            lambda *_a: None,
        )
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert transport.eject_called is False


def test_device_close_raises_hardware_lane_busy_while_job_active(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _BlockingStartScanTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    assert transport.started.wait(timeout=2.0)

    try:
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch({"id": 4, "method": "device.close"}, emit)
        assert excinfo.value.code == ErrorCode.HARDWARE_LANE_BUSY
    finally:
        transport.release.set()
        _wait_for(lambda: emit.has("scan.completed"))


# -- scan.start: FrameRetryExhausted -> anomaly halt -----------------------------


def test_scan_start_frame_retry_exhausted_emits_anomaly_before_completed_and_ejects(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(
        preview_thumbnails=1, start_scan_raises=FrameRetryExhausted(3, RuntimeError("x"))
    )
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [3],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert names.index("hardware.anomaly") < names.index("scan.completed")
    anomaly = emit.payload_of("hardware.anomaly")
    assert anomaly["code"] == ErrorCode.TRANSPORT_SMEAR_DETECTED.value
    assert transport.eject_called is True


# -- scan.start: never-silent guarantee (Plan 10-05) -------------------------------
#
# LIVE-VERIFICATION-20260723.md attempt #2 (2026-07-23 ~18:00 PDT): hw-telemetry
# proved `roll.scan:slot1` entered and exited in 0.55s -- too fast for real
# motion -- and the worker then emitted nothing at all, ever (no scan.error, no
# scan.completed, no closing scan.start telemetry line). Root cause: the
# pre-Plan-10-05 worker only ever assigned its local `summary` variable on
# success or on FrameRetryExhausted; any OTHER exception fell through to
# `finally`'s `to_wire(summary)` and raised UnboundLocalError, which silently
# killed the daemon worker thread. Each test below drives a different outcome
# shape transport.start_scan can produce and asserts the wire can never go
# silent again -- against the pre-fix worker, every `_wait_for(scan.completed)`
# below times out and fails instead.


def test_scan_start_bridge_error_from_transport_emits_scan_error_then_completed_with_slot_failed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The REAL observed shape (Plan 10-05 root cause): CoolscanPyTransport
    already correctly maps coolscanpy.RefeedRequired ->
    BridgeError(REFEED_REQUIRED, ...) (see
    tests/test_transport_coolscanpy.py's test_start_scan_maps_refeed_required)
    -- this BridgeError is exactly what the old worker silently swallowed."""
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(
        preview_thumbnails=1,
        start_scan_raises=BridgeError(
            ErrorCode.REFEED_REQUIRED,
            "the fine-scan fresh index read failed because the transport is "
            "parked at the end-stop from an earlier preview; pull the strip "
            "fully out, reinsert it until the feeder grips, then retry the batch",
        ),
    )
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    # Against the pre-Plan-10-05 worker this never resolves: the worker
    # thread dies inside `finally` with no wire output at all, so this line
    # times out and fails the test on the OLD code; it resolves immediately
    # against the fix.
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert "scan.error" in names, names
    assert names.index("scan.error") < names.index("scan.completed")

    error_payload = emit.payload_of("scan.error")
    assert error_payload["code"] == ErrorCode.REFEED_REQUIRED.value
    assert "end-stop" in error_payload["message"]

    completed_summary = emit.payload_of("scan.completed")["summary"]
    assert completed_summary["completed"] == []
    assert completed_summary["failed"] == [1]
    assert completed_summary["stopped"] is False


def test_film_feed_interrupted_retires_service_preview_before_a_second_scan_start(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A terminal dropout is sufficient to close the preview gate; the UI
    must not need to poll device.status before its next scan.start is refused.
    """

    class _FilmFeedInterruptedTransport(_StubTransport):
        def __init__(self) -> None:
            super().__init__(preview_thumbnails=1)
            self.start_scan_calls = 0

        def start_scan(
            self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None
        ):
            self.start_scan_calls += 1
            raise BridgeError(
                ErrorCode.FILM_FEED_INTERRUPTED,
                "film feed interrupted: scanner stopped detecting film (02/3A/00)",
            )

    _arm(monkeypatch, tmp_path)
    transport = _FilmFeedInterruptedTransport()
    svc = _opened_service(tmp_path, transport)
    scan_params = {
        "slots": [1],
        "recipe": _wire_recipe(),
        "output": {
            "destination": str(tmp_path / "out"),
            "filenameTemplate": "frame-####.tif",
        },
    }
    terminal_refusals: list[ErrorCode] = []

    class _TerminalReentrantEmit(_RecordingEmit):
        def __call__(self, event: str, payload: dict) -> None:
            if event == "scan.completed" and not terminal_refusals:
                try:
                    svc.dispatch(
                        {"id": 4, "method": "scan.start", "params": scan_params}, self
                    )
                except BridgeError as exc:
                    terminal_refusals.append(exc.code)
            super().__call__(event, payload)

    emit = _TerminalReentrantEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch({"id": 3, "method": "scan.start", "params": scan_params}, emit)
    _wait_for(lambda: emit.has("scan.completed"))

    assert terminal_refusals == [ErrorCode.NO_PREVIEW]
    assert transport.start_scan_calls == 1


def test_film_feed_interrupted_summary_preserves_completed_frames_and_fails_only_pending(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A typed terminal error after three callbacks must not rewrite those
    durable completions as failures in the terminal batch summary.
    """

    class _ThreeFramesThenDropoutTransport(_StubTransport):
        def start_scan(
            self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None
        ):
            for slot in slots[:3]:
                on_frame(slot, _stub_receipt(slot))
            raise BridgeError(
                ErrorCode.FILM_FEED_INTERRUPTED,
                "film feed interrupted while positioning frame 4 (02/3A/00)",
            )

    _arm(monkeypatch, tmp_path)
    svc = _opened_service(
        tmp_path, _ThreeFramesThenDropoutTransport(preview_thumbnails=6)
    )
    emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1, 2, 3, 4, 5, 6],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    summary = emit.payload_of("scan.completed")["summary"]
    assert summary["completed"] == [1, 2, 3]
    assert summary["failed"] == [4, 5, 6]
    assert summary["stopped"] is False
    assert [payload["slot"] for payload in emit.payloads_of("scan.frameCompleted")] == [
        1,
        2,
        3,
    ]
    assert [payload["slot"] for payload in emit.payloads_of("scan.frameFailed")] == [4]
    terminal_order = [
        name
        for name in emit.names()
        if name
        in {
            "scan.frameCompleted",
            "scan.frameFailed",
            "scan.error",
            "scan.completed",
        }
    ]
    assert terminal_order == [
        "scan.frameCompleted",
        "scan.frameCompleted",
        "scan.frameCompleted",
        "scan.frameFailed",
        "scan.error",
        "scan.completed",
    ]


def test_scan_start_unexpected_exception_from_transport_emits_internal_scan_error_then_completed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A Transport bug (or any exception type CoolscanPyTransport doesn't
    itself translate to BridgeError) must still reach the wire -- never
    silently kill the worker thread."""
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(
        preview_thumbnails=1, start_scan_raises=RuntimeError("unexpected transport bug")
    )
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    error_payload = emit.payload_of("scan.error")
    assert error_payload["code"] == ErrorCode.INTERNAL.value
    assert "RuntimeError" in error_payload["message"]
    assert "unexpected transport bug" in error_payload["message"]

    completed_summary = emit.payload_of("scan.completed")["summary"]
    assert completed_summary["failed"] == [1]


class _NoneReturningTransport(_StubTransport):
    """start_scan returns None instead of a ScanSummary -- simulates a
    misbehaving Transport that fails by returning rather than raising."""

    def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
        return None


def test_scan_start_none_return_from_transport_emits_internal_scan_error_then_completed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _NoneReturningTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    error_payload = emit.payload_of("scan.error")
    assert error_payload["code"] == ErrorCode.INTERNAL.value
    assert "None" in error_payload["message"]

    completed_summary = emit.payload_of("scan.completed")["summary"]
    assert completed_summary["failed"] == [1]


class _EmptySummaryTransport(_StubTransport):
    """start_scan returns a ScanSummary that accounts for none of the
    requested slots (not completed, not failed, not stopped) -- the
    no-motion, no-op-result shape Plan 10-05's Task 2 hypothesis list named
    ("a required kwarg/mode makes the call return a no-op result"). Ruled out
    as the live root cause (see the Plan 10-05 SUMMARY: the live telemetry's
    missing `scan.start "ok"` line proves transport.start_scan raised rather
    than returned), but still a shape this worker must never go silent on."""

    def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
        return domain.ScanSummary(completed=(), failed=(), stopped=False)


def test_scan_start_empty_summary_from_transport_emits_internal_scan_error_then_completed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _EmptySummaryTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)
    emit = _RecordingEmit()

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for_preview_complete_and_lane_free(svc, emit)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert "scan.error" in names, names
    error_payload = emit.payload_of("scan.error")
    assert error_payload["code"] == ErrorCode.INTERNAL.value
    assert "accounts for none of the requested slots" in error_payload["message"]

    # The degenerate empty result itself is discarded, not propagated: the
    # worker reports the requested slot(s) failed rather than parroting back
    # an empty-but-claimed-successful summary.
    completed_summary = emit.payload_of("scan.completed")["summary"]
    assert completed_summary["completed"] == []
    assert completed_summary["failed"] == [1]
    assert completed_summary["stopped"] is False


# -- scan.start: lane released before the terminal event reaches anyone -------------
#
# Same 2026-07-25 live race as the roll.preview section above, checked on
# scan.start's own worker: scan.completed is the unconditional terminal event
# for every scan.start job (BRIDGE.md: scan.error, when it fires, never
# replaces scan.completed), and the old shared `finally` block emitted it
# (plus, on an error path, scan.error and the closing scan.start telemetry)
# BEFORE that same block released the hardware lane. Not explicitly required
# by the fix request (which scoped the new regression test to roll.preview),
# but added for symmetry: this exercises the larger, riskier of the two
# reordered workers at the same rigor.


def test_scan_completed_device_status_polled_from_callback_sees_lane_not_held(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = _StubTransport(preview_thumbnails=1)
    svc = _opened_service(tmp_path, transport)

    lock = threading.Lock()
    lane_held_snapshots: list[bool] = []

    def emit(event: str, payload: dict) -> None:
        if event == "scan.completed":
            status = svc.dispatch(
                {"id": 98, "method": "device.status"}, lambda *_a: None
            )
            with lock:
                lane_held_snapshots.append(status["laneHeld"])

    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    # Not _wait_for_preview_complete_and_lane_free: that helper's first wait
    # requires a _RecordingEmit's `.has()` interface, which this test's plain
    # callback function doesn't implement. Waiting on `svc._lane_held`
    # directly is equivalent here (and is exactly the condition this test
    # cares about) regardless of which side of the roll.preview fix is
    # active, since the lane is always released, eventually, either way.
    _wait_for(lambda: not svc._lane_held)
    _wait_for(lambda: not svc._motion_op_active)

    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": [1],
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    _wait_for(lambda: len(lane_held_snapshots) == 1)

    assert lane_held_snapshots == [False]


# -- motion-operation gate: no new operation inside the terminal-reporting window ---
#
# Adversarial review of the lane-release reorder (2026-07-25): releasing the
# hardware lane before the terminal event reaches the wire opened a window in
# which a NEW motion request (or device.close) could be accepted while the old
# operation's terminal events were still being reported -- the old job's
# events could then interleave into (or be consumed as) the new operation's.
# The service therefore keeps a protocol-operation gate, separate from the
# hardware lane, from acceptance until the terminal event has been handed to
# emit. device.status keeps reporting the LANE alone (free), so the stale-
# "Scanner busy" fix above is unaffected.


def test_new_preview_inside_terminal_reporting_window_is_refused_then_accepted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """From INSIDE the roll.previewComplete callback -- lane already
    released, gate still held -- a second roll.preview must bounce with the
    recoverable HARDWARE_LANE_BUSY, and a retry after the worker finishes
    must be accepted."""
    _arm(monkeypatch, tmp_path)
    svc = _opened_service(tmp_path)
    window_refusals: list[str] = []

    class _ReentrantEmit(_RecordingEmit):
        def __call__(self, event: str, payload: dict) -> None:
            # Reentrant dispatch FIRST, record the event LAST: the main
            # thread's `_wait_for(emit.has("roll.previewComplete"))` may wake
            # the instant the event is visible, so the event becoming
            # visible must IMPLY the reentry already ran -- recording first
            # let the assert race the worker thread (observed 5/10 flake).
            if event == "roll.previewComplete" and not window_refusals:
                try:
                    svc.dispatch(
                        {
                            "id": 98,
                            "method": "roll.preview",
                            "params": {"material": "colorNegative"},
                        },
                        self,
                    )
                except BridgeError as exc:
                    window_refusals.append(exc.code.value)
            super().__call__(event, payload)

    emit = _ReentrantEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for(lambda: emit.has("roll.previewComplete"))
    assert window_refusals == [ErrorCode.HARDWARE_LANE_BUSY.value]

    # Once the worker has fully finished reporting, the gate is down and a
    # fresh preview is accepted normally.
    _wait_for(lambda: not svc._motion_op_active)
    emit2 = _RecordingEmit()
    svc.dispatch(
        {"id": 3, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit2
    )
    _wait_for(lambda: emit2.has("roll.previewComplete"))


def test_device_close_inside_terminal_reporting_window_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """device.close accepted between the lane release and the terminal event
    would let a disconnected device.status precede the old operation's own
    completion on the wire -- it must bounce with HARDWARE_LANE_BUSY inside
    that window."""
    _arm(monkeypatch, tmp_path)
    svc = _opened_service(tmp_path)
    window_refusals: list[str] = []

    class _ClosingEmit(_RecordingEmit):
        def __call__(self, event: str, payload: dict) -> None:
            # Reentry before recording, for the same has()-implies-reentry
            # ordering reason as _ReentrantEmit above.
            if event == "roll.previewComplete" and not window_refusals:
                try:
                    svc.dispatch({"id": 99, "method": "device.close"}, self)
                except BridgeError as exc:
                    window_refusals.append(exc.code.value)
            super().__call__(event, payload)

    emit = _ClosingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for(lambda: emit.has("roll.previewComplete"))
    assert window_refusals == [ErrorCode.HARDWARE_LANE_BUSY.value]


def test_failed_preview_does_not_claim_a_preview_material(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Adversarial review, 2026-07-25: `_preview_material` was committed at
    request ACCEPTANCE, so a preview that then failed left the service
    claiming a material -- scan.start's NO_PREVIEW gate passed on state no
    successful preview ever established. It now commits on success only."""
    _arm(monkeypatch, tmp_path)

    class _PreviewRaisingTransport(_StubTransport):
        def preview(self, material, slots, on_thumbnail):
            raise BridgeError(ErrorCode.FEEDER_PARKED, "power cycle required")

    svc = _opened_service(tmp_path, _PreviewRaisingTransport())
    emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    _wait_for(lambda: emit.has("roll.previewError"))
    _wait_for(lambda: not svc._motion_op_active)

    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {
                "id": 3,
                "method": "scan.start",
                "params": {
                    "slots": [1],
                    "recipe": _wire_recipe(),
                    "output": {
                        "destination": str(tmp_path / "out"),
                        "filenameTemplate": "frame-####.tif",
                    },
                },
            },
            emit,
        )
    assert excinfo.value.code == ErrorCode.NO_PREVIEW


def test_roll_manual_frames_rejects_non_integer_rows(tmp_path: Path) -> None:
    """Wire strictness (adversarial review 2026-08-08, F8a): floats, digit
    strings, booleans, and non-lists must all refuse as INVALID_PARAMS with
    a plain sentence -- never truncate, explode into digits, or surface as
    INTERNAL -- and must never reach the transport."""

    transport = _StubTransport()
    svc = _opened_service(tmp_path, transport)

    for bad in ([12.5, 200], ["123"], [True, 200], "12,200", [12, "x"]):
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch(
                {"id": 3, "method": "roll.manualFrames", "params": {"rows": bad}},
                lambda *_a: None,
            )
        assert excinfo.value.code is ErrorCode.INVALID_PARAMS, bad
        assert "whole numbers" in str(excinfo.value), bad
    assert transport.manual_frames_calls == []
