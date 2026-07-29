"""Full protocol + SAFE-02 integration coverage: drives BridgeService
in-process against a real MockTransport (no subprocess -- the subprocess
path is covered by scripts/smoke_bridge.sh). Every test uses tmp_path as
safety's base_dir (base_dir=tmp_path / ".scanstudio", per Plan 08-02's own
base_dir seam) -- never the real ~/.scanstudio. See BRIDGE.md
(nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md)
for the wire-level contract this suite exercises end to end.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from scanstudio_bridge import safety, service
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport.mock import MockTransport


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


def _wait_for(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pytest.fail("condition not met within timeout")


def _arm(monkeypatch: pytest.MonkeyPatch, base_dir: Path) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    base_dir.mkdir(parents=True, exist_ok=True)
    (base_dir / "hw-motion-armed").write_text("junk-roll")


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

    def has(self, event: str) -> bool:
        return event in self.names()


def _wait_for_idle(svc: service.BridgeService) -> None:
    """Waits until BridgeService's own bookkeeping shows the hardware lane
    free -- roll.previewComplete/scan.completed are emitted from inside a
    worker's `try` block, strictly before that same worker's `finally`
    actually releases the HardwareLane, so a following motion-capable
    dispatch must wait for this, not just the event, to avoid a spurious
    HARDWARE_LANE_BUSY race against the still-finishing prior worker."""
    _wait_for(lambda: not svc._lane_held)


def _hello_open_service(
    tmp_path: Path, transport: MockTransport, emit: _RecordingEmit
) -> tuple[service.BridgeService, Path, str]:
    base_dir = tmp_path / ".scanstudio"
    telemetry = safety.TelemetryLog(base_dir)
    svc = service.BridgeService(transport, telemetry, base_dir=base_dir)

    svc.dispatch(
        {"id": 1, "method": "bridge.hello", "params": {"clientName": "e2e", "protocolVersion": 1}},
        emit,
    )
    devices = svc.dispatch({"id": 2, "method": "device.list"}, emit)
    device_id = devices["devices"][0]["deviceId"]
    svc.dispatch({"id": 3, "method": "device.open", "params": {"deviceId": device_id}}, emit)
    return svc, base_dir, device_id


# -- 1. Full happy path: hello -> ... -> shutdown ------------------------------------


def test_full_happy_path_hello_through_shutdown(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = MockTransport(slot_count=6)
    emit = _RecordingEmit()
    svc, base_dir, _device_id = _hello_open_service(tmp_path, transport, emit)

    _arm(monkeypatch, base_dir)

    preview_result = svc.dispatch(
        {"id": 4, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    assert preview_result == {"accepted": True}
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for_idle(svc)
    assert emit.names().count("roll.thumbnail") == 6
    assert emit.names().count("roll.previewComplete") == 1

    start_result = svc.dispatch(
        {
            "id": 5,
            "method": "scan.start",
            "params": {"slots": [1], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        emit,
    )
    job_id = start_result["jobId"]
    _wait_for(lambda: emit.has("scan.completed"))
    _wait_for_idle(svc)

    frame_completed = emit.payload_of("scan.frameCompleted")
    assert frame_completed["jobId"] == job_id
    assert frame_completed["slot"] == 1
    receipt = frame_completed["receipt"]
    for key in ("exposure", "clipping", "focusDetail", "transportSmear"):
        assert key in receipt, f"receipt missing wire key {key!r}"

    completed = emit.payload_of("scan.completed")
    assert completed["jobId"] == job_id
    assert completed["summary"]["completed"] == [1]
    assert completed["summary"]["failed"] == []
    assert completed["summary"]["stopped"] is False

    eject_result = svc.dispatch({"id": 6, "method": "device.eject"}, emit)
    assert eject_result == {}

    shutdown_result = svc.dispatch({"id": 7, "method": "bridge.shutdown"}, emit)
    assert shutdown_result == {}

    # BRIDGE.md's SAFE-02 "Telemetry" guardrail: every hardware-bound call
    # (roll.preview, scan.start, device.eject) gets a "started" record
    # before the call and an "ok"/outcome record after (T-08-05) -- not
    # just the anomaly-halt path.
    telemetry_files = list((base_dir / "hw-telemetry").glob("*.jsonl"))
    assert len(telemetry_files) == 1
    entries = [json.loads(line) for line in telemetry_files[0].read_text().splitlines()]
    methods_and_outcomes = [(e["method"], e["outcome"]) for e in entries]
    for expected in [
        ("roll.preview", "started"),
        ("roll.preview", "ok"),
        ("scan.start", "started"),
        ("scan.start", "ok"),
        ("device.eject", "started"),
        ("device.eject", "ok"),
    ]:
        assert expected in methods_and_outcomes, f"missing telemetry entry {expected}"


# -- 2. SAFE-02 disarmed then armed --------------------------------------------------


def test_safe02_disarmed_roll_preview_then_succeeds_once_armed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = MockTransport(slot_count=2)
    emit = _RecordingEmit()
    svc, base_dir, _device_id = _hello_open_service(tmp_path, transport, emit)

    events_before_refusal = emit.names()  # device.open above already emitted device.status
    monkeypatch.delenv(safety.HW_MOTION_ENV_VAR, raising=False)
    with pytest.raises(BridgeError) as excinfo:
        svc.dispatch(
            {"id": 4, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
        )
    assert excinfo.value.code == ErrorCode.HW_MOTION_NOT_ARMED
    # No worker thread started for the refused attempt: no new events beyond
    # what device.open had already produced.
    assert emit.names() == events_before_refusal

    _arm(monkeypatch, base_dir)
    result = svc.dispatch(
        {"id": 5, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit
    )
    assert result == {"accepted": True}
    _wait_for(lambda: emit.has("roll.previewComplete"))


# -- 3. Single-lane contention, re-asserted at the BridgeService level ---------------


def test_single_lane_contention_via_two_scan_start_calls(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = MockTransport(slot_count=6)
    setup_emit = _RecordingEmit()
    svc, base_dir, _device_id = _hello_open_service(tmp_path, transport, setup_emit)
    _arm(monkeypatch, base_dir)

    svc.dispatch(
        {"id": 4, "method": "roll.preview", "params": {"material": "colorNegative"}}, setup_emit
    )
    _wait_for(lambda: setup_emit.has("roll.previewComplete"))
    _wait_for_idle(svc)

    # A custom emit that blocks the worker thread mid-slot (inside
    # MockTransport's synchronous on_progress callback) the first time it
    # sees scan.progress -- this keeps the first scan.start's HardwareLane
    # held so the second scan.start below deterministically contends,
    # without needing a second Transport double (Task 3 requires a real
    # MockTransport here).
    started = threading.Event()
    release = threading.Event()
    first_job_emit = _RecordingEmit()

    def blocking_emit(event: str, payload: dict) -> None:
        first_job_emit(event, payload)
        if event == "scan.progress" and not started.is_set():
            started.set()
            release.wait(timeout=2.0)

    svc.dispatch(
        {
            "id": 5,
            "method": "scan.start",
            "params": {"slots": [1], "recipe": _wire_recipe(), "output": _output(tmp_path, "out1")},
        },
        blocking_emit,
    )
    assert started.wait(timeout=2.0), "first job's worker never reached scan.progress"

    try:
        second_emit = _RecordingEmit()
        with pytest.raises(BridgeError) as excinfo:
            svc.dispatch(
                {
                    "id": 6,
                    "method": "scan.start",
                    "params": {
                        "slots": [2],
                        "recipe": _wire_recipe(),
                        "output": _output(tmp_path, "out2"),
                    },
                },
                second_emit,
            )
        assert excinfo.value.code == ErrorCode.HARDWARE_LANE_BUSY
        assert second_emit.names() == []  # contention is synchronous, no worker started
    finally:
        release.set()
        _wait_for(lambda: first_job_emit.has("scan.completed"))


# -- 4. Retry-then-succeed -----------------------------------------------------------


def test_retry_then_succeed_emits_one_frame_retrying_then_frame_completed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = MockTransport(slot_count=6, fault_script={3: 1})
    emit = _RecordingEmit()
    svc, base_dir, _device_id = _hello_open_service(tmp_path, transport, emit)
    _arm(monkeypatch, base_dir)

    svc.dispatch({"id": 4, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit)
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for_idle(svc)

    svc.dispatch(
        {
            "id": 5,
            "method": "scan.start",
            "params": {"slots": [3], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert names.count("scan.frameRetrying") == 1
    assert names.count("scan.frameCompleted") == 1
    assert names.index("scan.frameRetrying") < names.index("scan.frameCompleted")


# -- 5. Retry-exhausted anomaly halt --------------------------------------------------


def test_retry_exhausted_emits_anomaly_before_completed_and_records_telemetry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = MockTransport(slot_count=6, permanent_fault_slots={4})
    emit = _RecordingEmit()
    svc, base_dir, _device_id = _hello_open_service(tmp_path, transport, emit)
    _arm(monkeypatch, base_dir)

    svc.dispatch({"id": 4, "method": "roll.preview", "params": {"material": "colorNegative"}}, emit)
    _wait_for(lambda: emit.has("roll.previewComplete"))
    _wait_for_idle(svc)

    svc.dispatch(
        {
            "id": 5,
            "method": "scan.start",
            "params": {"slots": [4], "recipe": _wire_recipe(), "output": _output(tmp_path)},
        },
        emit,
    )
    _wait_for(lambda: emit.has("scan.completed"))

    names = emit.names()
    assert names.index("hardware.anomaly") < names.index("scan.completed")
    anomaly = emit.payload_of("hardware.anomaly")
    assert anomaly["code"] == "TRANSPORT_SMEAR_DETECTED"
    assert anomaly["ejected"] is True
    assert anomaly["slot"] == 4

    telemetry_files = list((base_dir / "hw-telemetry").glob("*.jsonl"))
    assert len(telemetry_files) == 1
    lines = telemetry_files[0].read_text().splitlines()
    assert any(json.loads(line)["method"] == "hardware.anomaly" for line in lines)
