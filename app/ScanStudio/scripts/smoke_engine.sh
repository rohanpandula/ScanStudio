#!/usr/bin/env bash
# Scripted NDJSON smoke session against the release scanstudio-engine
# binary: hello -> list -> connect (timeScale 0.02) -> loadMedia(roll36) ->
# acquireThumbnails -> wait for thumbnail completion -> scan.start
# (2 frames, 1 pass) -> scan.stop
# (afterCurrentFrame) -> shutdown. Loose substring assertions (D-17) to
# avoid timing flake; a portable macOS-safe watchdog (no GNU
# timeout/gtimeout assumed) bounds the whole run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$SCRIPT_DIR/../engine"
BIN="$ENGINE_DIR/target/release/scanstudio-engine"
TIMEOUT_SECS=30
SCRIPT_PID=$$

if ! command -v cargo >/dev/null 2>&1; then
  echo "[smoke] FAIL: Rust Cargo is required; install it and make sure cargo is on PATH." >&2
  exit 127
fi

echo "[smoke] building engine (release)..." >&2
(cd "$ENGINE_DIR" && cargo build --release) >&2

if [ ! -x "$BIN" ]; then
  echo "[smoke] FAIL: engine binary not found at $BIN after build" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
FIFO="$WORKDIR/engine.in"
CAPTURE="$WORKDIR/engine.out"
mkfifo "$FIFO"
: > "$CAPTURE"

ENGINE_PID=""
WATCHDOG_PID=""

cleanup() {
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
  [ -n "$ENGINE_PID" ] && kill -9 "$ENGINE_PID" >/dev/null 2>&1 || true
  exec 9>&- 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Launch the engine with stdin held open via a FIFO (not a one-shot
# `printf | binary`, since later writes must happen after observing
# earlier output) and stdout captured to a file.
"$BIN" < "$FIFO" > "$CAPTURE" 2>&1 &
ENGINE_PID=$!

# Portable macOS-safe watchdog: do not assume GNU timeout/gtimeout is
# installed. Kills both the engine and (as a last resort) this script
# itself if anything hangs past the budget.
( sleep "$TIMEOUT_SECS"; kill -9 "$ENGINE_PID" >/dev/null 2>&1; kill -9 "$SCRIPT_PID" >/dev/null 2>&1 ) &
WATCHDOG_PID=$!

# Hold the FIFO's write end open on fd 9 across the whole session so
# writes can happen incrementally, after observing prior output.
exec 9>"$FIFO"

write_line() {
  printf '%s\n' "$1" >&9
}

# Pure predicate: 0 if `needle` appears in the capture before the timeout
# budget elapses (or the engine is still alive), 1 otherwise. Safe to use
# under `set -e` since it's only ever called inside `if`/`!`.
wait_for() {
  local needle="$1"
  local deadline=$((SECONDS + TIMEOUT_SECS))
  while ! grep -q "$needle" "$CAPTURE" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      return 1
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 0
}

require() {
  local needle="$1"
  if ! wait_for "$needle"; then
    echo "[smoke] FAIL: timed out waiting for '$needle' in engine output (or engine exited early)" >&2
    echo "--- captured output so far ---" >&2
    cat "$CAPTURE" >&2
    exit 1
  fi
}

echo "[smoke] session start (engine pid $ENGINE_PID)..." >&2

write_line '{"id":1,"method":"engine.hello","params":{"clientName":"smoke","protocolVersion":1}}'
require '"id":1'

write_line '{"id":2,"method":"scanner.list"}'
require '"id":2'

write_line '{"id":3,"method":"scanner.connect","params":{"deviceId":"sim-ls5000-0","options":{"timeScale":0.02}}}'
require '"id":3'

write_line '{"id":4,"method":"sim.loadMedia","params":{"carrier":"roll36"}}'
require '"id":4'

write_line '{"id":5,"method":"scanner.acquireThumbnails"}'
require '"id":5'

# Thumbnail acquisition owns the transport until its completion event.
# Starting a scan before this point must be rejected with SCANNER_BUSY.
require 'thumbnailsComplete'

write_line '{"id":6,"method":"scan.start","params":{"frames":[1,2],"recipe":{"resolutionDpi":4000,"bitDepth":16,"multisamplePasses":1,"channels":"rgbi"}}}'
require '"id":6'

# Poll for scan.completed before stopping/shutting down.
require 'scan.completed'

# By the time scan.completed has been observed the job has already
# reached a terminal state, so `{acknowledged: false}` is a valid,
# non-error response here — don't assert acknowledged:true.
write_line '{"id":7,"method":"scan.stop","params":{"jobId":"job-1","mode":"afterCurrentFrame"}}'
require '"id":7'

write_line '{"id":8,"method":"engine.shutdown"}'
require '"id":8'

# Give the engine a moment to flush + exit after shutdown.
for _ in $(seq 1 100); do
  if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

set +e
wait "$ENGINE_PID"
EXIT_CODE=$?
set -e

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true

echo "[smoke] engine exit code: $EXIT_CODE" >&2

FAIL=0

if grep -q '"protocolVersion"' "$CAPTURE"; then
  echo "[smoke] PASS: hello result contains \"protocolVersion\""
else
  echo "[smoke] FAIL: no line contains \"protocolVersion\""
  FAIL=1
fi

if grep -E '"event":"scanner\.thumbnailsComplete".*"count":[[:space:]]*36' "$CAPTURE" >/dev/null 2>&1; then
  echo "[smoke] PASS: thumbnailsComplete count 36 observed"
else
  echo "[smoke] FAIL: no thumbnailsComplete line with count 36"
  FAIL=1
fi

if grep -q '"event":"scan\.completed"' "$CAPTURE"; then
  echo "[smoke] PASS: scan.completed observed"
else
  echo "[smoke] FAIL: no scan.completed line observed"
  FAIL=1
fi

if [ "$EXIT_CODE" -eq 0 ]; then
  echo "[smoke] PASS: engine exited 0"
else
  echo "[smoke] FAIL: engine exited $EXIT_CODE"
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
