#!/bin/zsh
# Black-box verification for the bundled GPL bridge. It works from an app path
# containing spaces, uses only the mock transport, and proves the handshake
# does not arm hardware motion or create the armed-latch file.
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
source_app="${1:-$package_root/.build/ScanStudio.app}"

if [[ ! -x "$source_app/Contents/MacOS/scanstudio-bridge" ]]; then
    print -u2 "Packaged bridge check requires a packaged app with Contents/MacOS/scanstudio-bridge: $source_app"
    exit 66
fi

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

relocated_app="$workdir/ScanStudio relocated app/ScanStudio.app"
mkdir -p "${relocated_app:h}"
ditto "$source_app" "$relocated_app"

base_dir="$workdir/isolated bridge base"
output="$workdir/bridge.ndjson"
bridge="$relocated_app/Contents/MacOS/scanstudio-bridge"
engine="$relocated_app/Contents/MacOS/scanstudio-engine"
poison_root="$workdir/hostile Python cwd"
poison_marker="$workdir/poison-imported"
mkdir -p "$poison_root/scanstudio_bridge"
print -r -- "from pathlib import Path; Path(r'$poison_marker').touch()" \
    > "$poison_root/scanstudio_bridge/__init__.py"
print -r -- "from pathlib import Path; Path(r'$poison_marker').touch()" \
    > "$poison_root/sitecustomize.py"

if otool -L "$relocated_app/Contents/Resources/BridgeRuntime/python/bin/python3.13" | tail -n +2 \
    | grep -qE '/(opt/homebrew|usr/local|Users)/'; then
    print -u2 "packaged bridge check failed: bundled Python has a machine-absolute dylib dependency"
    exit 1
fi
repository_root="${package_root:h:h}"
privacy_scan_targets=(
    "$relocated_app/Contents/MacOS"
    "$relocated_app/Contents/Info.plist"
    "$relocated_app/Contents/Resources/CorrespondingSource"
)
if grep -R -a -q -F "$repository_root/" "$relocated_app" \
    || grep -R -a -q -E '/Users/[^/[:space:]]+/' "${privacy_scan_targets[@]}"; then
    print -u2 "packaged bridge check failed: bundle retains a private source path"
    exit 1
fi
if grep -R -a -q -E '[[:alnum:]._%+-]+@(gmail|outlook|yahoo)\.com' "${privacy_scan_targets[@]}"; then
    print -u2 "packaged bridge check failed: bundle retains a personal email address"
    exit 1
fi
if find "$relocated_app/Contents/Resources/CorrespondingSource" \
    \( -name '.claude' -o -name '.planning*' -o -name '.venv' \) -print -quit | grep -q .; then
    print -u2 "packaged bridge check failed: corresponding source contains local configuration or build artifacts"
    exit 1
fi
if find "$relocated_app" \( -name '__pycache__' -o -name '*.pyc' \) -print -quit | grep -q .; then
    print -u2 "packaged bridge check failed: app contains pre-existing Python bytecode"
    exit 1
fi
source_verify="$workdir/corresponding source verify"
mkdir -p "$source_verify"
ditto "$relocated_app/Contents/Resources/CorrespondingSource/scanstudio-bridge" "$source_verify/scanstudio-bridge"
ditto "$relocated_app/Contents/Resources/CorrespondingSource/coolscanpy" "$source_verify/coolscanpy"
if ! (cd "$source_verify/scanstudio-bridge" && uv sync --locked --offline --no-install-project --no-dev); then
    print -u2 "packaged bridge check failed: corresponding source cannot resolve its shipped sibling CoolscanPy source with uv sync --locked"
    exit 1
fi
if grep -hv '^[[:space:]]*#' \
    "$relocated_app/Contents/MacOS/ScanStudioLauncher" "$bridge" \
    | grep -Eq '(^|[[:space:];])(export[[:space:]]+)?SCANSTUDIO_HW_MOTION='; then
    print -u2 "packaged bridge check failed: launcher/helper assigns SCANSTUDIO_HW_MOTION"
    exit 1
fi
if grep -hv '^[[:space:]]*#' \
    "$relocated_app/Contents/MacOS/ScanStudioLauncher" "$bridge" \
    | grep -Eq '(^|[[:space:];])(touch|rm|mv|cp|install)[^[:cntrl:]]*hw-motion-armed'; then
    print -u2 "packaged bridge check failed: launcher/helper mutates the armed latch"
    exit 1
fi

(
    cd "$poison_root"
    printf '%s\n' \
        '{"id":1,"method":"bridge.hello","params":{"clientName":"packaged-smoke","protocolVersion":1}}' \
        '{"id":2,"method":"device.list"}' \
        '{"id":3,"method":"bridge.shutdown","params":{}}' \
        | env -i HOME="$workdir/home" PATH="/usr/bin:/bin" \
            PYTHONHOME="$poison_root/not-a-python-home" \
            PYTHONPATH="$poison_root" \
            SCANSTUDIO_BRIDGE_TRANSPORT=mock \
            SCANSTUDIO_BRIDGE_BASE_DIR="$base_dir" \
            "$bridge" > "$output"
)

if ! grep -Eq '"id":1.*"protocolVersion":1' "$output"; then
    print -u2 "packaged bridge check failed: bridge.hello did not answer from relocated app"
    cat "$output" >&2
    exit 1
fi
if ! grep -Eq '"id":2.*"devices"' "$output"; then
    print -u2 "packaged bridge check failed: device.list did not answer from relocated app"
    cat "$output" >&2
    exit 1
fi
if [[ -e "$base_dir/hw-motion-armed" ]]; then
    print -u2 "packaged bridge check failed: mock handshake created an armed latch"
    exit 1
fi
telemetry_file="$(find "$base_dir/hw-telemetry" -type f -name '*.jsonl' -print -quit)"
if [[ -z "$telemetry_file" ]] \
    || ! grep -Eq '"version"[[:space:]]*:[[:space:]]*"0\.1\.3"' "$telemetry_file" \
    || ! grep -Eq '"head_sha"[[:space:]]*:[[:space:]]*null' "$telemetry_file"; then
    print -u2 "packaged bridge check failed: provenance did not report sealed CoolscanPy 0.1.3 with no borrowed checkout SHA"
    [[ -n "$telemetry_file" ]] && cat "$telemetry_file" >&2
    exit 1
fi
if [[ -e "$poison_marker" ]]; then
    print -u2 "packaged bridge check failed: hostile working-directory Python code was imported"
    exit 1
fi

# CaptureProcessAdapter launches real capture work as the bundled interpreter
# under `-I`, through a stdlib-only worker bootstrap. Exercise the worker
# import boundary against the relocated app. `--help` parses the worker after
# all module imports but does not request `--live`, so it performs no scanner
# operation. This proves the worker sees only the bundled CoolscanPy source
# and curated dependencies, not a developer environment, user PYTHONPATH, or
# the hostile current directory above.
runtime_python="$relocated_app/Contents/Resources/BridgeRuntime/python/bin/python3.13"
expected_worker_package="$relocated_app/Contents/Resources/CorrespondingSource/coolscanpy/src/coolscanpy/__init__.py"
expected_worker_package="${expected_worker_package:A}"
worker_package="$(
    cd "$poison_root"
    env -i HOME="$workdir/worker-home" PATH="/usr/bin:/bin" \
        PYTHONHOME="$poison_root/not-a-python-home" \
        PYTHONPATH="$poison_root" \
        "$runtime_python" -I -B -c 'from pathlib import Path; import coolscanpy; print(Path(coolscanpy.__file__).resolve())'
)"
if [[ "$worker_package" != "$expected_worker_package" ]]; then
    print -u2 "packaged bridge check failed: isolated worker did not import the bundled CoolscanPy source"
    print -u2 "expected: $expected_worker_package"
    print -u2 "actual:   $worker_package"
    exit 1
fi
# Use the exact bootstrap command shape with the real worker and --help.
# It must leave the sealed ready marker and reach only argparse, never
# --live scanner dispatch.
bootstrap_ready_status="$workdir/worker-bootstrap-ready.json"
(
    cd "$poison_root"
    env -i HOME="$workdir/worker-home" PATH="/usr/bin:/bin" \
        PYTHONHOME="$poison_root/not-a-python-home" \
        PYTHONPATH="$poison_root" \
        "$runtime_python" -I -B - "$bootstrap_ready_status" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    _PACKAGED_WORKER_BOOTSTRAP,
    PACKAGED_WORKER_MODULE,
)

status_path = Path(sys.argv[1])
nonce = "b" * 64
worker_argv = ["--help"]
digest = hashlib.sha256(
    json.dumps(worker_argv, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
result = subprocess.run(
    [
        sys.executable,
        "-I",
        "-B",
        "-c",
        _PACKAGED_WORKER_BOOTSTRAP,
        str(status_path),
        PACKAGED_WORKER_MODULE,
        nonce,
        digest,
        *worker_argv,
    ],
    check=False,
    capture_output=True,
    text=True,
)
if result.returncode != 0 or "--live" not in result.stdout:
    raise SystemExit("isolated bootstrap did not reach the real worker help parser")
payload = json.loads(status_path.read_text(encoding="utf-8"))
if payload != {
    "schema_version": 1,
    "state": "ready",
    "nonce": nonce,
    "worker_argv_sha256": digest,
}:
    raise SystemExit("bootstrap ready receipt is not exact and bound to the isolated argv")
PYTHON
)
if [[ -e "$poison_marker" ]]; then
    print -u2 "packaged bridge check failed: isolated worker imported hostile Python code"
    exit 1
fi

# Exercise the exact stdlib-only wrapper used by CaptureProcessAdapter. The
# deliberately nonexistent module fails before `main()` and therefore before
# any scanner-capable entry point. Assert its sealed receipt is bound to the
# parent nonce and exact inner argv; this is the only case the parent may show
# as a local installation repair rather than a feeder recovery condition.
bootstrap_status="$workdir/worker-bootstrap-status.json"
(
    cd "$poison_root"
    env -i HOME="$workdir/worker-home" PATH="/usr/bin:/bin" \
        PYTHONHOME="$poison_root/not-a-python-home" \
        PYTHONPATH="$poison_root" \
        "$runtime_python" -I -B - "$bootstrap_status" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    _PACKAGED_WORKER_BOOTSTRAP,
)

status_path = Path(sys.argv[1])
nonce = "a" * 64
worker_argv: list[str] = []
digest = hashlib.sha256(
    json.dumps(worker_argv, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
result = subprocess.run(
    [
        sys.executable,
        "-I",
        "-B",
        "-c",
        _PACKAGED_WORKER_BOOTSTRAP,
        str(status_path),
        "coolscanpy._scanstudio_missing_worker_for_bootstrap_test",
        nonce,
        digest,
    ],
    check=False,
    capture_output=True,
    text=True,
)
if result.returncode == 0:
    raise SystemExit("bootstrap probe unexpectedly succeeded")
payload = json.loads(status_path.read_text(encoding="utf-8"))
if set(payload) != {
    "schema_version",
    "state",
    "nonce",
    "worker_argv_sha256",
    "error_type",
    "error_message",
}:
    raise SystemExit("bootstrap receipt schema is not exact")
if (
    payload["schema_version"] != 1
    or payload["state"] != "failed-before-ready"
    or payload["nonce"] != nonce
    or payload["worker_argv_sha256"] != digest
    or payload["error_type"] != "ModuleNotFoundError"
    or not isinstance(payload["error_message"], str)
):
    raise SystemExit("bootstrap receipt is not bound to the failed isolated launch")
PYTHON
)
if [[ -e "$poison_marker" ]]; then
    print -u2 "packaged bridge check failed: bootstrap wrapper imported hostile Python code"
    exit 1
fi

# The launcher represents its bundled helper as the no-space token
# `scanstudio-bridge` after placing Contents/MacOS first on PATH. Exercise
# that exact engine spawn route from the relocated app, rather than merely
# invoking the wrapper directly.
engine_output="$workdir/engine.ndjson"
printf '%s\n' \
    '{"id":11,"method":"engine.hello","params":{"clientName":"packaged-engine-smoke","protocolVersion":1}}' \
    '{"id":12,"method":"scanner.list","params":{}}' \
    '{"id":13,"method":"engine.shutdown","params":{}}' \
    | env -i HOME="$workdir/engine-home" \
        PATH="$relocated_app/Contents/MacOS:/usr/bin:/bin" \
        SCANSTUDIO_BRIDGE_CMD=scanstudio-bridge \
        SCANSTUDIO_BRIDGE_TRANSPORT=mock \
        SCANSTUDIO_BRIDGE_BASE_DIR="$workdir/engine isolated bridge base" \
        "$engine" > "$engine_output"
if ! grep -Eq '"id":12.*"kind":"real".*"mock-ls5000-0"|"id":12.*"mock-ls5000-0".*"kind":"real"' "$engine_output"; then
    print -u2 "packaged bridge check failed: engine did not spawn the relocated bundled helper"
    cat "$engine_output" >&2
    exit 1
fi
if [[ -e "$workdir/engine isolated bridge base/hw-motion-armed" ]]; then
    print -u2 "packaged bridge check failed: engine handshake created an armed latch"
    exit 1
fi
if find "$relocated_app" \( -name '__pycache__' -o -name '*.pyc' \) -print -quit | grep -q .; then
    print -u2 "packaged bridge check failed: bridge execution wrote bytecode into the signed app"
    exit 1
fi
if ! codesign --verify --deep --strict "$relocated_app"; then
    print -u2 "packaged bridge check failed: app signature changed after bridge execution"
    exit 1
fi
print "packaged bridge relocation and unarmed mock handshake passed"
