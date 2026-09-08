#!/usr/bin/env bash
# HEAD-03/04: run the same socket-only acceptance through both hosts.
# Simulator evidence only. Each suite owns and tears down its own processes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for mode in in-process headless; do
    HOST_MODE="$mode" E2E_TRANSCRIPT="$WORK/$mode.ndjson" \
        nice -n 15 bash "$ROOT/scripts/cli_attach_acceptance.sh"
done
python3 "$ROOT/scripts/compare_cli_transcripts.py" "$WORK/in-process.ndjson" "$WORK/headless.ndjson"
HOST_PID="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["hostPid"])' "$WORK/headless.ndjson")"
if kill -0 "$HOST_PID" 2>/dev/null || pgrep -P "$HOST_PID" >/dev/null 2>&1; then
    printf 'FAIL headless host or child survived parity run (pid=%s)\n' "$HOST_PID" >&2
    exit 1
fi
printf 'VERIFY_CLI_PARITY OK\n'
