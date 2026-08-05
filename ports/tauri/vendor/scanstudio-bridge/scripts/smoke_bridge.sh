#!/usr/bin/env bash
# Scripted NDJSON smoke session against the real `scanstudio-bridge`
# console script: bridge.hello -> device.list -> roll.preview (SAFE-02
# deliberately left disarmed, proving the armed-latch gate is enforced by a
# real subprocess with no hardware and no arming needed) -> bridge.shutdown.
# Loose substring assertions to avoid timing flake; a portable macOS-safe
# watchdog (no GNU timeout/gtimeout assumed) bounds the whole run. Mirrors
# app/ScanStudio/scripts/smoke_engine.sh's structure (this repo's own Phase
# 1 engine smoke test) -- read that file for the exact pattern this
# mirrors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMEOUT_SECS=30
SCRIPT_PID=$$

WORKDIR="$(mktemp -d)"
FIFO="$WORKDIR/bridge.in"
CAPTURE="$WORKDIR/bridge.out"
# An isolated temp dir, never the real ~/.scanstudio -- SAFE-02's
# latch/lane/telemetry files must never be written to the real path by a
# verification run (see cli.py's SCANSTUDIO_BRIDGE_BASE_DIR seam).
BASE_DIR="$WORKDIR/scanstudio-base"
mkfifo "$FIFO"
: > "$CAPTURE"

BRIDGE_PID=""
WATCHDOG_PID=""

cleanup() {
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
  [ -n "$BRIDGE_PID" ] && kill -9 "$BRIDGE_PID" >/dev/null 2>&1 || true
  exec 9>&- 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Launch the bridge with stdin held open via a FIFO (not a one-shot
# `printf | scanstudio-bridge`, since later writes must happen after
# observing earlier output) and stdout captured to a file. `uv run`
# resolves/uses the project's own venv -- no separate `uv sync` step
# needed. No hardware: SCANSTUDIO_BRIDGE_TRANSPORT=mock.
(
  cd "$BRIDGE_DIR"
  SCANSTUDIO_BRIDGE_TRANSPORT=mock SCANSTUDIO_BRIDGE_BASE_DIR="$BASE_DIR" \
    uv run scanstudio-bridge <"$FIFO" >"$CAPTURE" 2>&1
) &
BRIDGE_PID=$!

# Portable macOS-safe watchdog: do not assume GNU timeout/gtimeout is
# installed. Kills both the bridge and (as a last resort) this script
# itself if anything hangs past the budget.
(
  sleep "$TIMEOUT_SECS"
  kill -9 "$BRIDGE_PID" >/dev/null 2>&1
  kill -9 "$SCRIPT_PID" >/dev/null 2>&1
) &
WATCHDOG_PID=$!

# Hold the FIFO's write end open on fd 9 across the whole session so
# writes can happen incrementally, after observing prior output.
exec 9>"$FIFO"

write_line() {
  printf '%s\n' "$1" >&9
}

# Pure predicate: 0 if `needle` appears in the capture before the timeout
# budget elapses (or the bridge is still alive), 1 otherwise. Safe to use
# under `set -e` since it's only ever called inside `if`/`!`.
wait_for() {
  local needle="$1"
  local deadline=$((SECONDS + TIMEOUT_SECS))
  while ! grep -q "$needle" "$CAPTURE" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      return 1
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 0
}

require() {
  local needle="$1"
  if ! wait_for "$needle"; then
    echo "[smoke] FAIL: timed out waiting for '$needle' in bridge output (or bridge exited early)" >&2
    echo "--- captured output so far ---" >&2
    cat "$CAPTURE" >&2
    exit 1
  fi
}

echo "[smoke] session start (bridge pid $BRIDGE_PID, base_dir $BASE_DIR)..." >&2

write_line '{"id":1,"method":"bridge.hello","params":{"clientName":"smoke","protocolVersion":1}}'
require '"protocolVersion"'

write_line '{"id":2,"method":"device.list"}'
require '"devices"'

# roll.preview also refuses NOT_CONNECTED when no device is open (BRIDGE.md's
# Methods table) -- open the mock device first so this session's roll.preview
# reaches the SAFE-02 check this script actually wants to exercise.
write_line '{"id":3,"method":"device.open","params":{"deviceId":"mock-ls5000-0"}}'
require '"id":3'

# SAFE-02 deliberately left disarmed (no SCANSTUDIO_HW_MOTION, no latch
# file under $BASE_DIR): proves the armed-latch gate is enforced by the
# real subprocess, no hardware and no arming needed.
write_line '{"id":4,"method":"roll.preview","params":{"material":"colorNegative"}}'
require 'HW_MOTION_NOT_ARMED'

write_line '{"id":5,"method":"bridge.shutdown"}'
require '"id":5'

for _ in $(seq 1 100); do
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

set +e
wait "$BRIDGE_PID"
EXIT_CODE=$?
set -e

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true

echo "[smoke] bridge exit code: $EXIT_CODE" >&2

FAIL=0

if grep -q '"protocolVersion"' "$CAPTURE"; then
  echo "[smoke] PASS: bridge.hello result contains \"protocolVersion\""
else
  echo "[smoke] FAIL: no line contains \"protocolVersion\""
  FAIL=1
fi

if grep -q '"devices"' "$CAPTURE"; then
  echo "[smoke] PASS: device.list result contains \"devices\""
else
  echo "[smoke] FAIL: no line contains \"devices\""
  FAIL=1
fi

if grep -q 'HW_MOTION_NOT_ARMED' "$CAPTURE"; then
  echo "[smoke] PASS: disarmed roll.preview refused with HW_MOTION_NOT_ARMED"
else
  echo "[smoke] FAIL: no HW_MOTION_NOT_ARMED refusal observed"
  FAIL=1
fi

if grep -q '"id":5' "$CAPTURE"; then
  echo "[smoke] PASS: bridge.shutdown response observed"
else
  echo "[smoke] FAIL: no bridge.shutdown response observed"
  FAIL=1
fi

if [ "$EXIT_CODE" -eq 0 ]; then
  echo "[smoke] PASS: bridge exited 0"
else
  echo "[smoke] FAIL: bridge exited $EXIT_CODE"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "[smoke] ALL CHECKS PASSED"
  exit 0
else
  echo "[smoke] SOME CHECKS FAILED"
  echo "--- captured output ---" >&2
  cat "$CAPTURE" >&2
  exit 1
fi
