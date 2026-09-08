from __future__ import annotations

import json
from pathlib import Path

import pytest

from scanstudio_bridge import domain, safety, service
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport.mock import MockTransport


def _service(tmp_path: Path) -> tuple[service.BridgeService, safety.TelemetryLog]:
    telemetry = safety.TelemetryLog(tmp_path, session_id="unverified")
    bridge = service.BridgeService(MockTransport(preview_dir=tmp_path), telemetry, tmp_path)
    bridge.dispatch(
        {
            "id": 0,
            "method": "bridge.hello",
            "params": {"clientName": "test", "protocolVersion": 1},
        },
        lambda *_: None,
    )
    return bridge, telemetry


def _open(bridge: service.BridgeService, **params: object) -> dict:
    return bridge.dispatch(
        {"id": 1, "method": "device.open", "params": params}, lambda *_: None
    )


def test_unverified_device_requires_explicit_opt_in(tmp_path: Path) -> None:
    bridge, _ = _service(tmp_path)
    with pytest.raises(BridgeError) as refused:
        _open(bridge, deviceId="mock-ls50-0")
    assert refused.value.code is ErrorCode.DEVICE_NOT_FOUND


def test_unverified_device_opens_and_reports_both_wire_fields(tmp_path: Path) -> None:
    bridge, _ = _service(tmp_path)
    result = _open(
        bridge, deviceId="mock-ls50-0", allowUnverifiedHardware=True
    )
    assert result["device"]["unverifiedAllowed"] is True
    assert result["device"]["hardwareVerification"] == "unverified"


def test_verified_device_keeps_verified_defaults(tmp_path: Path) -> None:
    bridge, _ = _service(tmp_path)
    result = _open(bridge, deviceId="mock-ls5000-0")
    assert result["device"]["unverifiedAllowed"] is False
    assert result["device"]["hardwareVerification"] == "verified"


def test_unverified_receipt_carries_verification(tmp_path: Path) -> None:
    transport = MockTransport(slot_count=2, preview_dir=tmp_path)
    transport.open_device("mock-ls50-0", allow_unverified_hardware=True)
    transport.preview(domain.Material.COLOR_NEGATIVE, [1], lambda _: None)
    receipts: list[domain.ScanReceipt] = []
    transport.start_scan(
        [1],
        domain.FIXED_COLOR_NEGATIVE_RECIPE,
        domain.OutputSpec(str(tmp_path), "frame-####.tif"),
        lambda _: None,
        lambda *_: None,
        lambda _, receipt: receipts.append(receipt),
    )
    assert receipts[0].device_model == "LS-50 ED"
    assert receipts[0].hardware_verification is domain.HardwareVerification.UNVERIFIED


def test_opt_in_must_be_a_real_boolean(tmp_path: Path) -> None:
    bridge, _ = _service(tmp_path)
    with pytest.raises(BridgeError) as refused:
        _open(bridge, deviceId="mock-ls50-0", allowUnverifiedHardware="true")
    assert refused.value.code is ErrorCode.INVALID_PARAMS


def test_opt_in_does_not_accept_unknown_device(tmp_path: Path) -> None:
    bridge, _ = _service(tmp_path)
    with pytest.raises(BridgeError) as refused:
        _open(bridge, deviceId="unknown", allowUnverifiedHardware=True)
    assert refused.value.code is ErrorCode.DEVICE_NOT_FOUND


def test_telemetry_after_unverified_open_carries_tier(tmp_path: Path) -> None:
    bridge, telemetry = _service(tmp_path)
    telemetry.record("device.status", "disconnected")
    _open(bridge, deviceId="mock-ls50-0", allowUnverifiedHardware=True)
    telemetry.record("scan.start", "started")
    bridge.dispatch({"id": 2, "method": "device.close", "params": {}}, lambda *_: None)
    telemetry.record("device.status", "disconnected")
    lines = [
        json.loads(line)
        for line in (tmp_path / "hw-telemetry" / "unverified.jsonl")
        .read_text()
        .splitlines()
    ]
    assert [line["hardware_verification"] for line in lines] == [
        "notConnected",
        "unverified",
        "notConnected",
    ]
