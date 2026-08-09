#!/usr/bin/env python3
"""Deterministic NDJSON engine double. It never imports or touches scanner code."""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any


def emit(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def simulated_device() -> dict[str, Any]:
    return {
        "deviceId": "sim-ls5000-0",
        "model": "SUPER COOLSCAN 5000 ED",
        "kind": "simulated",
        "firmware": "1.03-sim",
        "connection": "USB (simulated)",
    }


def status(*, connected: bool, media: bool = False) -> dict[str, Any]:
    return {
        "connected": connected,
        "adapter": "SA-21 (simulated)" if connected else None,
        "mediaLoaded": media,
        "carrier": "strip6" if media else None,
        "frameCount": 6 if media else None,
        "lamp": "stable" if connected else "off",
        "transport": "idle",
        "activeJobId": None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="normal")
    parser.add_argument("--request-log", type=Path)
    parser.add_argument("--env-log", type=Path)
    args = parser.parse_args()

    if args.env_log:
        args.env_log.write_text(
            json.dumps(
                {
                    "bridge": os.environ.get("SCANSTUDIO_BRIDGE_CMD"),
                    "motion": os.environ.get("SCANSTUDIO_HW_MOTION"),
                    "gatewayKeys": sorted(
                        name
                        for name in os.environ
                        if name.startswith("SCANSTUDIO_WEB_")
                    ),
                    "engineSentinel": os.environ.get(
                        "SCANSTUDIO_ENGINE_TEST_SENTINEL"
                    ),
                }
            ),
            encoding="utf-8",
        )

    hello_seen = False
    connected = False
    media_loaded = False
    pending_status: dict[str, Any] | None = None
    output_lock = threading.Lock()

    def safe_emit(message: dict[str, Any]) -> None:
        with output_lock:
            emit(message)

    for raw_line in sys.stdin:
        if args.request_log:
            with args.request_log.open("a", encoding="utf-8") as handle:
                handle.write(raw_line)
        try:
            request = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        request_id = request["id"]
        method = request["method"]
        params = request.get("params", {})

        if not hello_seen and method != "engine.hello":
            safe_emit(
                {
                    "id": request_id,
                    "error": {
                        "code": "INVALID_PARAMS",
                        "message": "engine.hello must be the first request",
                        "recoverable": False,
                    },
                }
            )
            continue

        if method == "engine.hello":
            hello_seen = True
            version = 2 if args.mode == "bad-hello" else 1
            safe_emit(
                {
                    "id": request_id,
                    "result": {
                        "engineName": "scanstudio-engine",
                        "engineVersion": "fake-0.1",
                        "protocolVersion": version,
                        "capabilities": ["simulated-ls5000"],
                    },
                }
            )
            continue

        if method == "engine.shutdown":
            if args.mode == "ignore-shutdown":
                continue
            safe_emit({"id": request_id, "result": {}})
            return 0

        if method == "scanner.list":
            devices = [simulated_device()]
            if args.mode == "real-device":
                devices.append(
                    {
                        "deviceId": "nikon-ls5000-real-0",
                        "kind": "real",
                        "model": "unexpected real device",
                    }
                )
            safe_emit({"id": request_id, "result": {"devices": devices}})
            continue

        if args.mode == "malformed" and method == "scanner.status":
            sys.stdout.write("{this-is-not-json}\n")
            sys.stdout.flush()
            continue

        if args.mode == "exit-on-status" and method == "scanner.status":
            return 17

        if args.mode == "out-of-order" and method == "scanner.status":
            if pending_status is None:
                pending_status = request
                continue
            safe_emit(
                {
                    "id": request_id,
                    "result": {"sequence": params.get("sequence")},
                }
            )
            safe_emit(
                {
                    "id": pending_status["id"],
                    "result": {
                        "sequence": pending_status.get("params", {}).get("sequence")
                    },
                }
            )
            pending_status = None
            continue

        if method == "scanner.connect":
            connected = True
            current = status(connected=True)
            safe_emit({"event": "scanner.status", "payload": {"status": current}})
            safe_emit(
                {
                    "id": request_id,
                    "result": {"device": simulated_device(), "status": current},
                }
            )
            continue

        if method == "scanner.status":
            if not connected:
                safe_emit(
                    {
                        "id": request_id,
                        "error": {
                            "code": "NOT_CONNECTED",
                            "message": "scanner is not connected",
                            "recoverable": False,
                            "fakeDetail": "preserve-me",
                        },
                    }
                )
            else:
                safe_emit(
                    {
                        "id": request_id,
                        "result": status(connected=True, media=media_loaded),
                    }
                )
            continue

        if method == "sim.loadMedia":
            media_loaded = True
            current = status(connected=True, media=True)
            safe_emit({"event": "scanner.status", "payload": {"status": current}})
            safe_emit({"id": request_id, "result": current})
            continue

        if method == "scanner.acquireThumbnails":
            frames = params.get("frames") or list(range(1, 7))
            safe_emit(
                {"id": request_id, "result": {"accepted": True, "frames": frames}}
            )
            operation_id = params.get("operationId")
            for frame in frames:
                payload: dict[str, Any] = {
                    "frameIndex": frame,
                    "thumbnail": {"brightness": 0.5, "tint": 0.0},
                }
                if operation_id is not None:
                    payload["operationId"] = operation_id
                safe_emit({"event": "scanner.thumbnail", "payload": payload})
            safe_emit(
                {
                    "event": "scanner.thumbnailsComplete",
                    "payload": {
                        "frames": frames,
                        **(
                            {"operationId": operation_id}
                            if operation_id is not None
                            else {}
                        ),
                    },
                }
            )
            continue

        if method == "scanner.disconnect":
            connected = False
            media_loaded = False
            safe_emit(
                {
                    "event": "scanner.status",
                    "payload": {"status": status(connected=False)},
                }
            )
            safe_emit({"id": request_id, "result": {}})
            continue

        if method == "test.delayed":
            delay = float(params.get("seconds", 0.2))
            threading.Thread(
                target=lambda: (
                    time.sleep(delay),
                    safe_emit({"id": request_id, "result": {}}),
                ),
                daemon=True,
            ).start()
            continue

        safe_emit(
            {
                "id": request_id,
                "error": {
                    "code": "UNKNOWN_METHOD",
                    "message": method,
                    "recoverable": False,
                },
            }
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
