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
    FINGERPRINT_REFUSED = "FINGERPRINT_REFUSED"
    MANUAL_REVIEW_REQUIRED = "MANUAL_REVIEW_REQUIRED"
    REFEED_REQUIRED = "REFEED_REQUIRED"
    FILM_FEED_INTERRUPTED = "FILM_FEED_INTERRUPTED"
    ROLL_MISMATCH = "ROLL_MISMATCH"
    TRANSPORT_SMEAR_DETECTED = "TRANSPORT_SMEAR_DETECTED"
    GEOMETRY_VALIDATION_ERROR = "GEOMETRY_VALIDATION_ERROR"
    SPLIT_ALIGNMENT_ERROR = "SPLIT_ALIGNMENT_ERROR"
    BATCH_INTEGRITY_ERROR = "BATCH_INTEGRITY_ERROR"
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
    hints = typing.get_type_hints(cls)
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
        kwargs[field.name] = _decode_value(data[wire_key], hints[field.name])
    return cls(**kwargs)


def _decode_value(value: object, type_: object) -> object:
    origin = typing.get_origin(type_)

    if origin is typing.Union or origin is types.UnionType:
        members = [arg for arg in typing.get_args(type_) if arg is not type(None)]
        if value is None:
            return None
        if len(members) == 1:
            return _decode_value(value, members[0])
        return value  # opaque multi-member union: pass through unchanged

    if value is None:
        return None

    if isinstance(type_, type) and dataclasses.is_dataclass(type_):
        return from_wire(value, type_)

    if isinstance(type_, type) and issubclass(type_, Enum):
        return type_(value)

    if origin is tuple:
        args = typing.get_args(type_)
        if len(args) == 2 and args[1] is Ellipsis:
            return tuple(_decode_value(item, args[0]) for item in value)
        return tuple(_decode_value(item, arg) for item, arg in zip(value, args))

    if origin is list:
        (element_type,) = typing.get_args(type_) or (object,)
        return [_decode_value(item, element_type) for item in value]

    if origin is dict:
        _, value_type = typing.get_args(type_) or (str, object)
        return {key: _decode_value(item, value_type) for key, item in value.items()}

    # Primitive (str/int/float/bool) or intentionally opaque (e.g. `object`).
    return value


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
