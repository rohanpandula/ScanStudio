"""NDJSON stdin/stdout dispatch loop and the `scanstudio-bridge` console
entry point (`[project.scripts]` in pyproject.toml). Mirrors
`app/ScanStudio/engine/src/server.rs`'s `run()` loop
(nikon-coolscan4-software-archaeology, this repo's own Phase 1 engine): one
blocking stdin-read loop on the main thread, one dedicated stdout-writer
thread fed by a queue (every write pre-serialized JSON, flushed after every
line). See BRIDGE.md (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md) for the wire-level transport contract
this loop implements.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
from pathlib import Path

from scanstudio_bridge import protocol, safety, service
from scanstudio_bridge.transport.coolscanpy_transport import (
    CoolscanPyTransport,
    coolscanpy_provenance,
)
from scanstudio_bridge.transport.mock import MockTransport

_WRITER_JOIN_TIMEOUT_SECONDS = 5.0


def _best_effort_id(line: str) -> object | None:
    """Best-effort recovery of just the `id` field from an
    otherwise-malformed request line, so a proper `{id, error}` response can
    still be sent instead of silently dropping the line. Mirrors
    server.rs's `best_effort_id`. Genuinely broken JSON syntax can never be
    parsed for any field, id included -- this only helps when the line is
    valid JSON that just doesn't match the expected request shape."""
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return None
    if isinstance(data, dict) and "id" in data:
        return data["id"]
    return None


def _queue_line(out_queue: "queue.Queue[str | None]", payload: dict) -> None:
    out_queue.put(json.dumps(payload, separators=(",", ":")))


def main() -> None:
    transport_kind = os.environ.get("SCANSTUDIO_BRIDGE_TRANSPORT", "coolscanpy")
    transport = MockTransport() if transport_kind == "mock" else CoolscanPyTransport()

    # SCANSTUDIO_BRIDGE_BASE_DIR lets a verification run (scripts/smoke_bridge.sh,
    # this module's own test suite) redirect SAFE-02's latch/lane/telemetry
    # files away from the real ~/.scanstudio; unset in production, where
    # safety.DEFAULT_BASE_DIR (~/.scanstudio) is exactly what SAFE-02 requires.
    base_dir = Path(
        os.environ.get("SCANSTUDIO_BRIDGE_BASE_DIR", str(safety.DEFAULT_BASE_DIR))
    )
    process_ownership = safety.BridgeProcessOwnership(base_dir)
    try:
        process_ownership.acquire()
    except protocol.BridgeError as err:
        print(f"scanstudio-bridge: ownership refused: {err.message}", file=sys.stderr)
        sys.exit(2)
    telemetry = safety.TelemetryLog(base_dir)
    # Plan 10-09 (provenance header): recorded at bridge startup, before the
    # stdin loop reads even the first request (bridge.hello has no
    # telemetry entry of its own to extend -- see _handle_hello in
    # service.py -- so this is the new "bridge.provenance" entry instead).
    # Unconditional regardless of SCANSTUDIO_BRIDGE_TRANSPORT: `coolscanpy`
    # is already imported transitively by CoolscanPyTransport above (this
    # module never imports it directly, preserving that module's "one file
    # imports coolscanpy" invariant), so reporting on it costs nothing extra
    # even when transport_kind == "mock". Closes today's stale-wheel
    # blindspot: this repo's own pyproject.toml documents a real incident
    # where an unchanged version string masked a stale cached build.
    telemetry.record("bridge.provenance", "ok", **coolscanpy_provenance())
    bridge_service = service.BridgeService(transport, telemetry, base_dir=base_dir)

    out_queue: "queue.Queue[str | None]" = queue.Queue()

    def writer() -> None:
        # The only thread that ever writes to stdout. Producers (this
        # function's caller for responses, worker threads inside service.py
        # for events) serialize their own JSON before sending it here, so
        # this loop is a trivial, panic-resistant write-and-flush -- mirrors
        # server.rs's writer thread, including stopping quietly on a
        # broken pipe rather than raising.
        while True:
            line = out_queue.get()
            if line is None:
                return
            try:
                sys.stdout.write(line)
                sys.stdout.write("\n")
                sys.stdout.flush()
            except OSError:
                return

    writer_thread = threading.Thread(target=writer, daemon=True)
    writer_thread.start()

    def emit(event: str, payload: object) -> None:
        _queue_line(out_queue, {"event": event, "payload": protocol.to_wire(payload)})

    shutdown_completed = False
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            request = protocol.read_request(line)
        except json.JSONDecodeError as exc:
            print(
                f"scanstudio-bridge: malformed request line, skipping: {exc}",
                file=sys.stderr,
            )
            recovered_id = _best_effort_id(line)
            if recovered_id is not None:
                _queue_line(
                    out_queue,
                    {
                        "id": recovered_id,
                        "error": {
                            "code": "INTERNAL",
                            "message": "malformed request line",
                            "recoverable": False,
                        },
                    },
                )
            continue

        if not isinstance(request, dict):
            print(
                f"scanstudio-bridge: request line is not a JSON object, skipping: {line!r}",
                file=sys.stderr,
            )
            continue

        try:
            result = bridge_service.dispatch(request, emit)
            _queue_line(out_queue, {"id": request.get("id"), "result": result})
            if request.get("method") == "bridge.shutdown":
                shutdown_completed = True
                break
        except protocol.BridgeError as err:
            _queue_line(
                out_queue,
                {
                    "id": request.get("id"),
                    "error": {
                        "code": err.code.value,
                        "message": err.message,
                        "recoverable": err.recoverable,
                    },
                },
            )
        except Exception as exc:  # noqa: BLE001 -- T-08-02: never let a request line crash the process
            print(
                f"scanstudio-bridge: unexpected error handling request: {exc}",
                file=sys.stderr,
            )
            _queue_line(
                out_queue,
                {
                    "id": request.get("id"),
                    "error": {
                        "code": "INTERNAL",
                        "message": str(exc),
                        "recoverable": False,
                    },
                },
            )

    # On parent loss/EOF, remain the worker's owner until cooperative
    # cleanup really finishes. A successful bridge.shutdown already proved
    # the same condition before its acknowledgement was queued.
    if not shutdown_completed:
        bridge_service.wait_for_owned_work_before_exit()

    out_queue.put(None)
    writer_thread.join(timeout=_WRITER_JOIN_TIMEOUT_SECONDS)
    process_ownership.close()
    sys.exit(0)


if __name__ == "__main__":
    main()
