"""Tests for scanstudio_bridge.safety: SAFE-02's armed latch, single
hardware lane, telemetry log, and anomaly-halt helper.

Every test passes pytest's `tmp_path` as `base_dir` -- none of these tests
are permitted to touch the real `~/.scanstudio` (see BRIDGE.md's SAFE-02
guardrails section, nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md).
"""

from __future__ import annotations

import json
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
    # Released -- a fresh lane over the same base_dir can be acquired again.
    with safety.HardwareLane(tmp_path):
        pass


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
