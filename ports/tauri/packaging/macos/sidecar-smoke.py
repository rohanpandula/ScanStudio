#!/usr/bin/env python3
"""Bounded NDJSON smoke test for the sidecar shipped in a macOS bundle."""

from __future__ import annotations

import argparse
from collections import deque
import json
import os
import selectors
import subprocess
import sys
import time
from typing import Any


class ResponseReader:
    """Newline decoder whose deadline is never hidden inside readline()."""

    def __init__(self, stream: Any) -> None:
        self._stream = stream
        self._selector = selectors.DefaultSelector()
        self._selector.register(stream, selectors.EVENT_READ)
        self._buffer = bytearray()
        self._messages: deque[dict[str, Any]] = deque()

    def close(self) -> None:
        self._selector.close()

    def _decode_complete_lines(self) -> None:
        while True:
            newline = self._buffer.find(b"\n")
            if newline < 0:
                return
            raw = bytes(self._buffer[:newline])
            del self._buffer[: newline + 1]
            try:
                value = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(value, dict):
                self._messages.append(value)

    def read_response(self, match_id: int, timeout: float) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while True:
            retained: deque[dict[str, Any]] = deque()
            match = None
            while self._messages:
                message = self._messages.popleft()
                if "event" in message:
                    continue
                if match is None and message.get("id") == match_id:
                    match = message
                else:
                    retained.append(message)
            self._messages = retained
            if match is not None:
                return match

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            if not self._selector.select(remaining):
                return None
            chunk = os.read(self._stream.fileno(), 64 * 1024)
            if not chunk:
                return None
            self._buffer.extend(chunk)
            self._decode_complete_lines()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("engine")
    parser.add_argument("--engine-arg", action="append", default=[])
    parser.add_argument("--response-timeout", type=float, default=10.0)
    parser.add_argument("--shutdown-timeout", type=float, default=10.0)
    return parser.parse_args()


def run_smoke(args: argparse.Namespace) -> int:
    proc = subprocess.Popen(
        [args.engine, *args.engine_arg],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    assert proc.stdin is not None
    assert proc.stdout is not None
    reader = ResponseReader(proc.stdout)
    failures: list[str] = []

    def send(obj: dict[str, Any]) -> None:
        proc.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
        proc.stdin.flush()

    def check(name: str, condition: bool, detail: Any = "") -> None:
        if condition:
            print("PASS  " + name)
        else:
            suffix = (": " + str(detail)) if detail else ""
            print("FAIL  " + name + suffix, file=sys.stderr)
            failures.append(name)

    def require_response(match_id: int, name: str) -> dict[str, Any] | None:
        response = reader.read_response(match_id, args.response_timeout)
        check(name, response is not None, f"timed out after {args.response_timeout:.3f}s")
        return response

    try:
        send(
            {
                "id": 1,
                "method": "engine.hello",
                "params": {
                    "clientName": "packaging-smoke-test",
                    "protocolVersion": 1,
                },
            }
        )
        response = require_response(1, "engine.hello responds id 1")
        if response is None:
            return 1
        check(
            "engine.hello engineName == scanstudio-engine",
            response.get("result", {}).get("engineName") == "scanstudio-engine",
            response,
        )
        check(
            "engine.hello protocolVersion == 1",
            response.get("result", {}).get("protocolVersion") == 1,
            response,
        )

        send({"id": 2, "method": "scanner.list", "params": {}})
        response = require_response(2, "scanner.list responds id 2")
        if response is None:
            return 1
        devices = response.get("result", {}).get("devices", [])
        check(
            "scanner.list exactly one device",
            isinstance(devices, list) and len(devices) == 1,
            f"devices={devices!r}",
        )
        device_id = None
        if isinstance(devices, list) and devices and isinstance(devices[0], dict):
            device_id = devices[0].get("deviceId") or devices[0].get("id")
        check("scanner.list device has id", bool(device_id), f"devices={devices!r}")
        if not device_id:
            return 1

        send(
            {
                "id": 3,
                "method": "scanner.connect",
                "params": {"deviceId": device_id},
            }
        )
        response = require_response(3, "scanner.connect responds id 3")
        if response is None:
            return 1
        check("scanner.connect no error", "error" not in response, response)

        send({"id": 4, "method": "engine.shutdown", "params": {}})
        response = require_response(4, "engine.shutdown responds id 4")
        if response is None:
            return 1
        check("engine.shutdown no error", "error" not in response, response)

        try:
            code = proc.wait(timeout=args.shutdown_timeout)
        except subprocess.TimeoutExpired:
            print(
                f"FAIL  engine did not exit within {args.shutdown_timeout:.3f}s of shutdown",
                file=sys.stderr,
            )
            failures.append("engine.shutdown exit")
        else:
            check("engine exits 0 on shutdown", code == 0, f"exit={code}")

        if failures:
            print(f"smoke: {len(failures)} assertion(s) failed", file=sys.stderr)
            return 1
        print("smoke: all assertions passed")
        return 0
    except (BrokenPipeError, OSError) as error:
        print(f"FAIL  sidecar I/O failed: {error}", file=sys.stderr)
        return 1
    finally:
        reader.close()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def main() -> int:
    args = parse_args()
    if args.response_timeout <= 0 or args.shutdown_timeout <= 0:
        print("timeouts must be positive", file=sys.stderr)
        return 2
    return run_smoke(args)


if __name__ == "__main__":
    raise SystemExit(main())
