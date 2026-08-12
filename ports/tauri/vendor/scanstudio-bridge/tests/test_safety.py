"""Tests for scanstudio_bridge.safety: SAFE-02's armed latch, single
hardware lane, telemetry log, and anomaly-halt helper.

Every test passes pytest's `tmp_path` as `base_dir` -- none of these tests
are permitted to touch the real `~/.scanstudio` (see BRIDGE.md's SAFE-02
guardrails section, nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from scanstudio_bridge import safety
from scanstudio_bridge.protocol import BridgeError, ErrorCode

# -- armed_media / require_armed --------------------------------------------


def test_armed_media_is_none_when_env_var_unset(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv(safety.HW_MOTION_ENV_VAR, raising=False)
    (tmp_path / "hw-motion-armed").write_text("junk-roll")
    assert safety.armed_media(tmp_path) is None


def test_armed_media_is_none_when_latch_file_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    assert safety.armed_media(tmp_path) is None


def test_armed_media_is_none_when_latch_file_empty_or_whitespace(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_text("   \n\t  ")
    assert safety.armed_media(tmp_path) is None


def test_armed_media_is_none_when_latch_is_a_symlink(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    target = tmp_path / "authorization-target"
    target.write_text("scanstudio-app-session")
    (tmp_path / "hw-motion-armed").symlink_to(target)
    assert safety.armed_media(tmp_path) is None


def test_armed_media_does_not_block_when_latch_is_a_fifo(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    latch = tmp_path / "hw-motion-armed"
    os.mkfifo(latch)
    result: list[str | None] = []
    reader = threading.Thread(
        target=lambda: result.append(safety.armed_media(tmp_path)),
        daemon=True,
    )
    reader.start()
    reader.join(timeout=0.25)
    if reader.is_alive():
        # Release a blocking implementation before failing so the test does
        # not strand a thread in the shared pytest process.
        writer = os.open(latch, os.O_WRONLY | os.O_NONBLOCK)
        os.close(writer)
        reader.join(timeout=1)
        pytest.fail("armed_media blocked while opening a FIFO latch")
    assert result == [None]


def test_armed_media_is_none_when_latch_is_not_utf8(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_bytes(b"\xff")
    assert safety.armed_media(tmp_path) is None


def test_armed_media_is_none_when_latch_is_oversized(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_bytes(b"a" * 4097)
    assert safety.armed_media(tmp_path) is None


def test_armed_media_returns_stripped_content_when_armed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_text("  junk-roll  \n")
    assert safety.armed_media(tmp_path) == "junk-roll"


def test_armed_media_is_none_when_env_var_not_exactly_one(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "true")
    (tmp_path / "hw-motion-armed").write_text("junk-roll")
    assert safety.armed_media(tmp_path) is None


def test_require_armed_raises_hw_motion_not_armed_when_not_armed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv(safety.HW_MOTION_ENV_VAR, raising=False)
    with pytest.raises(BridgeError) as excinfo:
        safety.require_armed(tmp_path)
    assert excinfo.value.code == ErrorCode.HW_MOTION_NOT_ARMED


def test_require_armed_returns_media_when_armed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(safety.HW_MOTION_ENV_VAR, "1")
    (tmp_path / "hw-motion-armed").write_text("junk-roll")
    assert safety.require_armed(tmp_path) == "junk-roll"


# -- HardwareLane -------------------------------------------------------------


def test_hardware_lane_second_contender_is_busy_then_third_succeeds_after_release(
    tmp_path: Path,
) -> None:
    first = safety.HardwareLane(tmp_path)
    first.__enter__()
    try:
        second = safety.HardwareLane(tmp_path)
        with pytest.raises(BridgeError) as excinfo:
            second.__enter__()
        assert excinfo.value.code == ErrorCode.HARDWARE_LANE_BUSY
    finally:
        first.__exit__(None, None, None)

    third = safety.HardwareLane(tmp_path)
    third.__enter__()
    third.__exit__(None, None, None)


def test_hardware_lane_works_as_a_context_manager_and_releases_on_exit(
    tmp_path: Path,
) -> None:
    with safety.HardwareLane(tmp_path):
        pass


# -- BridgeProcessOwnership --------------------------------------------------


@pytest.mark.skipif(
    safety.fcntl is None,
    reason="the packaged Windows bridge runs inside WSL; native Windows fails closed",
)
def test_bridge_process_ownership_refuses_a_second_live_bridge(tmp_path: Path) -> None:
    first = safety.BridgeProcessOwnership(tmp_path).acquire()
    try:
        with pytest.raises(BridgeError) as excinfo:
            safety.BridgeProcessOwnership(tmp_path).acquire()
        assert excinfo.value.code == ErrorCode.HARDWARE_LANE_BUSY
    finally:
        first.close()

    replacement = safety.BridgeProcessOwnership(tmp_path).acquire()
    replacement.close()


@pytest.mark.skipif(
    safety.fcntl is None,
    reason="the packaged Windows bridge runs inside WSL; native Windows fails closed",
)
def test_surviving_worker_keeps_replacement_bridge_fenced(tmp_path: Path) -> None:
    owner = safety.BridgeProcessOwnership(tmp_path).acquire()
    worker = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        pass_fds=(owner.fd,),
    )
    owner.close()
    try:
        with pytest.raises(BridgeError) as excinfo:
            safety.BridgeProcessOwnership(tmp_path).acquire()
        assert excinfo.value.code == ErrorCode.HARDWARE_LANE_BUSY
    finally:
        worker.terminate()
        worker.wait(timeout=5)

    replacement = safety.BridgeProcessOwnership(tmp_path).acquire()
    replacement.close()
    # Released -- a fresh lane over the same base_dir can be acquired again.
    with safety.HardwareLane(tmp_path):
        pass


@pytest.mark.skipif(
    safety.fcntl is None,
    reason="fcntl-only; the msvcrt branch is covered by the monkeypatch test",
)
def test_hardware_lane_contention_across_real_processes(tmp_path: Path) -> None:
    # A genuinely separate OS process must fail to acquire the lane while
    # this test process holds it -- proves cross-process contention (flock
    # semantics), not just cross-object contention within one process.
    lane = safety.HardwareLane(tmp_path)
    lane.__enter__()
    try:
        script = (
            "import fcntl, sys\n"
            f"fh = open({str(tmp_path / 'hw-lane.lock')!r}, 'a+')\n"
            "try:\n"
            "    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "except BlockingIOError:\n"
            "    sys.exit(42)\n"
            "sys.exit(0)\n"
        )
        result = subprocess.run([sys.executable, "-c", script], timeout=10)
        assert result.returncode == 42
    finally:
        lane.__exit__(None, None, None)


class _FakeMsvcrt:
    LK_NBLCK = 1
    LK_UNLCK = 0

    def __init__(self) -> None:
        self.calls: list[tuple[int, int, int]] = []

    def locking(self, fd: int, mode: int, nbytes: int) -> None:
        self.calls.append((fd, mode, nbytes))


def test_hardware_lane_uses_msvcrt_branch_when_fcntl_is_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # With fcntl monkeypatched away, the Windows msvcrt branch must be the
    # one selected: locking(LK_NBLCK, 1) on acquire, locking(LK_UNLCK, 1)
    # on release. Real msvcrt semantics only run in actual Windows CI.
    fake_msvcrt = _FakeMsvcrt()
    monkeypatch.setattr(safety, "fcntl", None)
    monkeypatch.setattr(safety, "msvcrt", fake_msvcrt, raising=False)

    lane = safety.HardwareLane(tmp_path)
    lane.__enter__()
    try:
        assert len(fake_msvcrt.calls) == 1
        _fd, mode, nbytes = fake_msvcrt.calls[0]
        assert mode == _FakeMsvcrt.LK_NBLCK
        assert nbytes == 1
    finally:
        lane.__exit__(None, None, None)

    assert len(fake_msvcrt.calls) == 2
    _fd, mode, nbytes = fake_msvcrt.calls[1]
    assert mode == _FakeMsvcrt.LK_UNLCK
    assert nbytes == 1


# -- TelemetryLog ---------------------------------------------------------------


def test_telemetry_log_record_appends_one_valid_json_line(tmp_path: Path) -> None:
    log = safety.TelemetryLog(tmp_path)
    log.record("device.open", "ok", deviceId="mock-ls5000-0")

    telemetry_files = list((tmp_path / "hw-telemetry").glob("*.jsonl"))
    assert len(telemetry_files) == 1

    lines = telemetry_files[0].read_text().splitlines()
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["method"] == "device.open"
    assert parsed["outcome"] == "ok"
    assert parsed["deviceId"] == "mock-ls5000-0"
    assert "timestamp" in parsed


def test_telemetry_log_uses_given_session_id(tmp_path: Path) -> None:
    log = safety.TelemetryLog(tmp_path, session_id="fixed-session")
    log.record("device.status", "ok")
    assert (tmp_path / "hw-telemetry" / "fixed-session.jsonl").exists()


def test_telemetry_log_appends_multiple_records_as_separate_lines(
    tmp_path: Path,
) -> None:
    log = safety.TelemetryLog(tmp_path, session_id="multi")
    log.record("device.open", "ok")
    log.record("device.close", "ok")
    lines = (tmp_path / "hw-telemetry" / "multi.jsonl").read_text().splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0])["method"] == "device.open"
    assert json.loads(lines[1])["method"] == "device.close"


# -- anomaly_halt -----------------------------------------------------------------


class _FakeTransportEjectOk:
    def eject(self) -> bool:
        return True


class _FakeTransportEjectRaises:
    def eject(self) -> bool:
        raise RuntimeError("eject failed: transport wedged")


def test_anomaly_halt_reports_ejected_true_on_success(tmp_path: Path) -> None:
    telemetry = safety.TelemetryLog(tmp_path)
    result = safety.anomaly_halt(
        _FakeTransportEjectOk(),
        telemetry,
        reason="transport smear exhausted retries",
        code="TRANSPORT_SMEAR_DETECTED",
        slot=3,
    )
    assert result == {
        "reason": "transport smear exhausted retries",
        "code": "TRANSPORT_SMEAR_DETECTED",
        "slot": 3,
        "ejected": True,
    }


def test_anomaly_halt_swallows_eject_exception_and_reports_ejected_false(
    tmp_path: Path,
) -> None:
    telemetry = safety.TelemetryLog(tmp_path)
    result = safety.anomaly_halt(
        _FakeTransportEjectRaises(),
        telemetry,
        reason="feeder parked",
        code="FEEDER_PARKED",
        slot=None,
    )
    assert result["ejected"] is False
    assert result["slot"] is None
    assert result["code"] == "FEEDER_PARKED"


def test_anomaly_halt_records_a_telemetry_entry(tmp_path: Path) -> None:
    telemetry = safety.TelemetryLog(tmp_path)
    safety.anomaly_halt(
        _FakeTransportEjectOk(),
        telemetry,
        reason="geometry validation failed",
        code="GEOMETRY_VALIDATION_ERROR",
        slot=7,
    )
    telemetry_files = list((tmp_path / "hw-telemetry").glob("*.jsonl"))
    assert len(telemetry_files) == 1
    lines = telemetry_files[0].read_text().splitlines()
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["method"] == "hardware.anomaly"
    assert parsed["outcome"] == "halted"
    assert parsed["code"] == "GEOMETRY_VALIDATION_ERROR"
    assert parsed["slot"] == 7
    assert parsed["ejected"] is True
