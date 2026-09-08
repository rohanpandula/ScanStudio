#!/bin/bash
# Attended full-roll runbook. It proves the CLI sequence against the simulator;
# it does not authorize film motion, retry a refusal, eject, or power-cycle a scanner.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: full_roll_cli.sh [options]

  --simulator             start an isolated host for sim-ls5000-0
  --film-loaded           operator confirms film is physically loaded
  --confirm-motion        operator confirms this run may move film
  --app PATH              ScanStudio.app (default: /Applications/ScanStudio.app)
  --dmg PATH              record the DMG SHA-256 in the evidence directory
  --adapter NAME          record the adapter/holder used by the operator
  --frame-count N         frame count passed to roll run (simulator default 6, hardware default 36)
  --name NAME             project name (default: full-roll-UTC timestamp)
  -h, --help              show this help

Both motion flags are required even in simulator mode and are forwarded verbatim.
Simulator mode owns a short private socket and host; hardware mode attaches the
existing default GUI/headless host and selects a discovered non-simulator device.
The script stops at the first failed command. Stop or recover a hardware run
manually using docs/MAC-ACCEPTANCE.md before starting another command.
EOF
}

simulator=0
film_loaded=0
confirm_motion=0
app="/Applications/ScanStudio.app"
dmg=""
adapter=""
frame_count=""
name=""
original_home="${HOME:?}"
while (($#)); do
    case "$1" in
        --simulator) simulator=1; shift ;;
        --film-loaded) film_loaded=1; shift ;;
        --confirm-motion) confirm_motion=1; shift ;;
        --app) [[ $# -ge 2 ]] || { echo "--app needs a path" >&2; exit 64; }; app=$2; shift 2 ;;
        --dmg) [[ $# -ge 2 ]] || { echo "--dmg needs a path" >&2; exit 64; }; dmg=$2; shift 2 ;;
        --adapter) [[ $# -ge 2 ]] || { echo "--adapter needs a name" >&2; exit 64; }; adapter=$2; shift 2 ;;
        --frame-count) [[ $# -ge 2 ]] || { echo "--frame-count needs a number" >&2; exit 64; }; frame_count=$2; shift 2 ;;
        --name) [[ $# -ge 2 ]] || { echo "--name needs a value" >&2; exit 64; }; name=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

(( film_loaded )) || { echo "missing required --film-loaded" >&2; exit 77; }
(( confirm_motion )) || { echo "missing required --confirm-motion" >&2; exit 77; }
[[ -n "$adapter" ]] || adapter="unspecified"
if [[ -z "$frame_count" ]]; then
    if (( simulator )); then
        frame_count=6
    else
        frame_count=36
    fi
fi
[[ "$frame_count" =~ ^[1-9][0-9]*$ ]] || { echo "--frame-count must be a positive integer" >&2; exit 64; }

app="$(cd "$app" 2>/dev/null && pwd -P)" || { echo "app not found: $app" >&2; exit 1; }
cli="$app/Contents/MacOS/scanstudio-cli"
[[ -x "$cli" ]] || { echo "missing executable: $cli" >&2; exit 1; }
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="${name:-full-roll-$timestamp}"
qa_root="$original_home/ScanStudio-QA"
run_dir="$qa_root/$timestamp"
suffix=0
while [[ -e "$run_dir" ]]; do
    suffix=$((suffix + 1))
    run_dir="$qa_root/${timestamp}-${suffix}"
done
mkdir -p "$run_dir/diagnostics"
socket=""
log="$run_dir/host.log"

host_started=0
socket_dir=""
cleanup() {
    if (( host_started )); then
        "$cli" host stop --socket "$socket" --attach >"$run_dir/host-stop.json" 2>"$run_dir/host-stop.stderr" || true
    fi
    [[ -z "$socket_dir" ]] || rm -rf "$socket_dir"
}
trap cleanup EXIT

if (( simulator )); then
    socket_dir="$(mktemp -d /tmp/scanstudio-cli.XXXXXX)"
    socket="$socket_dir/control.sock"
    mkdir -p "$run_dir/home"
    export HOME="$run_dir/home"
    export CFFIXED_USER_HOME="$HOME"
    unset SCANSTUDIO_BRIDGE_CMD SCANSTUDIO_HW_MOTION SCANSTUDIO_BRIDGE_SOURCE \
        SCANSTUDIO_BRIDGE_PYTHON SCANSTUDIO_BRIDGE_BASE_DIR
    export SCANSTUDIO_BRIDGE_TRANSPORT=mock
fi

printf 'app=%s\nversion=' "$app" >"$run_dir/identity.txt"
if command -v plutil >/dev/null 2>&1; then
    plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" >>"$run_dir/identity.txt" || printf 'unknown\n' >>"$run_dir/identity.txt"
else
    printf 'unknown\n' >>"$run_dir/identity.txt"
fi
printf 'adapter=%s\n' "$adapter" >>"$run_dir/identity.txt"
printf 'cli_sha256=' >>"$run_dir/identity.txt"; shasum -a 256 "$cli" >>"$run_dir/identity.txt"
if [[ -n "$dmg" ]]; then
    [[ -f "$dmg" ]] || { echo "DMG not found: $dmg" >&2; exit 1; }
    printf 'dmg_sha256=' >>"$run_dir/identity.txt"; shasum -a 256 "$dmg" >>"$run_dir/identity.txt"
fi

step=""
run_step() {
    step=$1
    shift
    local output="$run_dir/$step.json" rc
    set +e
    "$@" >"$output" 2>"$run_dir/$step.stderr"
    rc=$?
    set -e
    if (( rc != 0 )); then
        printf 'FAIL %s exit=%s\n' "$step" "$rc" >&2
        python3 - "$output" <<'PY'
import json, sys
try:
    body = json.load(open(sys.argv[1], encoding="utf-8"))
    error = body.get("error", {})
    if error:
        print(f"code={error.get('code', 'unknown')} recoverable={error.get('recoverable', 'unknown')}", file=sys.stderr)
    result = body.get("result", {})
    failed = [step for step in result.get("steps", []) if step.get("exitCode", 0) != 0]
    if failed:
        last = failed[-1]
        print(
            "failed_step="
            f"{last.get('step', 'unknown')} command={last.get('command', 'unknown')} "
            f"exit={last.get('exitCode', 'unknown')} outcome={last.get('outcome', 'unknown')}",
            file=sys.stderr,
        )
    selected = result.get("frames", {}).get("selected")
    skipped = result.get("frames", {}).get("skipped")
    if selected is not None:
        print(f"frames_selected={selected} frames_skipped={skipped}", file=sys.stderr)
except (OSError, ValueError):
    print("code=unparseable recoverable=unknown", file=sys.stderr)
PY
        exit "$rc"
    fi
    printf 'PASS %s\n' "$step"
}

if (( simulator )); then
    run_step host-start "$cli" host --simulator --detach --socket "$socket" --log "$log"
    host_started=1
fi
cli_call() {
    if (( simulator )); then
        "$cli" "$@" --socket "$socket" --attach
    else
        "$cli" "$@" --attach
    fi
}
wait_for_host_idle() {
    local deadline=$(( $(date +%s) + 30 ))
    local output="$run_dir/host-ready.json" ready rc
    while (( $(date +%s) < deadline )); do
        set +e
        cli_call status >"$output" 2>"$run_dir/host-ready.stderr"
        rc=$?
        set -e
        if (( rc != 0 )); then
            printf 'FAIL host-ready exit=%s\n' "$rc" >&2
            cat "$output" >&2 || true
            exit "$rc"
        fi
        ready="$(python3 - "$output" <<'PY'
import json, sys
try:
    result = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {})
    print("yes" if result.get("mutatingOperationInFlight") is None else "no")
except (OSError, ValueError):
    print("no")
PY
)"
        if [[ "$ready" == yes ]]; then
            printf 'PASS host-ready\n'
            return
        fi
        sleep 0.1
    done
    printf 'FAIL host-ready timed out while waiting for scanner discovery to become idle\n' >&2
    exit 70
}
if (( simulator )); then
    wait_for_host_idle
fi
run_step discovery cli_call rescan
if (( simulator )); then
    run_step connect cli_call connect --device sim-ls5000-0
    run_step sim-load-media cli_call sim load-media --carrier strip6
    run_step settings cli_call settings set --resolution 100 --bit-depth 16 --channels rgb
    carrier=strip6
else
    device_id="$(python3 - "$run_dir/discovery.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
devices = body.get("result", {}).get("devices", [])
print(next((device.get("deviceId", "") for device in devices if device.get("kind") != "simulated"), ""))
PY
    )"
    [[ -n "$device_id" ]] || { echo "no supported non-simulator device was discovered" >&2; exit 65; }
    run_step connect cli_call connect --device "$device_id"
    carrier=roll36
fi
run_step status cli_call status --refresh
printf 'scanner_status=%s\n' "$run_dir/status.json" >>"$run_dir/identity.txt"

run_step roll-run cli_call roll run --name "$name" --carrier "$carrier" --frame-count "$frame_count" --film-process c41ColorNegative --film-loaded --confirm-motion --skip-blank --auto-approve --wait
run_step diagnostics cli_call diagnostics export --to "$run_dir/diagnostics"

project_dir="$(python3 - "$run_dir/roll-run.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
print(body.get("result", {}).get("project", {}).get("directory", ""))
PY
)"
receipt_path="$(python3 - "$run_dir/roll-run.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
print(body.get("result", {}).get("receiptPath", ""))
PY
)"
[[ -n "$project_dir" && -f "$project_dir/manifest.json" ]] || { echo "roll run did not report a project manifest" >&2; exit 65; }
cp -p "$project_dir/manifest.json" "$run_dir/manifest.json"
[[ -n "$receipt_path" && -f "$receipt_path" ]] || { echo "roll run did not report its cli-run receipt" >&2; exit 65; }
cp -p "$receipt_path" "$run_dir/$(basename "$receipt_path")"

find "$run_dir" -type f ! -name SHA256SUMS -print | sort | while IFS= read -r file; do
    shasum -a 256 "$file"
done >"$run_dir/SHA256SUMS"
printf 'VERIFY_FULL_ROLL_CLI OK (run=%s simulator=%s)\n' "$run_dir" "$simulator"
