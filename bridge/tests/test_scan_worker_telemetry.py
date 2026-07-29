"""Tests for the scan worker's call-boundary telemetry and soft timeout
(Plan 10-04, nikon-coolscan4-software-archaeology
.planning/phases/10-real-capture/LIVE-VERIFICATION-20260723.md: a real
fine-scan job's worker entered its CoolscanPy call path and never
returned, with no diagnostic and no watchdog). Drives BridgeService
in-process (mirrors test_end_to_end.py's own approach) against a real
MockTransport for the normal-telemetry path, and a small hand-written
hangable double for the soft-timeout path -- the timeout value needs to be
tiny and deterministic, which a real Transport's own timing can't
guarantee. Every test uses tmp_path as safety's base_dir, never the real
~/.scanstudio (see safety.py's own module docstring).
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from scanstudio_bridge import domain, safety, service
from scanstudio_bridge.transport.mock import MockTransport

_DEVICE_ID = "hanging-ls5000-0"
_MOCK_DEVICE_ID = "mock-ls5000-0"


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


def _output(tmp_path: Path, name: str = "out") -> dict:
    return {"destination": str(tmp_path / name), "filenameTemplate": "frame-####.tif"}


def _arm(monkeypatch: pytest.MonkeyPatch, base_dir: Path) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    base_dir.mkdir(parents=True, exist_ok=True)
    (base_dir / "hw-motion-armed").write_text("junk-roll")


def _wait_for(predicate, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pytest.fail("condition not met within timeout")


def _wait_for_preview_complete_and_lane_free(
    svc: service.BridgeService, emit: "_RecordingEmit"
) -> None:
    """roll.previewComplete is emitted before that same worker's `finally`
    block actually releases the lane -- waiting for the event alone risks
    a following scan.start's own HardwareLane.__enter__() spuriously
    observing HARDWARE_LANE_BUSY (see test_service_dispatch.py's identical
    helper/comment)."""
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for(lambda: not svc._lane_held)


def _read_telemetry(base_dir: Path, session_id: str) -> list[dict]:
    path = base_dir / "hw-telemetry" / f"{session_id}.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


class _RecordingEmit:
    """Thread-safe emit() collector shared between the dispatching test
    thread and BridgeService's worker/watchdog threads."""

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

    def has(self, event: str) -> bool:
        return event in self.names()


class _HangingTransport:
    """Hand-written Transport double whose start_scan calls
    on_call("enter", ...) for the one slot requested, then blocks on a
    real threading.Event until released -- simulates a CoolscanPy call
    that enters and never returns (LIVE-VERIFICATION-20260723.md's own
    diagnosis), without actually hanging the test process. Only the
    methods the soft-timeout test path actually exercises are
    implemented; satisfies transport.Transport structurally."""

    def __init__(self) -> None:
        self._connected = False
        self.entered = threading.Event()
        self.release = threading.Event()

    def list_devices(self) -> list[domain.DeviceInfo]:
        return [self._device_info()]

    def open_device(self, device_id: str) -> domain.DeviceInfo:
        self._connected = True
        return self._device_info()

    def status(self) -> domain.DeviceStatus:
        return domain.DeviceStatus(
            connected=self._connected,
            device_id=_DEVICE_ID if self._connected else None,
            preview_established=False,
            slot_count=None,
            active_job_id=None,
            lane_held=False,
            motion_armed=False,
            film_present=None,
        )

    def close_device(self) -> None:
        self._connected = False

    def preview(self, material, slots, on_thumbnail):
        return domain.PreviewResult(count=0, fingerprint="fake-hang-fp")

    def approve(self, slot: int) -> None:
        pass

    def start_scan(self, slots, recipe, output, on_progress, on_retry, on_frame, on_call=None):
        slot = slots[0]
        on_progress(
            domain.ScanProgress(
                job_id="",
                slot=slot,
                ordinal=0,
                total_slots=len(slots),
                fraction=0.0,
                message="entering the stuck call",
            )
        )
        call_name = f"roll.scan:slot{slot}"
        if on_call is not None:
            on_call("enter", call_name, None)
        self.entered.set()
        # Bounded so a bug that never sets .release can't hang the test
        # suite itself -- the soft timeout under test is what's actually
        # supposed to end this wait from the SERVICE's perspective; this
        # bound is only a last-resort safety net for the test process.
        released = self.release.wait(timeout=10.0)
        if not released:
            raise AssertionError("_HangingTransport was never released by its test")
        # Reaching here proves the call was never killed/aborted -- only
        # ever ignored by the watchdog -- it can still complete normally.
        if on_call is not None:
            on_call("exit", call_name, 0.0)
        return domain.ScanSummary(completed=tuple(slots), failed=(), stopped=False)

    def request_stop(self) -> None:
        pass

    def eject(self) -> bool:
        return True

    def _device_info(self) -> domain.DeviceInfo:
        return domain.DeviceInfo(
            device_id=_DEVICE_ID,
            vendor="Nikon",
            model="SUPER COOLSCAN 5000 ED (fake-hang)",
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


# -- normal scan: call-boundary telemetry present -----------------------------------


def test_scan_worker_emits_call_boundary_telemetry_for_a_normal_scan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _arm(monkeypatch, tmp_path)
    transport = MockTransport(slot_count=1)
    telemetry = safety.TelemetryLog(tmp_path)
    svc = service.BridgeService(transport, telemetry, base_dir=tmp_path)
    svc.dispatch(
        {"id": 0, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
        lambda *_a: None,
    )
    svc.dispatch(
        {"id": 1, "method": "device.open", "params": {"deviceId": _MOCK_DEVICE_ID}},
        lambda *_a: None,
    )
    preview_emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, preview_emit
    )
    _wait_for_preview_complete_and_lane_free(svc, preview_emit)

    scan_emit = _RecordingEmit()
    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {"slots": [1], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        scan_emit,
    )
    _wait_for(lambda: scan_emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    scan_call_entries = [e for e in entries if e["method"] == "scan.call"]
    assert scan_call_entries, f"expected scan.call telemetry entries, found none in: {entries}"

    pairs = {(e["call"], e["outcome"]) for e in scan_call_entries}

    def has_pair(call_name: str) -> bool:
        return (call_name, "enter") in pairs and (call_name, "exit") in pairs

    assert has_pair("mock.scan:slot1"), scan_call_entries
    assert has_pair("file_write.rgb:slot1"), scan_call_entries
    assert has_pair("file_write.ir:slot1"), scan_call_entries
    assert has_pair("file_write.meter:slot1"), scan_call_entries

    for entry in scan_call_entries:
        if entry["outcome"] == "enter":
            assert entry["elapsed_seconds"] is None, (
                f"an 'enter' entry must never carry an elapsed_seconds -- nothing has "
                f"elapsed yet: {entry}"
            )
        elif entry["outcome"] == "exit":
            assert isinstance(entry["elapsed_seconds"], (int, float)), entry
            assert entry["elapsed_seconds"] >= 0, entry


# -- normal scan: scan.phase-boundary telemetry (Plan 10-09 deliverable 2) ----------


def test_scan_worker_emits_phase_boundary_telemetry_for_a_normal_scan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`scan.phase` is a NEW, additive telemetry method (Plan 10-09) --
    layered alongside `scan.call` (Plan 10-04, unchanged, still asserted by
    test_scan_worker_emits_call_boundary_telemetry_for_a_normal_scan
    above), never replacing it. Each of the four scan.phase boundaries
    MockTransport genuinely exposes (fine_scan:slot{N}, and each of the
    three file writes) must show a full enter/exit pair with a real
    elapsed_seconds on exit -- identical contract to scan.call's own."""
    _arm(monkeypatch, tmp_path)
    transport = MockTransport(slot_count=1)
    telemetry = safety.TelemetryLog(tmp_path)
    svc = service.BridgeService(transport, telemetry, base_dir=tmp_path)
    svc.dispatch(
        {"id": 0, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
        lambda *_a: None,
    )
    svc.dispatch(
        {"id": 1, "method": "device.open", "params": {"deviceId": _MOCK_DEVICE_ID}},
        lambda *_a: None,
    )
    preview_emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, preview_emit
    )
    _wait_for_preview_complete_and_lane_free(svc, preview_emit)

    scan_emit = _RecordingEmit()
    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {"slots": [1], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        scan_emit,
    )
    _wait_for(lambda: scan_emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    scan_phase_entries = [e for e in entries if e["method"] == "scan.phase"]
    assert scan_phase_entries, f"expected scan.phase telemetry entries, found none in: {entries}"

    pairs = {(e["call"], e["outcome"]) for e in scan_phase_entries}

    def has_pair(call_name: str) -> bool:
        return (call_name, "enter") in pairs and (call_name, "exit") in pairs

    assert has_pair("fine_scan:slot1"), scan_phase_entries
    assert has_pair("file_write.rgb:slot1"), scan_phase_entries
    assert has_pair("file_write.ir:slot1"), scan_phase_entries
    assert has_pair("file_write.meter:slot1"), scan_phase_entries

    for entry in scan_phase_entries:
        if entry["outcome"] == "enter":
            assert entry["elapsed_seconds"] is None, entry
        elif entry["outcome"] == "exit":
            assert isinstance(entry["elapsed_seconds"], (int, float)), entry
            assert entry["elapsed_seconds"] >= 0, entry
            assert entry["call_outcome"] == "return", entry

    # Ordering: the fine-scan phase for a slot must fully close (exit)
    # before that same slot's file-write phases begin (enter) -- the
    # transport scans the frame, then writes it; scan.phase must reflect
    # that sequencing, not report it as concurrent/interleaved.
    fine_scan_exit_ts = next(
        e["timestamp"]
        for e in scan_phase_entries
        if e["call"] == "fine_scan:slot1" and e["outcome"] == "exit"
    )
    rgb_write_enter_ts = next(
        e["timestamp"]
        for e in scan_phase_entries
        if e["call"] == "file_write.rgb:slot1" and e["outcome"] == "enter"
    )
    assert fine_scan_exit_ts <= rgb_write_enter_ts

    # scan.call granularity (Plan 10-04) is untouched by this addition --
    # both methods coexist for the file-write boundaries (phased_call tags
    # the identical span as both), and fine_scan:slot{N} has no scan.call
    # sibling of its own (mock.scan:slot{N} remains scan.call-only, mirroring
    # CoolscanPyTransport's roll.scan:slot{N}).
    scan_call_names = {e["call"] for e in entries if e["method"] == "scan.call"}
    assert "mock.scan:slot1" in scan_call_names
    assert "fine_scan:slot1" not in scan_call_names


def test_scan_worker_frame_retry_exhausted_emits_raise_outcome_on_call_boundary_exit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Raise-aware call telemetry (Plan 10-09, coordinator scope addition
    #3): the mock.scan:slot{N} scan.call boundary for the FINAL (permanently
    failing) attempt exits via a raise, distinctly from every earlier
    successful-return exit -- MockTransport's mock.scan:slot{N} call itself
    never raises (it's a synthetic no-op), so this instead proves the
    OUTER fine_scan:slot{N} scan.phase boundary -- which wraps
    _run_one_slot, the thing that actually raises FrameRetryExhausted --
    correctly reports call_outcome="raise" with exception_class
    "FrameRetryExhausted"."""
    _arm(monkeypatch, tmp_path)
    transport = MockTransport(slot_count=6, permanent_fault_slots={4})
    telemetry = safety.TelemetryLog(tmp_path)
    svc = service.BridgeService(transport, telemetry, base_dir=tmp_path)
    svc.dispatch(
        {"id": 0, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
        lambda *_a: None,
    )
    svc.dispatch(
        {"id": 1, "method": "device.open", "params": {"deviceId": _MOCK_DEVICE_ID}},
        lambda *_a: None,
    )
    preview_emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, preview_emit
    )
    _wait_for_preview_complete_and_lane_free(svc, preview_emit)

    scan_emit = _RecordingEmit()
    svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {"slots": [4], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        scan_emit,
    )
    _wait_for(lambda: scan_emit.has("scan.completed"))

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    phase_exit = next(
        e
        for e in entries
        if e["method"] == "scan.phase"
        and e["call"] == "fine_scan:slot4"
        and e["outcome"] == "exit"
    )
    assert phase_exit["call_outcome"] == "raise"
    assert phase_exit["exception_class"] == "FrameRetryExhausted"


# -- soft timeout: scan.error + telemetry, worker never touched ---------------------


def test_scan_worker_soft_timeout_emits_scan_error_and_telemetry_without_touching_worker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SCANSTUDIO_BRIDGE_SCAN_TIMEOUT", "0.2")
    _arm(monkeypatch, tmp_path)
    transport = _HangingTransport()
    telemetry = safety.TelemetryLog(tmp_path)
    svc = service.BridgeService(transport, telemetry, base_dir=tmp_path)
    svc.dispatch(
        {"id": 0, "method": "bridge.hello", "params": {"clientName": "test", "protocolVersion": 1}},
        lambda *_a: None,
    )
    svc.dispatch(
        {"id": 1, "method": "device.open", "params": {"deviceId": _DEVICE_ID}}, lambda *_a: None
    )
    preview_emit = _RecordingEmit()
    svc.dispatch(
        {"id": 2, "method": "roll.preview", "params": {"material": "colorNegative"}}, preview_emit
    )
    _wait_for_preview_complete_and_lane_free(svc, preview_emit)

    scan_emit = _RecordingEmit()
    result = svc.dispatch(
        {
            "id": 3,
            "method": "scan.start",
            "params": {"slots": [1], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        scan_emit,
    )
    job_id = result["jobId"]

    assert transport.entered.wait(timeout=2.0), "the fake transport's stuck call never entered"

    # Configured to 0.2s -- wait comfortably past that for the watchdog to
    # poll, detect, and report. This must resolve in well under the bound
    # below, not merely within it, or the watchdog isn't actually catching
    # the short deadline.
    _wait_for(lambda: scan_emit.has("scan.error"), timeout=3.0)

    error_payload = scan_emit.payload_of("scan.error")
    assert error_payload["jobId"] == job_id
    assert error_payload["code"] == "INTERNAL"
    assert "roll.scan:slot1" in error_payload["message"], error_payload
    assert "power-cycle" in error_payload["message"].lower(), error_payload

    entries = _read_telemetry(tmp_path, telemetry.session_id)
    scan_call_entries = [e for e in entries if e["method"] == "scan.call"]
    assert any(
        e["outcome"] == "enter" and e["call"] == "roll.scan:slot1" for e in scan_call_entries
    ), scan_call_entries
    assert any(
        e["outcome"] == "timeout" and e["call"] == "roll.scan:slot1" for e in scan_call_entries
    ), scan_call_entries
    assert not any(
        e["outcome"] == "exit" and e["call"] == "roll.scan:slot1" for e in scan_call_entries
    ), "the stuck call must show no 'exit' entry while it is still genuinely in flight"

    # The no-kill proof (this test's whole point): the job is still not
    # terminal -- the worker thread is genuinely still blocked inside
    # _HangingTransport.start_scan, not killed or abandoned. Releasing the
    # fake transport's own block now lets that exact same call finish
    # completely normally afterward, proving nothing about it was ever
    # touched -- only ever ignored by the watchdog above.
    assert svc._last_job["terminal"] is False, "the watchdog must never mark the job terminal itself"
    transport.release.set()
    _wait_for(lambda: scan_emit.has("scan.completed"), timeout=3.0)
    completed_summary = scan_emit.payload_of("scan.completed")["summary"]
    assert completed_summary["completed"] == [1], completed_summary

    # A late "exit" telemetry entry now exists for the same call, proving
    # the very call the watchdog reported "timeout" for did eventually
    # return on its own -- never killed, never aborted.
    late_entries = _read_telemetry(tmp_path, telemetry.session_id)
    late_scan_call_entries = [e for e in late_entries if e["method"] == "scan.call"]
    assert any(
        e["outcome"] == "exit" and e["call"] == "roll.scan:slot1" for e in late_scan_call_entries
    ), late_scan_call_entries
