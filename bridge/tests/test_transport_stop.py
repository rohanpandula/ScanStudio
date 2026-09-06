"""Cancellation through real Device/Roll; only capture dispatch is substituted."""

import threading
from types import SimpleNamespace

import coolscanpy
import pytest
from coolscanpy.roll.preview_session import build_roll_preview_session

from scanstudio_bridge import domain, safety, service
from scanstudio_bridge.protocol import BridgeError, ErrorCode, to_wire
from scanstudio_bridge.transport.coolscanpy_transport import (
    CoolscanPyTransport,
    _reconstruct_preview_attempt,
)
from tests.test_transport_coolscanpy import _fake_device_info, _write_synthetic_preview_attempt
from tests.test_service_dispatch import _arm


@pytest.fixture
def real_transport(tmp_path, monkeypatch):
    monkeypatch.setattr("usb.core.find", lambda **_: pytest.fail("physical USB access"))
    device = coolscanpy.Device(_fake_device_info(), object())
    transport = CoolscanPyTransport()
    transport._device = device
    roll = device.roll(attempts_root=tmp_path / "attempts")
    transport._roll = roll
    attempt_dir = _write_synthetic_preview_attempt(tmp_path / "preview")
    session = build_roll_preview_session(_reconstruct_preview_attempt(attempt_dir / "journal.json"))
    roll.install_manual_session(session)
    for slot in (1, 2):
        if roll.needs_approval(slot):
            roll.approve(slot)
    transport._material = domain.Material.COLOR_NEGATIVE
    transport._preview_established = True
    dispatched = []
    def capture(*args, **kwargs):
        dispatched.append(True)
        raise coolscanpy.SafeStopRequested("test capture boundary")
    roll._adapter = SimpleNamespace(run_batch_session=capture)
    yield transport, roll, dispatched
    transport.close_device()


def scan(transport, tmp_path, **callbacks):
    return transport.start_scan(
        [1, 2], domain.FIXED_COLOR_NEGATIVE_RECIPE,
        domain.OutputSpec(destination=str(tmp_path / "out"), filename_template="frame-####.tif"),
        on_progress=callbacks.get("on_progress", lambda _: None),
        on_retry=lambda *a: None, on_frame=lambda *a: None,
        on_call=callbacks.get("on_call"),
    )


@pytest.mark.parametrize("boundary", ["progress", "reservation"])
def test_stop_survives_real_driver_reservation(real_transport, tmp_path, monkeypatch, boundary):
    transport, roll, dispatched = real_transport
    callbacks = {}
    if boundary == "progress":
        callbacks["on_progress"] = lambda _: transport.request_stop()
    else:
        reserve = roll._reserve_batch_locked
        def stop_then_reserve(iterator):
            transport.request_stop()
            return reserve(iterator)
        monkeypatch.setattr(roll, "_reserve_batch_locked", stop_then_reserve)
    assert scan(transport, tmp_path, **callbacks).stopped
    assert dispatched == []
    assert not roll._device._lock.locked()


@pytest.mark.parametrize("refusal", ["manual", "table"])
def test_stop_prevents_retry_dispatch(real_transport, tmp_path, monkeypatch, refusal):
    transport, roll, dispatched = real_transport
    scan_many = roll.scan_many
    calls = []
    def refuse_once(*args, **kwargs):
        calls.append(True)
        if len(calls) == 1:
            transport.request_stop()
            if refusal == "manual":
                raise coolscanpy.ManualReviewRequired("review slot 2", slot=2)
            raise coolscanpy.RollMismatch("requested frame 2 is outside the scanner-addressable table 1..1")
        return scan_many(*args, **kwargs)
    monkeypatch.setattr(roll, "scan_many", refuse_once)
    assert scan(transport, tmp_path).stopped
    assert calls == [True]
    assert dispatched == []


def test_completed_job_stop_cannot_poison_next_job(real_transport, tmp_path):
    transport, _, dispatched = real_transport
    assert scan(transport, tmp_path, on_progress=lambda _: transport.request_stop()).stopped
    transport.request_stop()  # Old job has finished; its terminal event may still be pending.
    assert scan(transport, tmp_path).stopped
    assert dispatched == [True]


@pytest.mark.parametrize("ending", ["stop", "shutdown"])
def test_service_cancels_before_transport_worker_entry(real_transport, tmp_path, monkeypatch, ending):
    transport, _, dispatched = real_transport
    _arm(monkeypatch, tmp_path)
    svc = service.BridgeService(transport, safety.TelemetryLog(tmp_path), base_dir=tmp_path)
    svc._device_open = True
    svc._preview_material = domain.Material.COLOR_NEGATIVE
    entered, proceed = threading.Event(), threading.Event()
    start_scan = transport.start_scan
    def delayed_start(*args, **kwargs):
        entered.set()
        assert proceed.wait(10)
        return start_scan(*args, **kwargs)
    monkeypatch.setattr(transport, "start_scan", delayed_start)
    emitted = []
    result = svc._handle_scan_start({"params": {
        "slots": [1, 2], "recipe": to_wire(domain.FIXED_COLOR_NEGATIVE_RECIPE),
        "output": {"destination": str(tmp_path / "out"), "filenameTemplate": "frame-####.tif"},
    }}, lambda name, payload: emitted.append((name, payload)))
    try:
        assert entered.wait(10)
        if ending == "stop":
            assert svc._handle_scan_stop({"params": {"jobId": result["jobId"]}}) == {"acknowledged": True}
        else:
            with pytest.raises(BridgeError) as error:
                svc._handle_shutdown(join_timeout=0)
            assert error.value.code == ErrorCode.HARDWARE_LANE_BUSY
    finally:
        proceed.set()
        svc._last_job["thread"].join(10)
    assert not svc._last_job["thread"].is_alive()
    assert dispatched == []
    completed = [payload for name, payload in emitted if name == "scan.completed"]
    assert len(completed) == 1
    assert completed[0]["summary"]["stopped"] is True
