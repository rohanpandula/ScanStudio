"""NDJSON wire envelope: dataclass<->JSON codec, error codes, and the
`bridge.hello` handshake.

`to_wire`/`from_wire` are the only encoder/decoder pair in this codebase --
no per-type `to_dict` methods anywhere else. See BRIDGE.md
(nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md)
for the canonical spec this module implements: its Error codes section
lists every `ErrorCode` member below, and its Methods section defines the
`bridge.hello` result `hello_result` builds.
"""

from __future__ import annotations

import dataclasses
import json
import math
import types
import typing
from dataclasses import dataclass
from enum import Enum, StrEnum
from typing import IO


class ErrorCode(StrEnum):
    UNKNOWN_METHOD = "UNKNOWN_METHOD"
    INVALID_PARAMS = "INVALID_PARAMS"
    NOT_CONNECTED = "NOT_CONNECTED"
    ALREADY_CONNECTED = "ALREADY_CONNECTED"
    DEVICE_NOT_FOUND = "DEVICE_NOT_FOUND"
    DEVICE_BUSY = "DEVICE_BUSY"
    NO_PREVIEW = "NO_PREVIEW"
    UNKNOWN_JOB = "UNKNOWN_JOB"
    HW_MOTION_NOT_ARMED = "HW_MOTION_NOT_ARMED"
    HARDWARE_LANE_BUSY = "HARDWARE_LANE_BUSY"
    EJECT_FAILED = "EJECT_FAILED"
    FEEDER_PARKED = "FEEDER_PARKED"
    ADAPTER_UNSUPPORTED = "ADAPTER_UNSUPPORTED"
    FINGERPRINT_REFUSED = "FINGERPRINT_REFUSED"
    MANUAL_REVIEW_REQUIRED = "MANUAL_REVIEW_REQUIRED"
    REFEED_REQUIRED = "REFEED_REQUIRED"
    FILM_FEED_INTERRUPTED = "FILM_FEED_INTERRUPTED"
    ROLL_MISMATCH = "ROLL_MISMATCH"
    TRANSPORT_SMEAR_DETECTED = "TRANSPORT_SMEAR_DETECTED"
    GEOMETRY_VALIDATION_ERROR = "GEOMETRY_VALIDATION_ERROR"
    SPLIT_ALIGNMENT_ERROR = "SPLIT_ALIGNMENT_ERROR"
    BATCH_INTEGRITY_ERROR = "BATCH_INTEGRITY_ERROR"
    METER_UNUSABLE = "METER_UNUSABLE"
    NOT_IMPLEMENTED = "NOT_IMPLEMENTED"
    INTERNAL = "INTERNAL"


class BridgeError(Exception):
    """One BRIDGE.md error code plus a human message."""

    def __init__(self, code: ErrorCode, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    @property
    def recoverable(self) -> bool:
        # Retrying the identical request once the lane frees can succeed
        # with no other action -- every other code needs a different
        # action first (re-arm, roll.approve, physical refeed, power
        # cycle), so every other code is unrecoverable.
        return self.code is ErrorCode.HARDWARE_LANE_BUSY


def to_camel_case(name: str) -> str:
    """Mechanical snake_case -> camelCase, e.g. `red_exposure_us` ->
    `redExposureUs`. The one place this conversion is implemented."""
    head, *rest = name.split("_")
    return head + "".join(word[:1].upper() + word[1:] for word in rest)


def to_wire(value: object) -> object:
    """Recursively convert a dataclass instance (or list/tuple/dict/Enum/
    primitive/None composed of them) into a JSON-safe structure, converting
    every dataclass field name snake_case -> camelCase. The only encoder in
    this codebase."""
    if value is None:
        return None
    if isinstance(value, Enum):
        return value.value
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return {
            to_camel_case(field.name): to_wire(getattr(value, field.name))
            for field in dataclasses.fields(value)
        }
    if isinstance(value, (list, tuple)):
        return [to_wire(item) for item in value]
    if isinstance(value, dict):
        return {key: to_wire(item) for key, item in value.items()}
    if isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError(f"to_wire: unsupported type {type(value)!r}")


def from_wire(data: dict, cls: type) -> object:
    """Inverse of `to_wire` for one dataclass type: camelCase JSON keys ->
    snake_case constructor kwargs, recursing per `cls`'s type annotations.
    A missing required field raises `BridgeError(INVALID_PARAMS)`."""
    if type(data) is not dict:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"{cls.__name__} must be a JSON object",
        )
    hints = typing.get_type_hints(cls)
    known_keys = {to_camel_case(field.name) for field in dataclasses.fields(cls)}
    unknown_keys = sorted(set(data) - known_keys)
    if unknown_keys:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"unknown {cls.__name__} field(s): {', '.join(unknown_keys)}",
        )
    kwargs: dict[str, object] = {}
    for field in dataclasses.fields(cls):
        wire_key = to_camel_case(field.name)
        if wire_key not in data:
            has_default = (
                field.default is not dataclasses.MISSING
                or field.default_factory is not dataclasses.MISSING
            )
            if has_default:
                continue
            raise BridgeError(
                ErrorCode.INVALID_PARAMS, f"missing required field: {wire_key}"
            )
        kwargs[field.name] = _decode_value(
            data[wire_key], hints[field.name], f"{cls.__name__}.{wire_key}"
        )
    return cls(**kwargs)


def _decode_value(value: object, type_: object, path: str) -> object:
    origin = typing.get_origin(type_)

    if origin is typing.Union or origin is types.UnionType:
        union_args = typing.get_args(type_)
        members = [arg for arg in union_args if arg is not type(None)]
        if value is None:
            if type(None) in union_args:
                return None
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} may not be null")
        if len(members) == 1:
            return _decode_value(value, members[0], path)
        return value  # opaque multi-member union: pass through unchanged

    if value is None:
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} may not be null")

    if isinstance(type_, type) and dataclasses.is_dataclass(type_):
        return from_wire(value, type_)

    if isinstance(type_, type) and issubclass(type_, Enum):
        try:
            return type_(value)
        except (TypeError, ValueError) as exc:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"{path} has unsupported value {value!r}",
            ) from exc

    if origin is tuple:
        if type(value) is not list:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a JSON array")
        args = typing.get_args(type_)
        if len(args) == 2 and args[1] is Ellipsis:
            return tuple(
                _decode_value(item, args[0], f"{path}[{index}]")
                for index, item in enumerate(value)
            )
        if len(value) != len(args):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"{path} must contain exactly {len(args)} items",
            )
        return tuple(
            _decode_value(item, arg, f"{path}[{index}]")
            for index, (item, arg) in enumerate(zip(value, args))
        )

    if origin is list:
        if type(value) is not list:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a JSON array")
        (element_type,) = typing.get_args(type_) or (object,)
        return [
            _decode_value(item, element_type, f"{path}[{index}]")
            for index, item in enumerate(value)
        ]

    if origin is dict:
        if type(value) is not dict:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a JSON object")
        _, value_type = typing.get_args(type_) or (str, object)
        if any(type(key) is not str for key in value):
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} keys must be strings")
        return {
            key: _decode_value(item, value_type, f"{path}.{key}")
            for key, item in value.items()
        }

    if type_ is bool:
        if type(value) is not bool:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a boolean")
        return value
    if type_ is int:
        if type(value) is not int:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a whole number")
        return value
    if type_ is float:
        if type(value) not in (int, float) or not math.isfinite(value):
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a finite number")
        return float(value)
    if type_ is str:
        if type(value) is not str:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"{path} must be a string")
        return value

    # Primitive (str/int/float/bool) or intentionally opaque (e.g. `object`).
    return value


def validate_request(request: object) -> dict:
    """Validate the common request envelope without coercion."""

    if type(request) is not dict:
        raise BridgeError(ErrorCode.INVALID_PARAMS, "request must be a JSON object")
    unknown = sorted(set(request) - {"id", "method", "params"})
    if unknown:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"unknown request field(s): {', '.join(unknown)}",
        )
    if (
        "id" not in request
        or type(request["id"]) is not int
        or not 0 <= request["id"] <= 2**64 - 1
    ):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "id must be a whole number between 0 and 18446744073709551615",
        )
    if type(request.get("method")) is not str or not request["method"]:
        raise BridgeError(ErrorCode.INVALID_PARAMS, "method must be a non-empty string")
    if "params" in request and type(request["params"]) is not dict:
        raise BridgeError(ErrorCode.INVALID_PARAMS, "params must be a JSON object")
    return request


def validate_params(
    request: dict,
    *,
    required: tuple[str, ...] = (),
    optional: tuple[str, ...] = (),
) -> dict:
    """Validate one method's exact parameter-key schema."""

    params = request.get("params", {})
    if type(params) is not dict:
        raise BridgeError(ErrorCode.INVALID_PARAMS, "params must be a JSON object")
    allowed = set(required) | set(optional)
    unknown = sorted(set(params) - allowed)
    if unknown:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"unknown parameter(s) for {request['method']}: {', '.join(unknown)}",
        )
    missing = [name for name in required if name not in params]
    if missing:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"missing required parameter(s) for {request['method']}: {', '.join(missing)}",
        )
    return params


def read_request(line: str) -> dict:
    """`json.loads(line)`. A malformed line's `json.JSONDecodeError`
    propagates uncaught -- the caller decides how to respond."""
    return json.loads(line)


def _write_line(stream: IO[str], obj: dict) -> None:
    stream.write(json.dumps(obj, separators=(",", ":")))
    stream.write("\n")
    stream.flush()


def write_response(stream: IO[str], id_: int, result: object) -> None:
    _write_line(stream, {"id": id_, "result": result})


def write_error(stream: IO[str], id_: int, error: BridgeError) -> None:
    _write_line(
        stream,
        {
            "id": id_,
            "error": {
                "code": error.code.value,
                "message": error.message,
                "recoverable": error.recoverable,
            },
        },
    )


def write_event(stream: IO[str], event: str, payload: object) -> None:
    _write_line(stream, {"event": event, "payload": payload})


@dataclass(frozen=True)
class _HelloResult:
    """Internal to this module -- the `bridge.hello` result shape is
    documented in BRIDGE.md's Methods section, not re-exported as a
    domain.py wire type."""

    bridge_name: str
    bridge_version: str
    protocol_version: int
    capabilities: tuple[str, ...]


def hello_result(client_protocol_version: int, bridge_version: str) -> dict:
    """Validate and build the wire-shaped `bridge.hello` result. Raises
    `BridgeError(INVALID_PARAMS)` unless `client_protocol_version == 1`."""
    if client_protocol_version != 1:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"unsupported protocolVersion {client_protocol_version!r}; only 1 is supported",
        )
    return to_wire(
        _HelloResult(
            bridge_name="scanstudio-bridge",
            bridge_version=bridge_version,
            protocol_version=1,
            capabilities=("ls5000-coolscanpy",),
        )
    )
