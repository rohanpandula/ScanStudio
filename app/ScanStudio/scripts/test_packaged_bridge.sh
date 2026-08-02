#!/bin/zsh
# Black-box verification for the bundled launcher and GPL bridge. It works
# from an app path containing spaces and uses only the mock transport. The app
# launcher must authorize its session before exec; invoking the bridge helper
# directly must remain disarmed.
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

bundled_libusb="$relocated_app/Contents/Frameworks/coolscanpy/_native/libusb-1.0.dylib"
libusb_license="$relocated_app/Contents/Resources/Licenses/libusb-LGPL-2.1-or-later.txt"
libusb_source="$relocated_app/Contents/Resources/CorrespondingSource/libusb/libusb-1.0.30.tar.bz2"
libusb_builder="$relocated_app/Contents/Resources/CorrespondingSource/libusb/build_bundled_libusb.sh"
libusb_rebuild="$relocated_app/Contents/Resources/CorrespondingSource/libusb/REBUILD.txt"
if [[ ! -f "$bundled_libusb" || -L "$bundled_libusb" ]]; then
    print -u2 "packaged bridge check failed: app-owned libusb is missing, not regular, or a symlink"
    exit 1
fi
if find "$relocated_app/Contents/Frameworks" -type l -print -quit | grep -q .; then
    print -u2 "packaged bridge check failed: Frameworks contains a symlink escape surface"
    exit 1
fi
if [[ ! -f "$libusb_license" || ! -f "$libusb_source" \
    || ! -x "$libusb_builder" || ! -f "$libusb_rebuild" ]]; then
    print -u2 "packaged bridge check failed: bundled libusb license, source, or rebuild controls are missing"
    exit 1
fi
if [[ "$(shasum -a 256 "$libusb_source" | awk '{print $1}')" \
    != "fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf" ]]; then
    print -u2 "packaged bridge check failed: bundled libusb source archive hash changed"
    exit 1
fi
if ! cmp -s "$libusb_builder" "$script_dir/build_bundled_libusb.sh" \
    || ! zsh -n "$libusb_builder" \
    || ! grep -q 'SCANSTUDIO_LIBUSB_DEPLOYMENT_TARGET=14.0' "$libusb_rebuild" \
    || ! grep -q 'SCANSTUDIO_LIBUSB_SOURCE_ARCHIVE=' "$libusb_rebuild"; then
    print -u2 "packaged bridge check failed: bundled libusb rebuild controls are incomplete or changed"
    exit 1
fi
if ! codesign --verify --strict "$bundled_libusb"; then
    print -u2 "packaged bridge check failed: bundled libusb signature is invalid"
    exit 1
fi
if [[ "$(otool -D "$bundled_libusb" | tail -n +2 | head -n 1)" \
    != "@rpath/coolscanpy/_native/libusb-1.0.dylib" ]]; then
    print -u2 "packaged bridge check failed: bundled libusb install identity is not relocatable"
    exit 1
fi
if otool -L "$bundled_libusb" | tail -n +3 | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    print -u2 "packaged bridge check failed: bundled libusb retains a non-system dependency"
    otool -L "$bundled_libusb" >&2
    exit 1
fi
app_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$relocated_app/Contents/Info.plist")"
libusb_minimum="$(vtool -show-build "$bundled_libusb" | awk '$1 == "minos" { print $2; exit }')"
if [[ -z "$libusb_minimum" || "$libusb_minimum" != "$app_minimum" ]]; then
    print -u2 "packaged bridge check failed: bundled libusb minimum macOS is '$libusb_minimum', expected '$app_minimum'"
    exit 1
fi
app_architectures="$(lipo -archs "$relocated_app/Contents/MacOS/ScanStudio")"
libusb_architectures="$(lipo -archs "$bundled_libusb")"
if [[ "$libusb_architectures" != "$app_architectures" ]]; then
    print -u2 "packaged bridge check failed: bundled libusb architecture '$libusb_architectures' does not match app '$app_architectures'"
    exit 1
fi

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
private_email_scan_targets=(
    "$relocated_app/Contents/MacOS"
    "$relocated_app/Contents/Info.plist"
    "$relocated_app/Contents/Resources/CorrespondingSource/scanstudio-bridge"
    "$relocated_app/Contents/Resources/CorrespondingSource/coolscanpy"
)
if grep -R -a -q -F "$repository_root/" "$relocated_app" \
    || grep -R -a -q -E '/Users/[^/[:space:]]+/' "${privacy_scan_targets[@]}"; then
    print -u2 "packaged bridge check failed: bundle retains a private source path"
    exit 1
fi
if grep -R -a -q -E '[[:alnum:]._%+-]+@(gmail|outlook|yahoo)\.com' "${private_email_scan_targets[@]}"; then
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
"$script_dir/test_launcher.sh" \
    "$relocated_app/Contents/MacOS/ScanStudioLauncher"
if grep -hv '^[[:space:]]*#' "$bridge" \
    | grep -Eq '(^|[[:space:];])(export[[:space:]]+)?SCANSTUDIO_HW_MOTION='; then
    print -u2 "packaged bridge check failed: bridge helper assigns SCANSTUDIO_HW_MOTION"
    exit 1
fi
if grep -hv '^[[:space:]]*#' "$bridge" \
    | grep -Eq '(^|[[:space:];])(touch|rm|mv|cp|install)[^[:cntrl:]]*hw-motion-armed'; then
    print -u2 "packaged bridge check failed: bridge helper mutates the armed latch"
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
resolved_libusb="$(
    cd "$poison_root"
    env -i HOME="$workdir/worker-home" PATH="/usr/bin:/bin" \
        PYTHONHOME="$poison_root/not-a-python-home" \
        PYTHONPATH="$poison_root" \
        "$runtime_python" -I -B -c \
        'from pathlib import Path; from coolscanpy.protocol.ls5000_single_pass.usb_backend import get_libusb_backend; print(Path(get_libusb_backend().lib._name).resolve())'
)"
if [[ "$resolved_libusb" != "${bundled_libusb:A}" ]]; then
    print -u2 "packaged bridge check failed: isolated runtime did not load the exact app-owned libusb"
    print -u2 "expected: ${bundled_libusb:A}"
    print -u2 "actual:   $resolved_libusb"
    exit 1
fi
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
print "packaged launcher arming, bridge relocation, and direct-helper checks passed"
