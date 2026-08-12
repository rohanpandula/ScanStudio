"""`BridgeService`: method dispatch, the hello-first gate, SAFE-02 armed
latch + single-lane enforcement, and bounded-retry-then-anomaly handling.
See BRIDGE.md (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md) for the wire-level contract this module
implements -- every method name, error code, and event shape below mirrors
that document. `cli.py` (Task 2) is the only caller: it owns the NDJSON
stdin/stdout loop and calls `dispatch()` once per request.

Mirrors `app/ScanStudio/engine/src/server.rs`'s `handle_request`/
`reject_before_hello` shape (this repo's own Phase 1 engine) arm-for-arm,
adapted for `roll.preview`/`scan.start` being asynchronous: both promise an
immediate response followed by streamed events, so their transport calls
run on a worker thread rather than the request-handling thread.
"""

from __future__ import annotations

import dataclasses
import importlib.metadata
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Callable

from scanstudio_bridge import domain, safety
from scanstudio_bridge.protocol import (
    BridgeError,
    ErrorCode,
    from_wire,
    hello_result,
    to_wire,
    validate_params,
    validate_request,
)
from scanstudio_bridge.transport import FrameRetryExhausted, Transport

try:
    BRIDGE_VERSION = importlib.metadata.version("scanstudio-bridge")
except importlib.metadata.PackageNotFoundError:
    # Run-from-source bundles (the Linux/Windows sealed launchers exec the
    # bridge via runpy with the corresponding-source tree on sys.path, and do
    # not pip-install it, so no distribution metadata exists). A missing
    # version must never crash bridge startup -- report a stable marker so
    # bridge.hello still answers. A pip-installed bridge (e.g. the Windows
    # WSL runtime) resolves the real version above.
    BRIDGE_VERSION = "0.0.0-src"

# Bounded so bridge.shutdown / dispatch-time joins never hang indefinitely
# on a stuck worker thread (BRIDGE.md: "Cancellation is bounded so an
# active operation cannot keep shutdown waiting on it indefinitely.").
_JOIN_TIMEOUT_SECONDS = 5.0

# Scan-worker soft timeout (Plan 10-04, nikon-coolscan4-software-archaeology
# .planning/phases/10-real-capture/LIVE-VERIFICATION-20260723.md: a real
# fine-scan job's worker entered its CoolscanPy call path and never
# returned, with no diagnostic). Env-tunable so tests can drive a tiny
# value; read once per scan.start call (see _scan_timeout_seconds), never
# process-wide-cached.
_SCAN_TIMEOUT_ENV_VAR = "SCANSTUDIO_BRIDGE_SCAN_TIMEOUT"
_DEFAULT_SCAN_TIMEOUT_SECONDS = 900.0
# The soft-timeout watchdog's own poll cadence: fine enough that a short
# test-configured timeout (e.g. 0.2s) is caught promptly, coarse enough
# that production's 900s default costs nothing.
_WATCHDOG_POLL_FLOOR_SECONDS = 0.01
_WATCHDOG_POLL_CEILING_SECONDS = 0.5

_METHOD_PARAM_SCHEMAS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "bridge.hello": (("clientName", "protocolVersion"), ()),
    "bridge.shutdown": ((), ()),
    "device.list": ((), ()),
    "device.open": (("deviceId",), ()),
    "device.status": ((), ()),
    "device.close": ((), ()),
    "roll.preview": (("material",), ("slots",)),
    "roll.approve": (("slot",), ("fingerprint",)),
    "roll.setSpacingOffset": (("slot", "offsetRows"), ()),
    "roll.manualFrames": (("rows",), ()),
    "roll.previewStrip": ((), ()),
    "scan.start": (("slots", "recipe", "output"), ("jobId",)),
    "scan.stop": (("jobId",), ()),
    "device.eject": ((), ()),
}


def _scan_timeout_seconds() -> float:
    """`SCANSTUDIO_BRIDGE_SCAN_TIMEOUT`, read once per `scan.start` call —
    mirrors the engine's own read-once-per-job convention for its sibling
    `SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS` (Plan 10-04's engine-side
    half). Unset or unparseable falls back to the default rather than
    raising."""
    raw = os.environ.get(_SCAN_TIMEOUT_ENV_VAR)
    if raw is None:
        return _DEFAULT_SCAN_TIMEOUT_SECONDS
    try:
        return float(raw)
    except ValueError:
        return _DEFAULT_SCAN_TIMEOUT_SECONDS


def _run_scan_soft_timeout_watchdog(
    *,
    job_record: dict,
    call_state: dict,
    call_state_lock: threading.Lock,
    telemetry: safety.TelemetryLog,
    emit: Callable[[str, dict], None],
    job_id: str,
    timeout_seconds: float,
) -> None:
    """Polls `call_state` (kept current by `on_call` below) until either
    the job reaches a terminal state (`job_record["terminal"]` — nothing to
    report, return quietly) or the currently in-flight call, if any, has
    been entered for longer than `timeout_seconds` with no matching exit
    yet. On expiry: one telemetry entry (`outcome="timeout"`) naming the
    stuck call, one `scan.error` wire event — then this watchdog thread
    simply returns.

    This function NEVER touches `job_record`, the hardware lane, the
    worker thread, or the Transport in any way — report-only, matching
    SAFE-02's anomaly-report philosophy (BRIDGE.md) and this plan's
    cardinal rule: the owner power-cycles. The worker thread and whatever
    device call it is blocked inside keep running untouched; if it ever
    does return, `worker()`'s own `finally` still emits `scan.completed`
    normally, independent of whatever this watchdog reported.
    """
    poll_interval = min(
        max(timeout_seconds / 20, _WATCHDOG_POLL_FLOOR_SECONDS),
        _WATCHDOG_POLL_CEILING_SECONDS,
    )
    while not job_record["terminal"]:
        time.sleep(poll_interval)
        if job_record["terminal"]:
            return
        with call_state_lock:
            stuck_call = call_state["name"]
            entered_at = call_state["entered_at"]
        if stuck_call is None or entered_at is None:
            continue
        if time.monotonic() - entered_at < timeout_seconds:
            continue
        telemetry.record(
            "scan.call",
            "timeout",
            job_id=job_id,
            call=stuck_call,
            timeout_seconds=timeout_seconds,
        )
        emit(
            "scan.error",
            {
                "jobId": job_id,
                "code": ErrorCode.INTERNAL.value,
                "message": (
                    f"scan worker soft timeout: no return from {stuck_call!r} within "
                    f"{timeout_seconds}s; the bridge process, worker thread, and any "
                    "in-flight device call were left untouched -- power-cycle required"
                ),
            },
        )
        return


def reject_before_hello(hello_received: bool, method: str) -> BridgeError | None:
    """`bridge.hello` must be the first request; every other method before
    it is rejected with `INVALID_PARAMS`. Extracted as a pure function so
    it's unit-testable without a real `BridgeService` -- directly mirrors
    `server.rs`'s `reject_before_hello`."""
    if not hello_received and method != "bridge.hello":
        return BridgeError(
            ErrorCode.INVALID_PARAMS, "bridge.hello must be the first request"
        )
    return None


def _require_param(params: dict, key: str) -> object:
    """Safe required-field access for method params: raises
    `BridgeError(INVALID_PARAMS)` instead of letting a raw `KeyError`/
    `TypeError` escape `dispatch()` and crash `cli.py`'s stdin loop on a
    malformed-but-valid-JSON request (T-08-02)."""
    value = params.get(key)
    if value is None:
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"missing required field: {key}")
    return value


def _require_plain_int(
    value: object,
    name: str,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if type(value) is not int:
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"{name} must be a whole number")
    if minimum is not None and value < minimum:
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"{name} must be at least {minimum}")
    if maximum is not None and value > maximum:
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"{name} must be at most {maximum}")
    return value


def _require_string(
    value: object,
    name: str,
    *,
    minimum_length: int = 1,
    maximum_length: int = 4096,
) -> str:
    if type(value) is not str:
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"{name} must be a string")
    if not minimum_length <= len(value) <= maximum_length:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"{name} length must be between {minimum_length} and {maximum_length}",
        )
    return value


def _require_int_list(
    value: object,
    name: str,
    *,
    minimum_length: int,
    maximum_length: int,
    item_minimum: int,
    item_maximum: int,
    unique: bool = False,
) -> list[int]:
    if type(value) is not list or any(type(item) is not int for item in value):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"{name} must be a list of whole numbers",
        )
    if not minimum_length <= len(value) <= maximum_length:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"{name} must contain between {minimum_length} and {maximum_length} items",
        )
    result = [
        _require_plain_int(
            item,
            f"{name}[{index}]",
            minimum=item_minimum,
            maximum=item_maximum,
        )
        for index, item in enumerate(value)
    ]
    if unique and len(set(result)) != len(result):
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"{name} may not contain duplicates")
    return result


# Plan 10-09 (durable per-frame failure reasons): scan.frameFailed's own
# fixed telemetry fields -- a coolscanpy exception attribute that happens to
# share one of these names is renamed rather than silently dropped or
# crashing telemetry.record() on a duplicate keyword argument (see
# _coolscanpy_error_attributes below).
_FRAME_FAILED_RESERVED_TELEMETRY_FIELDS = frozenset(
    {"job_id", "slot", "reason_class", "reason_message", "elapsed"}
)

# 2026-07-25 incident fix: additive scan.frameFailed qualifier (telemetry
# field and wire field both) marking a slot named by first_pending_slot()
# (see scan.start's worker below) as a best-effort pick among several
# equally-plausible pending slots, not a confirmed one -- set only when
# ambiguous, per BRIDGE.md's forward-compatibility rule (both sides must
# ignore unknown fields; same precedent as hardware.anomaly's own
# "laneReleased" extra field elsewhere in this module).
_BATCH_PRE_FRAME_ATTRIBUTION = "batch-pre-frame"


def _thumbnail_to_wire(thumbnail: domain.Thumbnail) -> dict:
    """Serialize a Thumbnail to the wire, adding the additive ``partial`` key
    only when the frame is partial.

    WHY post-``to_wire`` and not a plain field on ``domain.Thumbnail``:
    ``to_wire`` emits every dataclass field, so a ``partial=None`` would
    serialize as ``"partial": null`` on every full-cover thumbnail and change
    the wire. ``None`` cannot be skipped globally in ``to_wire`` because
    ``activeJobId: null`` in ``DeviceStatus`` is a MEANINGFUL value (it is a
    byte-valid golden fixture, ``05-status-event.json``); omit-when-None would
    silently drop it. So ``partial`` is injected here only when true --
    strictly additive and byte-absent for full-cover frames (Lane C, D2).
    """
    wire = to_wire(thumbnail)
    if thumbnail.partial:
        wire["partial"] = True
    else:
        wire.pop("partial", None)
    return wire


def _coolscanpy_error_attributes(exc: BaseException) -> dict[str, object]:
    """(if present) coolscanpy error attributes: any custom instance
    attribute an exception's own `__init__` set (e.g.
    `ManualReviewRequired.slot`, `TransportSmearDetected.assessment`,
    `FingerprintRefused.comparison`, or `BridgeError.code`/`.message` when
    `exc` is itself a bridge-native BridgeError). `vars(exc)` picks these up
    generically with no per-exception-type special-casing -- a plain
    `Exception`'s own `.args` lives in a C-level slot, not `__dict__`, so
    this never fabricates noise for an exception with no extra attributes.
    Converted to JSON-safe values via the same `to_wire` encoder the wire
    protocol itself already uses for every other dataclass in this codebase
    -- it handles an arbitrary nested dataclass (coolscanpy's own
    `TransportSmearAssessment`/`FingerprintComparison` included) generically;
    anything it doesn't recognize falls back to `repr()` rather than raising
    and losing the whole telemetry entry."""
    attributes: dict[str, object] = {}
    for key, value in vars(exc).items():
        safe_key = (
            f"error_{key}" if key in _FRAME_FAILED_RESERVED_TELEMETRY_FIELDS else key
        )
        try:
            attributes[safe_key] = to_wire(value)
        except TypeError:
            attributes[safe_key] = repr(value)
    return attributes


class BridgeService:
    """Owns bridge session state (hello/device/preview/job) and dispatches
    every BRIDGE.md method against a `Transport`. Constructed once per
    `cli.py` process; `dispatch()` is called once per NDJSON request from
    the single stdin-reading thread, so this class needs no internal
    locking of its own -- only the worker threads it spawns for
    `roll.preview`/`scan.start` touch shared state concurrently, and they
    only ever call `emit`/`safety`/`transport`, never mutate `self`
    directly except for the two flags documented below."""

    def __init__(
        self,
        transport: Transport,
        telemetry: safety.TelemetryLog,
        base_dir: Path = safety.DEFAULT_BASE_DIR,
    ) -> None:
        self._transport = transport
        self._telemetry = telemetry
        self._base_dir = base_dir
        self._hello_received = False
        self._device_open = False
        self._preview_material: domain.Material | None = None
        self._last_job: dict | None = None  # {"job_id": str, "terminal": bool, "thread": Thread}
        self._seen_job_ids: set[str] = set()
        # Set True the instant a `safety.HardwareLane` is actually held by
        # this process (roll.preview/scan.start/device.eject), False the
        # instant it's released -- lets `device.status`'s DeviceStatus.laneHeld
        # be accurate across all three motion-capable methods, since neither
        # Transport implementation tracks this uniformly (see 08-02's
        # "DeviceStatus placeholder fields deferred to this plan" decision).
        self._lane_held = False
        # Protocol-operation gate, deliberately SEPARATE from the hardware
        # lane above (2026-07-25 adversarial-review finding on the
        # lane-release reorder): a worker now releases the lane BEFORE its
        # terminal event is emitted so a status poll triggered by that event
        # sees the lane free -- but that opened a window where a new motion
        # request (or device.close) could be ACCEPTED between the release
        # and the terminal event reaching the wire, letting the old job's
        # terminal events interleave into (or be consumed by) the new
        # operation. This flag stays True from a motion request's acceptance
        # until AFTER its terminal event has been handed to `emit`;
        # dispatch refuses new motion requests and device.close with
        # HARDWARE_LANE_BUSY (recoverable -- the client simply retries)
        # while it is set. It is intentionally NOT reported in
        # device.status's laneHeld, which continues to describe the
        # hardware lane alone.
        self._motion_op_active = False

    # -- status snapshot ----------------------------------------------------------

    def _status_snapshot(self) -> domain.DeviceStatus:
        """`transport.status()` with `motionArmed`/`activeJobId`/`laneHeld`
        recomputed here rather than trusted from the Transport layer: per
        Plan 08-02's own documented decision, neither Transport is given
        `safety.py`'s `base_dir` or this service's job/lane bookkeeping, so
        those three fields are Transport-layer placeholders (always
        False/None) that only `BridgeService` can compute correctly."""
        status = self._transport.status()
        if status.film_present is False:
            # Physical absence is fresher and stronger than either cached
            # preview flag. Retire both service- and transport-facing preview
            # claims so status reports mediaLoaded=false and the next
            # scan.start is synchronously gated on NO_PREVIEW.
            self._preview_material = None
            status = dataclasses.replace(
                status,
                preview_established=False,
                slot_count=None,
            )
        return dataclasses.replace(
            status,
            active_job_id=(
                self._last_job["job_id"]
                if self._last_job is not None and not self._last_job["terminal"]
                else None
            ),
            lane_held=self._lane_held,
            motion_armed=safety.armed_media(self._base_dir) is not None,
        )

    def _closed_status_snapshot(self) -> domain.DeviceStatus:
        """`device.close` cannot call `transport.status()` after closing --
        both Transports raise `NOT_CONNECTED` once no device is open -- so
        this builds the all-off snapshot directly."""
        return domain.DeviceStatus(
            connected=False,
            device_id=None,
            preview_established=False,
            slot_count=None,
            active_job_id=None,
            lane_held=False,
            motion_armed=safety.armed_media(self._base_dir) is not None,
            # No device open, no Transport left to ask -- None is the only
            # honest value here (see BRIDGE.md's DeviceStatus.filmPresent
            # prose).
            film_present=None,
        )

    # -- dispatch -------------------------------------------------------------------

    def dispatch(self, request: dict, emit: Callable[[str, dict], None]) -> dict:
        request = validate_request(request)
        method = request.get("method")

        if method in _METHOD_PARAM_SCHEMAS:
            required, optional = _METHOD_PARAM_SCHEMAS[method]
            normalized = dict(request)
            normalized["params"] = validate_params(
                request, required=required, optional=optional
            )
            request = normalized

        reject = reject_before_hello(self._hello_received, method)
        if reject is not None:
            raise reject

        if method == "bridge.hello":
            return self._handle_hello(request)
        if method == "bridge.shutdown":
            return self._handle_shutdown()
        if method == "device.list":
            return {"devices": [to_wire(d) for d in self._transport.list_devices()]}
        if method == "device.open":
            return self._handle_device_open(request, emit)
        if method == "device.status":
            if not self._device_open:
                raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
            return to_wire(self._status_snapshot())
        if method == "device.close":
            return self._handle_device_close(emit)
        if method == "roll.preview":
            return self._handle_roll_preview(request, emit)
        if method == "roll.approve":
            params = request["params"]
            # Additive (2026-08-08 adversarial review, S1): `fingerprint` is
            # optional on the wire -- omitted entirely by every pre-existing
            # caller, unchanged. When present it must be a string; passed
            # through to the transport, which refuses the approval with
            # FINGERPRINT_REFUSED if it no longer matches the roll's current
            # state (see coolscanpy_transport.CoolscanPyTransport.approve).
            fingerprint = params.get("fingerprint")
            if fingerprint is not None:
                fingerprint = _require_string(
                    fingerprint, "fingerprint", maximum_length=256
                )
            self._transport.approve(
                _require_plain_int(params["slot"], "slot", minimum=1, maximum=40),
                fingerprint=fingerprint,
            )
            return {}
        if method == "roll.setSpacingOffset":
            if not self._device_open:
                raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
            if self._preview_material is None:
                raise BridgeError(
                    ErrorCode.NO_PREVIEW,
                    "roll.setSpacingOffset requires a completed roll.preview first",
                )
            if self._motion_op_active:
                raise BridgeError(
                    ErrorCode.HARDWARE_LANE_BUSY,
                    "a motion operation is still active; retry after it finishes",
                )
            params = request["params"]
            slot = _require_plain_int(params["slot"], "slot", minimum=1, maximum=40)
            offset_minimum = 0 if slot == 1 else -144
            offset_rows = _require_plain_int(
                params["offsetRows"],
                "offsetRows",
                minimum=offset_minimum,
                maximum=144,
            )
            thumbnail = self._transport.set_spacing_offset(
                slot,
                offset_rows,
            )
            return {"thumbnail": _thumbnail_to_wire(thumbnail)}
        if method == "roll.manualFrames":
            return self._handle_roll_manual_frames(request)
        if method == "roll.previewStrip":
            if not self._device_open:
                raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
            if self._motion_op_active:
                raise BridgeError(
                    ErrorCode.HARDWARE_LANE_BUSY,
                    "a motion operation is still active; retry after it finishes",
                )
            return to_wire(self._transport.preview_strip())
        if method == "scan.start":
            return self._handle_scan_start(request, emit)
        if method == "scan.stop":
            return self._handle_scan_stop(request)
        if method == "device.eject":
            return self._handle_device_eject(emit)

        raise BridgeError(ErrorCode.UNKNOWN_METHOD, f"unknown method '{method}'")

    # -- bridge.hello / bridge.shutdown --------------------------------------------

    def _handle_hello(self, request: dict) -> dict:
        params = request["params"]
        _require_string(params["clientName"], "clientName", maximum_length=128)
        protocol_version = _require_plain_int(
            params["protocolVersion"], "protocolVersion", minimum=0, maximum=2**31 - 1
        )
        result = hello_result(protocol_version, BRIDGE_VERSION)
        self._hello_received = True
        return result

    def _handle_shutdown(self, *, join_timeout: float | None = _JOIN_TIMEOUT_SECONDS) -> dict:
        if self._last_job is not None and not self._last_job["terminal"]:
            self._transport.request_stop()
            thread = self._last_job.get("thread")
            if thread is not None:
                thread.join(timeout=join_timeout)
            if thread is not None and thread.is_alive():
                raise BridgeError(
                    ErrorCode.HARDWARE_LANE_BUSY,
                    "shutdown not acknowledged: the owned capture worker is still active",
                )
            if not self._last_job["terminal"]:
                raise BridgeError(
                    ErrorCode.HARDWARE_LANE_BUSY,
                    "shutdown not acknowledged: the scan job has not published terminal cleanup",
                )
        if self._device_open:
            self._transport.close_device()
            self._device_open = False
            self._preview_material = None
        return {}

    def wait_for_owned_work_before_exit(self) -> None:
        """EOF/parent-loss cleanup that never abandons a capture worker.

        This may wait indefinitely for a genuinely stuck hardware call. That
        is intentional: the bridge process and inherited ownership lock stay
        alive, and a replacement bridge remains fenced off until ownership is
        actually released.
        """

        self._handle_shutdown(join_timeout=None)

    # -- device.* ---------------------------------------------------------------------

    def _handle_device_open(self, request: dict, emit: Callable[[str, dict], None]) -> dict:
        if self._device_open:
            raise BridgeError(ErrorCode.ALREADY_CONNECTED, "a device is already open")
        params = request["params"]
        device_id = _require_string(params["deviceId"], "deviceId", maximum_length=256)
        device = self._transport.open_device(device_id)
        self._device_open = True
        status = self._status_snapshot()
        emit("device.status", {"status": to_wire(status)})
        return {"device": to_wire(device), "status": to_wire(status)}

    def _handle_device_close(self, emit: Callable[[str, dict], None]) -> dict:
        if self._last_job is not None and not self._last_job["terminal"]:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY, "a scan job holds the hardware lane"
            )
        if self._motion_op_active:
            # A worker released the hardware lane but its terminal event has
            # not reached the wire yet -- closing now could emit a
            # disconnected device.status BEFORE the old operation's own
            # completion, an ordering no client should ever observe.
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a motion operation is still reporting its outcome; retry",
            )
        if not self._device_open:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        self._transport.close_device()
        self._device_open = False
        self._preview_material = None
        status = self._closed_status_snapshot()
        emit("device.status", {"status": to_wire(status)})
        return {}

    def _handle_device_eject(self, emit: Callable[[str, dict], None]) -> dict:
        # NOT_CONNECTED is listed as a notable error for device.eject in
        # BRIDGE.md's Methods table; CoolscanPyTransport.eject() enforces it
        # internally but MockTransport.eject() does not (it unconditionally
        # returns True), so this session-level check is required for both
        # transports to honor the documented contract identically.
        if not self._device_open:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        safety.require_armed(self._base_dir)
        if self._motion_op_active:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a motion operation is still reporting its outcome; retry",
            )
        # A concurrent scan.start already holds a HardwareLane instance in
        # this same process; flock is scoped per open file description, so
        # this second instance's __enter__ contends and raises
        # HARDWARE_LANE_BUSY on its own -- no separate "is a job active"
        # check needed here.
        with safety.HardwareLane(self._base_dir):
            self._lane_held = True
            # BRIDGE.md's SAFE-02 "Telemetry" guardrail: one JSONL line
            # before the call, one after the outcome is known -- for every
            # hardware-bound call, not just anomalies (T-08-05). Error
            # lines carry code AND message, same as roll.preview's --
            # the 2026-07-25 live failure was undiagnosable from telemetry
            # precisely because only a bare code was recorded.
            self._telemetry.record("device.eject", "started")
            try:
                ejected = bool(self._transport.eject())
            except BridgeError as exc:
                self._telemetry.record(
                    "device.eject", "error", code=exc.code.value, message=str(exc)
                )
                raise
            finally:
                self._lane_held = False
        if not ejected:
            # Contract boundary for the WIRE, independent of which Transport
            # is plugged in: a False return means the film is still inside,
            # and answering `{}` would be a silent success -- the exact
            # accepted-without-progress shape
            # INCIDENT-20260719-eject-from-park forbids. Both shipped
            # transports already raise instead of returning False; this
            # guard keeps the guarantee true for any future Transport too.
            message = "transport reported the film was not ejected"
            self._telemetry.record(
                "device.eject",
                "error",
                code=ErrorCode.EJECT_FAILED.value,
                message=message,
            )
            raise BridgeError(ErrorCode.EJECT_FAILED, message)
        # The film is out: this session no longer has a previewed roll, so
        # scan.start must gate on NO_PREVIEW again (the transport cleared
        # its own preview state; this clears the service-side copy that
        # scan.start's gate actually checks).
        self._preview_material = None
        self._telemetry.record("device.eject", "ok", ejected=True)
        # Status is emitted AFTER the lane release above, mirroring the
        # 2026-07-25 terminal-event ordering rule: a client reacting to
        # this event and polling device.status must observe the lane free.
        emit("device.status", {"status": to_wire(self._status_snapshot())})
        return {}

    # -- roll.preview / roll.approve --------------------------------------------------

    def _handle_roll_preview(self, request: dict, emit: Callable[[str, dict], None]) -> dict:
        # NOT_CONNECTED is listed as a notable error for roll.preview in
        # BRIDGE.md's Methods table, alongside HW_MOTION_NOT_ARMED and
        # HARDWARE_LANE_BUSY -- both of which are already checked
        # synchronously below. Checking here (before the lane is even
        # acquired) keeps the same "the request itself is answered
        # immediately" guarantee for this error, and avoids a NOT_CONNECTED
        # raised inside preview() reaching an already-detached worker
        # thread, where no one is left to report it back to the client.
        if not self._device_open:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        safety.require_armed(self._base_dir)

        params = request["params"]
        material_value = _require_string(params["material"], "material", maximum_length=64)
        try:
            material = domain.Material(material_value)
        except ValueError as exc:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"material has unsupported value {material_value!r}",
            ) from exc
        slots = params.get("slots")
        if slots is not None:
            slots = _require_int_list(
                slots,
                "slots",
                minimum_length=1,
                maximum_length=40,
                item_minimum=1,
                item_maximum=40,
                unique=True,
            )

        if self._motion_op_active:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a motion operation is still reporting its outcome; retry",
            )
        lane = safety.HardwareLane(self._base_dir)
        lane.__enter__()  # contention -> HARDWARE_LANE_BUSY, synchronously, before any thread starts
        self._lane_held = True
        self._motion_op_active = True
        # `self._preview_material` is deliberately NOT set here (2026-07-25
        # adversarial-review finding): committing it at acceptance meant a
        # FAILED preview left the service claiming a preview material --
        # scan.start's NO_PREVIEW gate then passed on bridge state that only
        # the transport's own second check caught. The worker commits it on
        # success only.

        transport = self._transport
        telemetry = self._telemetry
        # BRIDGE.md's SAFE-02 "Telemetry" guardrail: one JSONL line before
        # the call, one after the outcome is known -- for every
        # hardware-bound call, not just anomalies (T-08-05).
        telemetry.record("roll.preview", "started", material=material.value)

        def worker() -> None:
            # The hardware lane guards `transport.preview` itself, not the
            # bookkeeping that follows it -- emitting the terminal event and
            # recording its telemetry are not hardware operations, so both
            # are captured into plain locals here and only actually sent
            # AFTER the lane is released in `finally` below, on every path:
            # success, a typed BridgeError, or a genuinely unexpected
            # exception. Live-debugged 2026-07-25: the GUI engine reacts to
            # roll.previewComplete/roll.previewError by immediately
            # dispatching device.status on the bridge's dispatch thread; when
            # that poll could still observe `self._lane_held == True` (as it
            # could here, since the event used to fire before this
            # function's `finally` released the lane), the app rendered
            # "Scanner busy" forever, with no later re-poll to correct it --
            # confirmed live by `flock` showing the lane already free. Only
            # the ORDERING changed below; every event payload and telemetry
            # field is unchanged from before this fix.
            try:
                try:
                    result = transport.preview(
                        material,
                        slots,
                        on_thumbnail=lambda t: emit("roll.thumbnail", {"thumbnail": _thumbnail_to_wire(t)}),
                    )
                except BridgeError as exc:
                    # A worker exception with no except clause dies silently and the
                    # client sees nothing (or fabricates a completion) -- surface the
                    # real failure on the wire instead. Live-debugged 2026-07-23:
                    # CoolscanPy's detection raises (e.g. RollSessionError "no
                    # scanner-addressable slots") rather than returning empty.
                    event_name = "roll.previewError"
                    event_payload = {"code": exc.code.value, "message": str(exc)}
                    telemetry_outcome = "error"
                    telemetry_kwargs = {
                        "material": material.value, "code": exc.code.value, "message": str(exc),
                    }
                except Exception as exc:  # noqa: BLE001 -- boundary: every failure must reach the wire
                    event_name = "roll.previewError"
                    event_payload = {
                        "code": ErrorCode.INTERNAL.value,
                        "message": f"{type(exc).__name__}: {exc}",
                    }
                    telemetry_outcome = "error"
                    telemetry_kwargs = {
                        "material": material.value,
                        "code": ErrorCode.INTERNAL.value,
                        "message": f"{type(exc).__name__}: {exc}",
                    }
                else:
                    event_name = "roll.previewComplete"
                    event_payload = {"count": result.count, "fingerprint": result.fingerprint}
                    telemetry_outcome = "ok"
                    telemetry_kwargs = {"material": material.value, "count": result.count}
                    # Success-only commit -- see the acceptance-time comment.
                    self._preview_material = material
            finally:
                self._lane_held = False
                lane.__exit__(None, None, None)

            try:
                emit(event_name, event_payload)
                telemetry.record("roll.preview", telemetry_outcome, **telemetry_kwargs)
            finally:
                # Cleared strictly AFTER the terminal event was handed to
                # `emit` -- and unconditionally, so a raising emit (dead
                # pipe) can never leave the gate stuck at True, which would
                # be a permanent HARDWARE_LANE_BUSY.
                self._motion_op_active = False

        threading.Thread(target=worker, daemon=True).start()
        return {"accepted": True}

    # -- roll.manualFrames (Rung 4) --------------------------------------------------

    def _handle_roll_manual_frames(self, request: dict) -> dict:
        # Same NOT_CONNECTED/HARDWARE_LANE_BUSY shape as roll.setSpacingOffset
        # (both non-motion-capable, synchronous) -- deliberately NOT gated on
        # self._preview_material being set: manual placement's whole reason
        # to exist is re-slicing a preview attempt that may have FAILED
        # (never set self._preview_material at all). The transport itself
        # raises NO_PREVIEW when no preview attempt exists on disk at all.
        if not self._device_open:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        if self._motion_op_active:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a motion operation is still active; retry after it finishes",
            )
        params = request["params"]
        raw_rows = params["rows"]
        # Strict wire check (adversarial review 2026-08-08, F8a): int() would
        # silently truncate JSON floats, explode a string into digits, and
        # turn a non-numeric into an INTERNAL error. The driver's own gates
        # are strict; the wire deserves the same.
        rows = _require_int_list(
            raw_rows,
            "rows",
            minimum_length=2,
            maximum_length=41,
            item_minimum=0,
            item_maximum=2**31 - 1,
            unique=True,
        )
        if any(left >= right for left, right in zip(rows, rows[1:])):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                "rows must be strictly increasing",
            )
        preview_result, thumbnails, snaps, material = self._transport.manual_frames(
            rows
        )
        # manual_frames() arms a usable session exactly like a successful
        # roll.preview does, but carries no material param of its own (the
        # session already has one) -- scan.start's own NO_PREVIEW gate
        # (self._preview_material) is re-armed here, from the transport's
        # answer, instead of from this request's params.
        self._preview_material = material
        return {
            "count": preview_result.count,
            "fingerprint": preview_result.fingerprint,
            "thumbnails": [_thumbnail_to_wire(t) for t in thumbnails],
            "snaps": [to_wire(s) for s in snaps],
        }

    # -- scan.start / scan.stop --------------------------------------------------------

    def _handle_scan_start(self, request: dict, emit: Callable[[str, dict], None]) -> dict:
        # See _handle_roll_preview: same reasoning for checking NOT_CONNECTED
        # synchronously. NO_PREVIEW is also listed as a notable error for
        # scan.start -- self._preview_material is exactly the state
        # roll.preview records for this purpose (BRIDGE.md: "scan.start"
        # requires a completed roll.preview first").
        if not self._device_open:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        if self._preview_material is None:
            raise BridgeError(
                ErrorCode.NO_PREVIEW, "scan.start requires a completed roll.preview first"
            )
        safety.require_armed(self._base_dir)

        params = request["params"]
        slots = _require_int_list(
            params["slots"],
            "slots",
            minimum_length=1,
            maximum_length=40,
            item_minimum=1,
            item_maximum=40,
            unique=True,
        )
        recipe = from_wire(params["recipe"], domain.CaptureRecipe)
        output = from_wire(params["output"], domain.OutputSpec)
        domain.validate_capture_recipe(recipe, self._preview_material)

        requested_job_id = params.get("jobId")
        if "jobId" not in params:
            job_id = uuid.uuid4().hex
        elif (
            type(requested_job_id) is not str
            or len(requested_job_id) != 32
            or any(character not in "0123456789abcdef" for character in requested_job_id)
        ):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                "jobId must be a 32-character lowercase hexadecimal operation token",
            )
        else:
            job_id = requested_job_id
        if job_id in self._seen_job_ids:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                "jobId was already used in this bridge generation",
            )

        if self._motion_op_active:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a motion operation is still reporting its outcome; retry",
            )
        lane = safety.HardwareLane(self._base_dir)
        lane.__enter__()  # contention -> HARDWARE_LANE_BUSY, synchronously, before any thread starts
        self._lane_held = True
        self._motion_op_active = True

        self._seen_job_ids.add(job_id)
        job_record: dict = {"job_id": job_id, "terminal": False}
        self._last_job = job_record

        transport = self._transport
        telemetry = self._telemetry
        # BRIDGE.md's SAFE-02 "Telemetry" guardrail: one JSONL line before
        # the call, one after the outcome is known -- for every
        # hardware-bound call, not just anomalies (T-08-05). The
        # retry-exhausted path gets its own "hardware.anomaly" entry from
        # safety.anomaly_halt below; this "ok" entry covers normal
        # completion (including a client-requested scan.stop mid-job,
        # which is still a normal, non-exhausted return from start_scan).
        telemetry.record("scan.start", "started", job_id=job_id, slots=slots)

        # Call-boundary telemetry + soft-timeout state (Plan 10-04): shared
        # between the worker thread (writes, via on_call below) and the
        # watchdog thread (reads-only, via _run_scan_soft_timeout_watchdog)
        # spawned further down. A plain dict + lock is enough -- the lock
        # exists to keep each read-or-write of the (name, entered_at) pair
        # atomic, not to protect anything more elaborate.
        call_state_lock = threading.Lock()
        call_state: dict[str, object] = {"name": None, "entered_at": None}

        def on_call(
            phase: str,
            name: str,
            elapsed_seconds: float | None,
            kind: str = "call",
            *,
            call_outcome: str | None = None,
            exception_class: str | None = None,
        ) -> None:
            # Plan 10-09: `kind` ("call" or "phase") picks scan.call vs
            # scan.phase; call_outcome/exception_class (raise-aware call
            # telemetry, coordinator scope addition) are only ever non-None
            # on an "exit" entry -- see transport/__init__.py's OnCall/
            # timed_call docstrings for the full contract.
            fields: dict[str, object] = {
                "job_id": job_id, "call": name, "elapsed_seconds": elapsed_seconds
            }
            if call_outcome is not None:
                fields["call_outcome"] = call_outcome
            if exception_class is not None:
                fields["exception_class"] = exception_class
            telemetry.record(f"scan.{kind}", phase, **fields)
            with call_state_lock:
                if phase == "enter":
                    call_state["name"] = name
                    call_state["entered_at"] = time.monotonic()
                elif call_state["name"] == name:
                    call_state["name"] = None
                    call_state["entered_at"] = None

        # Plan 10-09 (durable per-frame failure reasons): state the worker
        # (and only the worker -- never the watchdog) reads/writes while
        # handling one scan.start job.
        job_started_at = time.monotonic()
        # 2026-07-25 incident fix: slots this job has definitively resolved
        # via on_frame, in request order -- lets first_pending_slot()
        # (below) name "the earliest slot we cannot rule out" for an
        # exception that carries no slot of its own. Replaces a prior
        # last_progress_slot/on_progress-based scheme that assumed every
        # Transport calls on_progress for a slot immediately before
        # attempting it: CoolscanPyTransport.start_scan instead emits
        # on_progress for EVERY requested slot up front, in one pass,
        # before scan_many is ever called (scan_many exposes no per-slot
        # pre-attempt hook -- see its own start_scan comment), so "the last
        # slot on_progress fired for" was always the batch's LAST slot,
        # never the slot actually in flight. Live 2026-07-25: a 33-slot
        # batch ([4..36]) failed with a pre-frame RollMismatch (scan_many
        # raised before yielding any frame) and scan.frameFailed reported
        # slot 36 (the last requested), not slot 4 (the first pending, and
        # the honest answer once no frame in this batch has resolved at
        # all).
        resolved_slots: set[int] = set()
        # slot -> reason_class, accumulated as scan.frameFailed events are
        # reported; folded into the "reasons" field of whichever scan.start
        # telemetry closure below actually fires for this job.
        frame_reasons: dict[int, str] = {}
        # Plan 10-09 (attempts-root persistence, coordinator scope
        # addition): CoolscanPyTransport is the only Transport that has
        # this concept -- getattr keeps MockTransport (and any other
        # Transport double) working unchanged.
        attempts_root_path = getattr(transport, "attempts_root", None)
        attempts_root_str = str(attempts_root_path) if attempts_root_path is not None else None

        def scan_start_closure_fields() -> dict[str, object]:
            """Extra fields folded into whichever `scan.start` telemetry
            entry closes out this job (`"ok"` or `"error"`) -- `"reasons"`
            (Plan 10-09 deliverable 1) only when at least one slot's
            failure reason is already known, `"attempts_root"` (Plan 10-09
            coordinator scope addition) whenever this Transport has one.
            Both additive: the entry's pre-existing shape
            (`job_id`/`completed`/`failed`/`stopped` for "ok",
            `job_id`/`code` for "error") is unchanged."""
            fields: dict[str, object] = {}
            if frame_reasons:
                fields["reasons"] = dict(frame_reasons)
            if attempts_root_str is not None:
                fields["attempts_root"] = attempts_root_str
            return fields

        def emit_frame_failed(
            slot: int,
            *,
            reason_class: str,
            reason_message: str,
            code: str,
            extra_attributes: dict[str, object] | None = None,
            attribution: str | None = None,
        ) -> None:
            """Deliverable 1 (durable per-frame failure reasons): one
            `scan.frameFailed` telemetry entry (slot, reason_class,
            reason_message, elapsed since this job's worker started) and
            one `scan.frameFailed` wire event ({jobId, slot, code,
            message}), emitted BEFORE scan.completed -- BRIDGE.md's Events
            section documents this as additive. Shared by every failure
            source this worker recognizes (an exception path via
            report_frame_failure below, or a per-slot skip a Transport
            already folded into ScanSummary.failure_reasons, e.g.
            ManualReviewRequired) so all of them produce an identical
            shape.

            `attribution` (2026-07-25 incident fix, additive): passed only
            by first_pending_slot()'s callers, and only when more than one
            requested slot was still unresolved at failure time -- i.e.
            `slot` is a best-effort pick among several equally-plausible
            candidates, not a confirmed one (unlike FrameRetryExhausted's
            or ManualReviewRequired's own `.slot`). Folded into both the
            telemetry entry and the wire event when present; omitted
            entirely otherwise (`None` default), so every pre-existing
            single-slot-batch caller keeps producing byte-identical
            output. An unrecognized extra wire field is ignored by a
            client per BRIDGE.md's forward-compatibility rule -- same
            precedent as hardware.anomaly's own "laneReleased" extra field
            elsewhere in this module."""
            extra_telemetry: dict[str, object] = dict(extra_attributes or {})
            if attribution is not None:
                extra_telemetry["attribution"] = attribution
            telemetry.record(
                "scan.frameFailed",
                "failed",
                job_id=job_id,
                slot=slot,
                reason_class=reason_class,
                reason_message=reason_message,
                elapsed=time.monotonic() - job_started_at,
                **extra_telemetry,
            )
            wire_payload: dict[str, object] = {
                "jobId": job_id, "slot": slot, "code": code, "message": reason_message,
            }
            if attribution is not None:
                wire_payload["attribution"] = attribution
            emit("scan.frameFailed", wire_payload)
            frame_reasons[slot] = reason_class

        def report_frame_failure(
            slot: int,
            reason_exc: BaseException,
            code: str,
            *,
            attribution: str | None = None,
        ) -> None:
            """`emit_frame_failed` from a raised exception: captures the
            exception's class + message + (if present) coolscanpy error
            attributes via `_coolscanpy_error_attributes`. `reason_exc` is
            the actual underlying fault -- for `FrameRetryExhausted` this
            is `exc.last_error` (the real transport exception, matching
            `safety.anomaly_halt`'s own `reason=str(exc.last_error)`
            convention below), for a `BridgeError` CoolscanPyTransport
            chained via `raise ... from exc` this is `exc.__cause__` (the
            original coolscanpy exception, recovered via Python's own
            exception-chaining), falling back to the `BridgeError` itself
            when it was raised bridge-natively (no chained cause)."""
            reason_message = str(reason_exc)
            if code == ErrorCode.FILM_FEED_INTERRUPTED.value:
                reason_message = (
                    f"Film feed interrupted while positioning frame {slot}. "
                    "The scanner no longer detected film (02/3A/00). Refeed "
                    "the film and acquire a fresh preview before resuming. "
                    f"Scanner diagnostic: {reason_message}"
                )
            emit_frame_failed(
                slot,
                reason_class=type(reason_exc).__name__,
                reason_message=reason_message,
                code=code,
                extra_attributes=_coolscanpy_error_attributes(reason_exc),
                attribution=attribution,
            )

        def on_progress(progress: domain.ScanProgress) -> None:
            emit("scan.progress", to_wire(dataclasses.replace(progress, job_id=job_id)))

        def on_frame(slot: int, receipt: domain.ScanReceipt) -> None:
            # Marks `slot` resolved for first_pending_slot() below, in
            # addition to this callback's pre-existing job of reporting the
            # slot's own scan.frameCompleted event.
            resolved_slots.add(slot)
            emit(
                "scan.frameCompleted",
                {"jobId": job_id, "slot": slot, "receipt": to_wire(receipt)},
            )

        def first_pending_slot() -> tuple[int | None, bool]:
            """Earliest requested slot not yet confirmed complete via
            on_frame -- the honest replacement for the old
            on_progress-based current_fail_slot() (see resolved_slots' own
            comment above for why that scheme broke) for an exception that
            carries no slot of its own (every BridgeError/generic
            Exception transport.start_scan can raise, unlike
            FrameRetryExhausted's own `.slot`).

            Returns `(slot, ambiguous)`: `ambiguous` is True when more than
            one requested slot was still unresolved, meaning `slot` was
            picked among several equally-plausible candidates rather than
            confirmed; False when it's the only candidate left (a
            single-slot batch, or every other slot already resolved),
            which carries the same confidence FrameRetryExhausted's own
            `remaining[0]` convention already relies on elsewhere in this
            codebase (coolscanpy_transport.py's start_scan). `(None,
            False)` only for the degenerate case of an empty `slots`
            list."""
            pending = [slot for slot in slots if slot not in resolved_slots]
            if not pending:
                return None, False
            return pending[0], len(pending) > 1

        def worker() -> None:
            # Never-silent guarantee (Plan 10-05, LIVE-VERIFICATION-20260723.md
            # attempt #2: hw-telemetry proved `roll.scan:slot1` entered and
            # exited in 0.55s -- too fast for real motion, meaning
            # transport.start_scan RAISED -- and the worker then emitted
            # nothing at all, forever). `summary` is now assigned before the
            # transport call and on every single exit path below, so
            # `to_wire(summary)` in `finally` can never see an undefined
            # name. The actual bug: the old code only ever assigned `summary`
            # inside the `try` or the `except FrameRetryExhausted` branch, so
            # ANY OTHER exception -- every other BridgeError
            # CoolscanPyTransport.start_scan can raise (FEEDER_PARKED,
            # FINGERPRINT_REFUSED, REFEED_REQUIRED, GEOMETRY_VALIDATION_ERROR,
            # SPLIT_ALIGNMENT_ERROR, BATCH_INTEGRITY_ERROR, NOT_IMPLEMENTED,
            # INVALID_PARAMS), or a genuinely unexpected one -- skipped both
            # assignments, fell into `finally`, and hit
            # `to_wire(summary)` -> `UnboundLocalError`, which silently
            # killed this daemon thread with zero wire output and zero
            # telemetry for the failure itself.
            summary = domain.ScanSummary(completed=(), failed=tuple(slots), stopped=False)
            # Live-debugged 2026-07-25 (same race as _handle_roll_preview's
            # worker above): the hardware lane guards transport.start_scan
            # itself, not the bookkeeping that follows it, so the closing
            # "scan.start" telemetry entry and the scan.error event (when
            # either fires) are captured into these two locals instead of
            # being sent immediately, and are only actually recorded/emitted
            # from the shared `finally` below, AFTER the lane is released.
            # scan.completed is unaffected in shape -- still unconditional,
            # still built from `summary` -- only its position relative to
            # the lane release moves. Per-frame events (scan.progress,
            # scan.frameRetrying, scan.frameCompleted, scan.frameFailed) and
            # hardware.anomaly are untouched: they report on things that
            # happen *during* the still-in-flight call (including
            # anomaly_halt's own transport.eject(), a real hardware
            # operation that still needs the lane held), not on the job's
            # own conclusion.
            closing_telemetry: tuple[str, dict[str, object]] | None = None
            scan_error_payload: dict[str, object] | None = None
            try:
                try:
                    result = transport.start_scan(
                        slots,
                        recipe,
                        output,
                        on_progress=on_progress,
                        on_retry=lambda slot, attempt, reason: emit(
                            "scan.frameRetrying",
                            {"jobId": job_id, "slot": slot, "attempt": attempt, "reason": reason},
                        ),
                        on_frame=on_frame,
                        on_call=on_call,
                    )
                    if not isinstance(result, domain.ScanSummary) or (
                        slots
                        and not result.completed
                        and not result.failed
                        and not result.stopped
                    ):
                        # A Transport is only ever supposed to fail by
                        # raising -- a None/wrong-shaped return, or a
                        # ScanSummary that accounts for none of the requested
                        # slots (not completed, not failed, not stopped), is
                        # itself a silent-failure shape indistinguishable
                        # from this same defect at the wire level unless
                        # flagged explicitly here.
                        closing_telemetry = (
                            "error",
                            {
                                "job_id": job_id,
                                "code": ErrorCode.INTERNAL.value,
                                "reason": f"transport.start_scan returned {result!r}",
                            },
                        )
                        scan_error_payload = {
                            "jobId": job_id,
                            "code": ErrorCode.INTERNAL.value,
                            "message": (
                                f"transport.start_scan returned {result!r}, which "
                                f"accounts for none of the requested slots {slots}"
                            ),
                        }
                    else:
                        summary = result
                        # Plan 10-09 deliverable 1 + coordinator scope
                        # addition #1: a slot the Transport already folded
                        # into `failed` without raising (today only
                        # ManualReviewRequired -- see
                        # coolscanpy_transport.py's start_scan) still gets a
                        # scan.frameFailed event/telemetry entry, BEFORE the
                        # "ok" closure below, exactly like every
                        # exception-driven failure this plan instruments.
                        for fail_slot, reason in sorted(summary.failure_reasons.items()):
                            emit_frame_failed(
                                fail_slot,
                                reason_class=reason["reason_class"],
                                reason_message=reason["reason_message"],
                                code=reason["code"],
                            )
                        closing_telemetry = (
                            "ok",
                            {
                                "job_id": job_id,
                                "completed": list(summary.completed),
                                "failed": list(summary.failed),
                                "stopped": summary.stopped,
                                **scan_start_closure_fields(),
                            },
                        )
                except FrameRetryExhausted as exc:
                    # Plan 10-09 deliverable 1: names this slot's exact
                    # cause via the underlying transport exception
                    # (exc.last_error), same source safety.anomaly_halt's
                    # own "reason" below already uses -- BEFORE the
                    # existing hardware.anomaly event, so a telemetry/wire
                    # reader sees "the specific frame that failed and why"
                    # ahead of "the broader safety response that
                    # followed".
                    report_frame_failure(
                        exc.slot, exc.last_error, ErrorCode.TRANSPORT_SMEAR_DETECTED.value
                    )
                    anomaly = safety.anomaly_halt(
                        transport,
                        telemetry,
                        reason=str(exc.last_error),
                        code=ErrorCode.TRANSPORT_SMEAR_DETECTED.value,
                        slot=exc.slot,
                    )
                    # BRIDGE.md's hardware.anomaly event is
                    # {jobId, slot, code, message, ejected}; anomaly_halt's
                    # return dict uses "reason" (not "message") and has no
                    # jobId, so it's reshaped here rather than spread
                    # directly. laneReleased is an extra, forward-compatible
                    # field (BRIDGE.md: "both sides must ignore unknown
                    # fields") -- true the instant this worker's finally
                    # block below runs, moments after this event is queued.
                    # Unmoved by the 2026-07-25 lane-release reorder below:
                    # this event reports on anomaly_halt's own
                    # transport.eject() a moment ago, a real hardware
                    # operation that still needed the lane held, not on the
                    # job's conclusion -- scan.completed (shared finally,
                    # below) is that signal, and it is what moves.
                    emit(
                        "hardware.anomaly",
                        {
                            "jobId": job_id,
                            "slot": anomaly["slot"],
                            "code": anomaly["code"],
                            "message": anomaly["reason"],
                            "ejected": anomaly["ejected"],
                            "laneReleased": True,
                        },
                    )
                    summary = domain.ScanSummary(
                        completed=(), failed=(exc.slot,), stopped=False
                    )
                except BridgeError as exc:
                    # Every other failure CoolscanPyTransport.start_scan can
                    # raise arrives here as a BridgeError -- this is the
                    # exact gap that swallowed the live 2026-07-23 0.55s
                    # roll.scan:slot1 failure (most likely
                    # coolscanpy.RefeedRequired -- see the Plan 10-05 SUMMARY
                    # for the full root-cause writeup). Mirrors
                    # _handle_roll_preview's own worker's roll.previewError
                    # handling above, adapted to scan.start's additive
                    # scan.error event (BRIDGE.md: unlike roll.previewError,
                    # scan.error does not replace scan.completed).
                    #
                    # Plan 10-09 deliverable 1: names the specific failing
                    # slot via first_pending_slot() and reports its exact
                    # cause -- exc.__cause__ when CoolscanPyTransport chained
                    # a coolscanpy exception via `raise ... from exc` (the
                    # common case: recovers the real coolscanpy exception
                    # class/attributes Python's own chaining already
                    # preserved), falling back to the BridgeError itself
                    # when it was raised bridge-natively with no chained
                    # cause (e.g. INVALID_PARAMS from a path-traversal
                    # check) -- BEFORE the existing scan.error event.
                    #
                    # 2026-07-25 incident fix: first_pending_slot() reports
                    # `ambiguous=True` whenever more than one requested slot
                    # was still unresolved -- e.g. a whole-batch RollMismatch
                    # raised from scan_many before any frame in the batch
                    # yielded, where every requested slot is equally
                    # "pending". Tagging the event with the additive
                    # "attribution": "batch-pre-frame" field keeps
                    # scan.frameFailed useful (still names a slot) without
                    # implying a confirmed per-slot cause the bridge cannot
                    # actually vouch for.
                    if exc.code is ErrorCode.FILM_FEED_INTERRUPTED:
                        self._preview_material = None
                    fail_slot, ambiguous = first_pending_slot()
                    if fail_slot is not None:
                        report_frame_failure(
                            fail_slot,
                            exc.__cause__ or exc,
                            exc.code.value,
                            attribution=_BATCH_PRE_FRAME_ATTRIBUTION if ambiguous else None,
                        )
                    closing_telemetry = (
                        "error",
                        {
                            "job_id": job_id,
                            "code": exc.code.value,
                            "message": str(exc),
                            **scan_start_closure_fields(),
                        },
                    )
                    scan_error_payload = {
                        "jobId": job_id, "code": exc.code.value, "message": str(exc)
                    }
                    summary = domain.ScanSummary(
                        completed=tuple(slot for slot in slots if slot in resolved_slots),
                        failed=tuple(slot for slot in slots if slot not in resolved_slots),
                        stopped=False,
                    )
                except Exception as exc:  # noqa: BLE001 -- boundary: every failure must reach the wire
                    # Plan 10-09 deliverable 1: same first_pending_slot()
                    # attribution as the BridgeError branch above (see its
                    # own 2026-07-25 incident-fix comment); this is a
                    # genuinely unexpected exception type, so there is no
                    # chained cause to recover -- reason_class is exc's own
                    # class (e.g. "RuntimeError").
                    fail_slot, ambiguous = first_pending_slot()
                    if fail_slot is not None:
                        report_frame_failure(
                            fail_slot,
                            exc,
                            ErrorCode.INTERNAL.value,
                            attribution=_BATCH_PRE_FRAME_ATTRIBUTION if ambiguous else None,
                        )
                    closing_telemetry = (
                        "error",
                        {
                            "job_id": job_id,
                            "code": ErrorCode.INTERNAL.value,
                            "message": f"{type(exc).__name__}: {exc}",
                            **scan_start_closure_fields(),
                        },
                    )
                    scan_error_payload = {
                        "jobId": job_id,
                        "code": ErrorCode.INTERNAL.value,
                        "message": f"{type(exc).__name__}: {exc}",
                    }
                    summary = domain.ScanSummary(
                        completed=(), failed=tuple(slots), stopped=False
                    )
            finally:
                job_record["terminal"] = True
                # Lane release now happens BEFORE any of scan.start's closing
                # telemetry, scan.error, or scan.completed -- previously all
                # three could reach the wire/log while self._lane_held was
                # still True and the flock still held, racing a GUI that
                # reacts to scan.completed by immediately polling
                # device.status (2026-07-25 live incident, same root cause as
                # _handle_roll_preview's worker above). The lane guards
                # transport.start_scan only; nothing below this point is a
                # hardware operation.
                self._lane_held = False
                lane.__exit__(None, None, None)
                try:
                    if closing_telemetry is not None:
                        outcome, fields = closing_telemetry
                        telemetry.record("scan.start", outcome, **fields)
                    if scan_error_payload is not None:
                        emit("scan.error", scan_error_payload)
                    # Built by hand rather than `to_wire(summary)`: BRIDGE.md's
                    # scan.completed documents exactly {completed, failed,
                    # stopped} for `summary` -- ScanSummary's own
                    # `failure_reasons` (Plan 10-09, internal-only; see its
                    # field docstring in domain.py) must never leak onto the
                    # wire through this event, even though `to_wire` would
                    # otherwise happily serialize it like every other dataclass
                    # field.
                    emit(
                        "scan.completed",
                        {
                            "jobId": job_id,
                            "summary": {
                                "completed": list(summary.completed),
                                "failed": list(summary.failed),
                                "stopped": summary.stopped,
                            },
                        },
                    )
                finally:
                    # Cleared strictly AFTER scan.completed was handed to
                    # `emit` (see _motion_op_active's __init__ comment), and
                    # unconditionally, so a raising emit can never leave the
                    # gate stuck.
                    self._motion_op_active = False

        job_record["thread"] = threading.Thread(target=worker, daemon=True)
        job_record["thread"].start()

        # Soft-timeout watchdog (Plan 10-04): a separate thread, never the
        # worker's own -- it only ever reads job_record/call_state and
        # calls telemetry/emit, so a stuck worker can never block it, and
        # it can never block or touch the worker in return.
        threading.Thread(
            target=_run_scan_soft_timeout_watchdog,
            kwargs={
                "job_record": job_record,
                "call_state": call_state,
                "call_state_lock": call_state_lock,
                "telemetry": telemetry,
                "emit": emit,
                "job_id": job_id,
                "timeout_seconds": _scan_timeout_seconds(),
            },
            daemon=True,
        ).start()

        return {"jobId": job_id}

    def _handle_scan_stop(self, request: dict) -> dict:
        params = request["params"]
        job_id = _require_string(params["jobId"], "jobId", maximum_length=128)
        if self._last_job is None or self._last_job["job_id"] != job_id:
            raise BridgeError(ErrorCode.UNKNOWN_JOB, f"unknown job id: {job_id!r}")
        if self._last_job["terminal"]:
            return {"acknowledged": False}
        self._transport.request_stop()
        return {"acknowledged": True}
