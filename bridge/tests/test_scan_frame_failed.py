"""Tests for the scan worker's durable per-frame failure reasons (Plan
10-09 deliverable 1, plus the coordinator's scope addition #1: a
ManualReviewRequired-sourced per-slot skip must also surface a
scan.frameFailed event/telemetry entry instead of an unexplained failed[]).

Drives BridgeService in-process against a small hand-written stub Transport
(mirrors tests/test_service_dispatch.py's own `_StubTransport` pattern) so
every failure path (retry exhaustion, a translated BridgeError with a
chained real coolscanpy exception, a genuinely unexpected exception, and a
ScanSummary.failure_reasons-carried per-slot skip) is exercised
deterministically, hardware-free. Every test uses tmp_path as safety's
base_dir, never the real ~/.scanstudio (see safety.py's own module
docstring).
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import coolscanpy
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


def _stub_receipt(slot: int) -> domain.ScanReceipt:
    """Minimal valid ScanReceipt for a test double's on_frame call --
    field values are arbitrary placeholders, never asserted on."""
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
            fractions=(0.0, 0.0, 0.0), clip_level=0.995, warning_fraction=0.02, warning=False
        ),
        focus_detail=domain.FocusDetailTelemetry(
            method="laplacian-variance", verdict="measured", score=0.0, texture_span=0.0
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
    start_scan outcome -- either raises `start_scan_raises` or returns
    `start_scan_returns` (a full ScanSummary the test controls directly,
    e.g. with `failure_reasons` pre-populated -- the shape
    CoolscanPyTransport itself produces for a ManualReviewRequired skip).
    `attempts_root` mirrors CoolscanPyTransport's own instance attribute so
    service.py's `getattr(transport, "attempts_root", None)` threading can
    be exercised without needing the real transport."""

    def __init__(
        self,
        *,
        preview_thumbnails: int = 2,
        start_scan_raises: Exception | None = None,
        start_scan_returns: domain.ScanSummary | None = None,
        attempts_root: str | None = None,
        progress_slot_sequence: list[int] | None = None,
    ) -> None:
        self.device_open = False
        self.eject_called = False
        self._preview_thumbnails = preview_thumbnails
        self._start_scan_raises = start_scan_raises
        self._start_scan_returns = start_scan_returns
        self.attempts_root = attempts_root
        # When set, on_progress fires once per slot in this exact order
        # before start_scan raises/returns -- lets a test prove
        # current_fail_slot() attribution for an exception that carries no
        # slot of its own.
        self._progress_slot_sequence = progress_slot_sequence or []

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
        self.device_open = False

    def preview(self, material, slots, on_thumbnail):
        for i in range(self._preview_thumbnails):
            on_thumbnail(_thumbnail(i + 1))
        return domain.PreviewResult(count=self._preview_thumbnails, fingerprint="stub-fp")

    def approve(self, slot: int) -> None:
        pass

    def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
        for i, slot in enumerate(self._progress_slot_sequence):
            on_progress(
                domain.ScanProgress(
                    job_id="", slot=slot, ordinal=i,
                    total_slots=len(self._progress_slot_sequence), fraction=0.0, message="",
                )
            )
        if self._start_scan_raises is not None:
            raise self._start_scan_raises
        if self._start_scan_returns is not None:
            return self._start_scan_returns
        return domain.ScanSummary(completed=tuple(slots), failed=(), stopped=False)

    def request_stop(self) -> None:
        pass

    def eject(self) -> bool:
        self.eject_called = True
        return True


def _wire_recipe() -> dict:
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
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for(lambda: not svc._lane_held)
    _wait_for(lambda: not svc._motion_op_active)


def _arm(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_text("junk-roll")


class _RecordingEmit:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._events: list[tuple[str, dict]] = []

    def __call__(self, event: str, payload: dict) -> None:
        with self._lock:
            self._events.append((event, payload))

    def names(self) -> list[str]:
        with self._lock:
            return [e for e, _p in self._events]

    def payloads_of(self, event: str) -> list[dict]:
        with self._lock:
            return [p for e, p in self._events if e == event]

    def payload_of(self, event: str) -> dict:
        return self.payloads_of(event)[0]

    def has(self, event: str) -> bool:
        return event in self.names()


def _read_telemetry(base_dir: Path, session_id: str) -> list[dict]:
    path = base_dir / "hw-telemetry" / f"{session_id}.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def _driven_service(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, transport: _StubTransport
) -> tuple[service.BridgeService, safety.TelemetryLog, _RecordingEmit]:
    _arm(monkeypatch, tmp_path)
    telemetry = safety.TelemetryLog(tmp_path)
    svc = service.BridgeService(transport, telemetry, base_dir=tmp_path)
    svc.dispatch(
        {"id": 0, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
        lambda *_a: None,
    )
    svc.dispatch(
        {"id": 1, "method": "device.open", "params": {"deviceId": _DEVICE_ID}}, lambda *_a: None
    )
    emit = _RecordingEmit()
    svc.dispatch({"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit)
    _wait_for_preview_complete_and_lane_free(svc, emit)
    return svc, telemetry, emit


def _start_scan(svc: service.BridgeService, tmp_path: Path, emit: _RecordingEmit, slots: list[int]) -> str:
    result = svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {
                "slots": slots,
                "recipe": _wire_recipe(),
                "output": {
                    "destination": str(tmp_path / "out"),
                    "filenameTemplate": "frame-####.tif",
                },
            },
        },
        emit,
    )
    return result["jobId"]


# -- FrameRetryExhausted: retry-exhaustion path -------------------------------------


def test_frame_retry_exhausted_emits_frame_failed_before_hardware_anomaly_and_completed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = _StubTransport(
        start_scan_raises=FrameRetryExhausted(3, RuntimeError("synthetic transport-smear fault"))
    )
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    job_id = _start_scan(svc, tmp_path, emit, [3])
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert names.index("scan.frameFailed") < names.index("hardware.anomaly")
    assert names.index("hardware.anomaly") < names.index("scan.completed")

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed == {
        "jobId": job_id,
        "slot": 3,
        "code": "TRANSPORT_SMEAR_DETECTED",
        "message": "synthetic transport-smear fault",
    }

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    frame_failed_entries = [e for e in entries if e["method"] == "scan.frameFailed"]
    assert len(frame_failed_entries) == 1
    entry = frame_failed_entries[0]
    assert entry["slot"] == 3
    assert entry["reason_class"] == "RuntimeError"
    assert entry["reason_message"] == "synthetic transport-smear fault"
    assert isinstance(entry["elapsed"], (int, float))
    assert entry["elapsed"] >= 0
    assert entry["job_id"] == job_id


def test_frame_retry_exhausted_with_real_coolscanpy_exception_surfaces_its_class_and_attributes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """last_error is what a real CoolscanPyTransport._scan_one_slot would
    actually put there: a genuine coolscanpy.TransportSmearDetected
    carrying an .assessment -- proves reason_class names the REAL cause
    (not the FrameRetryExhausted wrapper) and that its coolscanpy-specific
    attribute is captured in telemetry."""
    smear = coolscanpy.TransportSmearDetected(
        "stopped-transport smear QC refused",
        assessment=coolscanpy.TransportSmearAssessment(
            verdict="smear",
            start_row=10,
            suffix_rows=5,
            minimum_matches=3,
            tail_median_rms=1.0,
            tail_min_corr=0.9,
            pre_tail_median_rms=1.0,
            texture_span=0.5,
            reason="repeated tail rows detected",
        ),
    )
    transport = _StubTransport(start_scan_raises=FrameRetryExhausted(4, smear))
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [4])
    _wait_for(lambda: emit.has("scan.completed"))

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed["code"] == "TRANSPORT_SMEAR_DETECTED"
    assert frame_failed["message"] == "stopped-transport smear QC refused"

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    entry = next(e for e in entries if e["method"] == "scan.frameFailed")
    assert entry["reason_class"] == "TransportSmearDetected"
    assert entry["reason_message"] == "stopped-transport smear QC refused"
    assert entry["assessment"]["verdict"] == "smear"
    assert entry["assessment"]["startRow"] == 10
    assert entry["assessment"]["tailMedianRms"] == 1.0


# -- BridgeError: a translated coolscanpy exception, chained -----------------------


def test_bridge_error_with_chained_coolscanpy_exception_surfaces_its_real_class(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The real shape CoolscanPyTransport produces: `raise
    BridgeError(FINGERPRINT_REFUSED, str(exc)) from exc`. reason_class must
    be the ORIGINAL coolscanpy exception's class ("FingerprintRefused"),
    not the generic "BridgeError" wrapper -- recovered via __cause__."""
    comparison = coolscanpy.FingerprintComparison(
        matches=False,
        reason="a different roll is now loaded",
        compared_frames=12,
        visual_median_hamming=8.5,
        visual_p90_hamming=14,
        frame_start_median_delta_rows=3.0,
        frame_start_max_delta_rows=6,
    )
    original = coolscanpy.FingerprintRefused(
        "fresh transport read disagreed with the reviewed fingerprint",
        comparison=comparison,
    )
    bridge_error = BridgeError(ErrorCode.FINGERPRINT_REFUSED, str(original))
    bridge_error.__cause__ = original

    transport = _StubTransport(start_scan_raises=bridge_error)
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    job_id = _start_scan(svc, tmp_path, emit, [2])
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert names.index("scan.frameFailed") < names.index("scan.error")
    assert names.index("scan.error") < names.index("scan.completed")

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed["jobId"] == job_id
    assert frame_failed["slot"] == 2
    assert frame_failed["code"] == "FINGERPRINT_REFUSED"
    assert frame_failed["message"] == str(original)

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    entry = next(e for e in entries if e["method"] == "scan.frameFailed")
    assert entry["reason_class"] == "FingerprintRefused"
    assert entry["comparison"]["matches"] is False
    assert entry["comparison"]["comparedFrames"] == 12
    assert entry["comparison"]["visualMedianHamming"] == 8.5

    # Deliverable 1's `reasons: {slot: reason_class}` on the scan.start
    # closure -- "keeps its shape" (job_id, code) but gains this field.
    closure_entries = [
        e for e in entries if e["method"] == "scan.start" and e["outcome"] == "error"
    ]
    assert len(closure_entries) == 1
    assert closure_entries[0]["code"] == "FINGERPRINT_REFUSED"
    # JSONL round-trip always yields string keys for a JSON object.
    assert closure_entries[0]["reasons"] == {"2": "FingerprintRefused"}


def test_bridge_error_without_a_chained_cause_uses_bridge_error_itself_as_reason(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A bridge-native BridgeError (e.g. INVALID_PARAMS from a
    path-traversal check) has no __cause__ to recover -- reason_class must
    fall back to "BridgeError" itself rather than crash or fabricate one."""
    transport = _StubTransport(
        start_scan_raises=BridgeError(ErrorCode.REFEED_REQUIRED, "pull the strip and reinsert it")
    )
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [1])
    _wait_for(lambda: emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    entry = next(e for e in entries if e["method"] == "scan.frameFailed")
    assert entry["reason_class"] == "BridgeError"
    assert entry["reason_message"] == "pull the strip and reinsert it"


def test_bridge_error_names_the_first_pending_slot_not_the_last_on_progress_slot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """2026-07-25 incident: a live 33-slot batch ([4..36]) failed with a
    pre-frame RollMismatch (scan_many raised before yielding any frame) and
    scan.frameFailed reported slot 36 -- the LAST slot on_progress had
    fired for -- instead of slot 4, the actually-affected frame.
    first_pending_slot() replaces the old on_progress-based
    current_fail_slot(): CoolscanPyTransport.start_scan emits on_progress
    for every requested slot up front, in one pass, before scan_many is
    ever invoked (it exposes no per-slot pre-attempt hook), so "the last
    slot on_progress fired for" is always the batch's LAST slot, never the
    slot actually in flight -- proved here with the same
    progress_slot_sequence=[5, 6, 7] shape (on_progress fires for every
    slot before start_scan_raises), asserting the FIRST pending slot (5),
    tagged with the "batch-pre-frame" attribution qualifier since all 3
    requested slots were equally unresolved when the exception hit."""
    transport = _StubTransport(
        progress_slot_sequence=[5, 6, 7],
        start_scan_raises=BridgeError(ErrorCode.GEOMETRY_VALIDATION_ERROR, "shape mismatch"),
    )
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [5, 6, 7])
    _wait_for(lambda: emit.has("scan.completed"))

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed["slot"] == 5
    assert frame_failed["attribution"] == "batch-pre-frame"

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    entry = next(e for e in entries if e["method"] == "scan.frameFailed")
    assert entry["slot"] == 5
    assert entry["attribution"] == "batch-pre-frame"


def test_bridge_error_single_slot_batch_gets_no_attribution_qualifier(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A single-slot batch has exactly one pending candidate -- naming it
    is not a guess (matches FrameRetryExhausted's own unqualified
    `remaining[0]` convention elsewhere), so no "attribution" field should
    be added; every pre-existing single-slot assertion in this file must
    keep seeing the same 4-key wire payload it always has."""
    transport = _StubTransport(
        progress_slot_sequence=[5, 6, 7],
        start_scan_raises=BridgeError(ErrorCode.GEOMETRY_VALIDATION_ERROR, "shape mismatch"),
    )
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [5])
    _wait_for(lambda: emit.has("scan.completed"))

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed == {
        "jobId": frame_failed["jobId"],
        "slot": 5,
        "code": "GEOMETRY_VALIDATION_ERROR",
        "message": "shape mismatch",
    }
    assert "attribution" not in frame_failed


def test_bridge_error_names_first_unresolved_slot_after_some_frames_completed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """When on_frame already fired for some slots before the terminal
    exception, first_pending_slot() must skip those resolved slots and
    name the first slot that is still actually pending -- not just
    slots[0] of the original request."""

    class _PartialProgressTransport(_StubTransport):
        def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
            for i, slot in enumerate(self._progress_slot_sequence):
                on_progress(
                    domain.ScanProgress(
                        job_id="", slot=slot, ordinal=i,
                        total_slots=len(self._progress_slot_sequence), fraction=0.0, message="",
                    )
                )
            # Slot 5 resolves normally before the batch fails on the rest.
            on_frame(5, _stub_receipt(5))
            raise self._start_scan_raises

    transport = _PartialProgressTransport(
        progress_slot_sequence=[5, 6, 7],
        start_scan_raises=BridgeError(ErrorCode.GEOMETRY_VALIDATION_ERROR, "shape mismatch"),
    )
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [5, 6, 7])
    _wait_for(lambda: emit.has("scan.completed"))

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed["slot"] == 6
    assert frame_failed["attribution"] == "batch-pre-frame"


# -- generic Exception: unexpected transport bug ------------------------------------


def test_generic_exception_surfaces_its_own_class_with_internal_code(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = _StubTransport(start_scan_raises=RuntimeError("unexpected transport bug"))
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [1])
    _wait_for(lambda: emit.has("scan.completed"))

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed["code"] == "INTERNAL"
    assert frame_failed["message"] == "unexpected transport bug"

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    entry = next(e for e in entries if e["method"] == "scan.frameFailed")
    assert entry["reason_class"] == "RuntimeError"

    closure_entries = [
        e for e in entries if e["method"] == "scan.start" and e["outcome"] == "error"
    ]
    assert closure_entries[0]["code"] == "INTERNAL"
    assert "reasons" in closure_entries[0]


# -- ManualReviewRequired-sourced ScanSummary.failure_reasons (coordinator #1) ------


def test_manual_review_required_summary_reason_emits_frame_failed_on_the_ok_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The exact real shape CoolscanPyTransport.start_scan now returns for
    a ManualReviewRequired skip (see test_transport_coolscanpy.py's own
    coverage of that translation) -- this test proves service.py's worker
    correctly turns THAT into a scan.frameFailed event/telemetry entry
    instead of a silent, unexplained failed[] slot, on the "ok" (no
    exception raised) path."""
    summary = domain.ScanSummary(
        completed=(2,),
        failed=(1,),
        stopped=False,
        failure_reasons={
            1: {
                "reason_class": "ManualReviewRequired",
                "reason_message": "frame 1 transport origin requires manual review",
                "code": "MANUAL_REVIEW_REQUIRED",
            }
        },
    )
    transport = _StubTransport(start_scan_returns=summary)
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    job_id = _start_scan(svc, tmp_path, emit, [1, 2])
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert names.index("scan.frameFailed") < names.index("scan.completed")
    assert "scan.error" not in names, "an ok-path per-slot skip must not fabricate scan.error"
    assert "hardware.anomaly" not in names

    frame_failed = emit.payload_of("scan.frameFailed")
    assert frame_failed == {
        "jobId": job_id,
        "slot": 1,
        "code": "MANUAL_REVIEW_REQUIRED",
        "message": "frame 1 transport origin requires manual review",
    }

    completed_summary = emit.payload_of("scan.completed")["summary"]
    assert completed_summary["completed"] == [2]
    assert completed_summary["failed"] == [1]
    # failure_reasons must never leak onto the wire -- BRIDGE.md's
    # documented {completed, failed, stopped} shape only.
    assert set(completed_summary.keys()) == {"completed", "failed", "stopped"}

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    frame_failed_entries = [e for e in entries if e["method"] == "scan.frameFailed"]
    assert len(frame_failed_entries) == 1
    assert frame_failed_entries[0]["reason_class"] == "ManualReviewRequired"

    ok_entries = [e for e in entries if e["method"] == "scan.start" and e["outcome"] == "ok"]
    assert len(ok_entries) == 1
    assert ok_entries[0]["reasons"] == {"1": "ManualReviewRequired"}


def test_scan_start_ok_closure_has_no_reasons_key_when_nothing_failed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = _StubTransport()
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [1])
    _wait_for(lambda: emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    ok_entry = next(e for e in entries if e["method"] == "scan.start" and e["outcome"] == "ok")
    assert "reasons" not in ok_entry
    assert "scan.frameFailed" not in [e["method"] for e in entries]


# -- attempts_root threading into the scan.start telemetry closure (coordinator #2) -


def test_attempts_root_is_included_in_scan_start_closures_when_the_transport_has_one(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake_root = str(tmp_path / "coolscanpy-attempts" / "abc123")
    transport = _StubTransport(attempts_root=fake_root)
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [1])
    _wait_for(lambda: emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    ok_entry = next(e for e in entries if e["method"] == "scan.start" and e["outcome"] == "ok")
    assert ok_entry["attempts_root"] == fake_root


def test_attempts_root_is_included_on_the_error_closure_too(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake_root = str(tmp_path / "coolscanpy-attempts" / "def456")
    transport = _StubTransport(
        attempts_root=fake_root,
        start_scan_raises=RuntimeError("unexpected transport bug"),
    )
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [1])
    _wait_for(lambda: emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    error_entry = next(
        e for e in entries if e["method"] == "scan.start" and e["outcome"] == "error"
    )
    assert error_entry["attempts_root"] == fake_root


def test_no_attempts_root_key_when_the_transport_has_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """MockTransport has no attempts_root concept at all -- the field must
    be omitted, not present-as-null."""
    transport = _StubTransport(attempts_root=None)
    svc, telemetry, emit = _driven_service(tmp_path, monkeypatch, transport)
    _start_scan(svc, tmp_path, emit, [1])
    _wait_for(lambda: emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    ok_entry = next(e for e in entries if e["method"] == "scan.start" and e["outcome"] == "ok")
    assert "attempts_root" not in ok_entry
