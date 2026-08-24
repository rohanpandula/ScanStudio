"""Tests for scanstudio_bridge.protocol: wire envelope codec, error codes,
NDJSON read/write, and the bridge.hello handshake.

BRIDGE.md (nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md)
is the canonical spec these tests hold protocol.py to.
"""

from __future__ import annotations

import io
import json

import pytest

from scanstudio_bridge.domain import CaptureRecipe
from scanstudio_bridge.protocol import (
    BridgeError,
    ErrorCode,
    from_wire,
    hello_result,
    read_request,
    write_error,
    write_event,
    write_response,
)


class _RecordingStream(io.StringIO):
    """A StringIO that counts flush() calls, since NDJSON-over-stdio
    correctness depends on every line actually being flushed."""

    def __init__(self) -> None:
        super().__init__()
        self.flush_count = 0

    def flush(self) -> None:
        self.flush_count += 1
        super().flush()


def test_hardware_lane_busy_is_recoverable() -> None:
    error = BridgeError(ErrorCode.HARDWARE_LANE_BUSY, "lane held by another job")
    assert error.recoverable is True


@pytest.mark.parametrize(
    "code",
    [code for code in ErrorCode if code is not ErrorCode.HARDWARE_LANE_BUSY],
)
def test_every_other_error_code_is_not_recoverable(code: ErrorCode) -> None:
    error = BridgeError(code, "some failure")
    assert error.recoverable is False


def test_hello_result_accepts_protocol_version_1() -> None:
    result = hello_result(1, "0.1.0")
    assert result == {
        "bridgeName": "scanstudio-bridge",
        "bridgeVersion": "0.1.0",
        "protocolVersion": 1,
        "capabilities": ["ls5000-coolscanpy"],
    }


def test_hello_result_rejects_unsupported_protocol_version() -> None:
    with pytest.raises(BridgeError) as excinfo:
        hello_result(2, "0.1.0")
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


def test_read_request_parses_valid_json_line() -> None:
    assert read_request('{"id":1,"method":"bridge.hello"}') == {
        "id": 1,
        "method": "bridge.hello",
    }


def test_read_request_propagates_json_decode_error() -> None:
    with pytest.raises(json.JSONDecodeError):
        read_request("not json")


def test_write_response_writes_one_flushed_json_line() -> None:
    stream = _RecordingStream()
    write_response(stream, 1, {"ok": True})
    raw = stream.getvalue()
    assert raw.endswith("\n")
    assert raw.count("\n") == 1
    line = raw.strip()
    assert "\n" not in line
    assert json.loads(line) == {"id": 1, "result": {"ok": True}}
    assert stream.flush_count == 1


def test_write_error_writes_one_flushed_json_line() -> None:
    stream = _RecordingStream()
    write_error(stream, 2, BridgeError(ErrorCode.HARDWARE_LANE_BUSY, "lane busy"))
    line = stream.getvalue().strip()
    assert "\n" not in line
    assert json.loads(line) == {
        "id": 2,
        "error": {
            "code": "HARDWARE_LANE_BUSY",
            "message": "lane busy",
            "recoverable": True,
        },
    }
    assert stream.flush_count == 1


def test_write_error_preserves_bounded_structured_details() -> None:
    stream = _RecordingStream()
    details = {
        "pass": 2,
        "reasons": [
            {
                "code": "linearity_insufficient",
                "channel": "G",
                "validRawSamples": 12_800,
                "requiredRawSamples": 256,
                "validAggregateSamples": 0,
                "requiredAggregateSamples": 24,
            }
        ],
    }

    write_error(
        stream,
        3,
        BridgeError(
            ErrorCode.METER_CONTROLLER_REFUSED,
            "meter pass 2 controller refused",
            details=details,
        ),
    )

    assert json.loads(stream.getvalue())["error"] == {
        "code": "METER_CONTROLLER_REFUSED",
        "message": "meter pass 2 controller refused",
        "recoverable": False,
        "details": details,
    }


def test_write_error_preserves_diagnostic_evidence_without_changing_error() -> None:
    stream = _RecordingStream()
    evidence = {
        "schemaVersion": 1,
        "evidenceId": "failed-preview-42",
        "witness": {
            "kind": "terminalPadding",
            "recordCount": 2,
            "byteCount": 2048,
            "parity": "even",
            "housekeepingByteCount": 448,
            "nonzeroRgbCount": 1,
            "mismatchLocation": {"recordIndex": 1, "byteOffset": 1038},
        },
    }

    write_error(
        stream,
        4,
        BridgeError(
            ErrorCode.REFEED_REQUIRED,
            "original transport refusal",
            diagnostic_evidence=evidence,
        ),
    )

    assert json.loads(stream.getvalue())["error"] == {
        "code": "REFEED_REQUIRED",
        "message": "original transport refusal",
        "recoverable": False,
        "diagnosticEvidence": evidence,
    }


def test_write_error_carries_explicit_evidence_unavailable_reason() -> None:
    stream = _RecordingStream()
    write_error(
        stream,
        5,
        BridgeError(
            ErrorCode.REFEED_REQUIRED,
            "original transport refusal",
            diagnostic_evidence_unavailable_reason=(
                "bounded diagnostic evidence could not be published"
            ),
        ),
    )

    assert json.loads(stream.getvalue())["error"][
        "diagnosticEvidenceUnavailableReason"
    ] == "bounded diagnostic evidence could not be published"


def test_write_event_writes_one_flushed_json_line() -> None:
    stream = _RecordingStream()
    write_event(stream, "device.status", {"connected": True})
    line = stream.getvalue().strip()
    assert "\n" not in line
    assert json.loads(line) == {
        "event": "device.status",
        "payload": {"connected": True},
    }
    assert stream.flush_count == 1


def test_from_wire_raises_invalid_params_on_missing_required_field() -> None:
    incomplete = {
        "resolutionDpi": 4000,
        "bitDepth": 16,
        "multisamplePasses": 4,
        "channels": "rgbi",
        "autofocus": True,
        # missing autoExposure
    }
    with pytest.raises(BridgeError) as excinfo:
        from_wire(incomplete, CaptureRecipe)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


@pytest.mark.parametrize("bad_value", [True, "4000", 4000.0, float("nan")])
def test_from_wire_refuses_coercible_or_nonfinite_integer_fields(bad_value: object) -> None:
    recipe = {
        "resolutionDpi": bad_value,
        "bitDepth": 16,
        "multisamplePasses": 4,
        "channels": "rgbi",
        "autofocus": True,
        "autoExposure": True,
    }
    with pytest.raises(BridgeError) as excinfo:
        from_wire(recipe, CaptureRecipe)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS


def test_from_wire_refuses_unknown_fields() -> None:
    recipe = {
        "resolutionDpi": 4000,
        "bitDepth": 16,
        "multisamplePasses": 4,
        "channels": "rgbi",
        "autofocus": True,
        "autoExposure": True,
        "futureMotionFlag": True,
    }
    with pytest.raises(BridgeError) as excinfo:
        from_wire(recipe, CaptureRecipe)
    assert excinfo.value.code == ErrorCode.INVALID_PARAMS
    assert "unknown" in excinfo.value.message
