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

site_packages="$relocated_app/Contents/Resources/BridgeRuntime/site-packages"
python_sane_extensions=("$site_packages"/_sane*.so(N.))
python_sane_dist_info=("$site_packages"/python_sane-*.dist-info(N/))
if (( ${#python_sane_extensions} != 1 || ${#python_sane_dist_info} != 1 )); then
    print -u2 "packaged bridge check failed: expected exactly one regular python-sane extension and one dist-info directory"
    exit 1
fi
python_sane_extension="${python_sane_extensions[1]}"
case "$app_architectures" in
    arm64)
        python_sane_host_path="/opt/homebrew/opt/sane-backends/lib/libsane.1.dylib"
        ;;
    x86_64)
        python_sane_host_path="/usr/local/opt/sane-backends/lib/libsane.1.dylib"
        ;;
    *)
        print -u2 "packaged bridge check failed: unsupported app architecture '$app_architectures' for python-sane"
        exit 1
        ;;
esac
python_sane_minimum="$(vtool -show-build "$python_sane_extension" | awk '$1 == "minos" { print $2; exit }')"
if [[ "$(lipo -archs "$python_sane_extension")" != "$app_architectures" \
    || "$python_sane_minimum" != "$app_minimum" ]]; then
    print -u2 "packaged bridge check failed: python-sane architecture/minimum OS does not match the app"
    exit 1
fi
if otool -l "$python_sane_extension" \
    | awk '$2 == "LC_RPATH" { found=1 } END { exit !found }'; then
    print -u2 "packaged bridge check failed: python-sane contains LC_RPATH"
    exit 1
fi
python_sane_dependencies="$(otool -L "$python_sane_extension" | tail -n +2 | awk '{print $1}')"
if [[ "$(print -r -- "$python_sane_dependencies" | grep -Fxc "$python_sane_host_path")" != 1 ]] \
    || print -r -- "$python_sane_dependencies" | grep -Fq '__ScanStudio_SANE_Link_SDK' \
    || print -r -- "$python_sane_dependencies" | grep -vFx "$python_sane_host_path" \
        | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    print -u2 "packaged bridge check failed: python-sane linkage is not the canonical host SANE ABI plus system libraries"
    otool -L "$python_sane_extension" >&2
    exit 1
fi
if ! nm -g "$python_sane_extension" | awk '{print $3}' | grep -Fxq _PyInit__sane \
    || ! grep -q '^Name: python-sane$' "${python_sane_dist_info[1]}/METADATA" \
    || ! grep -q '^Version: 2.9.2$' "${python_sane_dist_info[1]}/METADATA"; then
    print -u2 "packaged bridge check failed: python-sane ABI or distribution metadata changed"
    exit 1
fi
python_sane_source="$relocated_app/Contents/Resources/CorrespondingSource/python-sane/python_sane-2.9.2.tar.gz"
python_sane_builder="$relocated_app/Contents/Resources/CorrespondingSource/python-sane/build_sane_link_sdk.sh"
python_sane_rebuild="$relocated_app/Contents/Resources/CorrespondingSource/python-sane/REBUILD.txt"
if [[ ! -f "$python_sane_source" || -L "$python_sane_source" \
    || ! -x "$python_sane_builder" || -L "$python_sane_builder" \
    || ! -f "$python_sane_rebuild" || -L "$python_sane_rebuild" ]]; then
    print -u2 "packaged bridge check failed: python-sane source or rebuild controls are missing, non-regular, or symlinks"
    exit 1
fi
if [[ "$(stat -f '%z' "$python_sane_source")" != 22513 \
    || "$(shasum -a 256 "$python_sane_source" | awk '{print $1}')" \
        != 50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe ]] \
    || ! cmp -s "$python_sane_builder" "$script_dir/build_sane_link_sdk.sh" \
    || ! zsh -n "$python_sane_builder" \
    || ! grep -q 'f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72' "$python_sane_builder" \
    || ! grep -q '50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe' "$python_sane_builder" \
    || ! grep -q 'SCANSTUDIO_PYTHON_SANE_SOURCE_ARCHIVE' "$python_sane_builder" \
    || ! grep -q 'macOS deployment target 14.0' "$python_sane_rebuild"; then
    print -u2 "packaged bridge check failed: python-sane source provenance or rebuild controls changed"
    exit 1
fi
runtime_scan_targets=(
    "$relocated_app/Contents/MacOS"
    "$relocated_app/Contents/Frameworks"
    "$relocated_app/Contents/Resources/BridgeRuntime"
)
if find "${runtime_scan_targets[@]}" -type f \
    \( -name 'libsane*.dylib' -o -name 'libsane*.so*' \) -print -quit | grep -q . \
    || grep -R -a -q -F '__ScanStudio_SANE_Link_SDK' "${runtime_scan_targets[@]}" \
    || grep -R -a -q -E '/(var/folders|private/tmp)/[^/[:space:]]+/(sane|python.sane)' \
        "${runtime_scan_targets[@]}"; then
    print -u2 "packaged bridge check failed: private SANE SDK identity/path or SANE runtime leaked into executable app content"
    exit 1
fi

base_dir="$workdir/isolated bridge base"
output="$workdir/bridge.ndjson"
bridge="$relocated_app/Contents/MacOS/scanstudio-bridge"
engine="$relocated_app/Contents/MacOS/scanstudio-engine"
runtime_python="$relocated_app/Contents/Resources/BridgeRuntime/python/bin/python3.13"
runtime_sysconfig="$relocated_app/Contents/Resources/BridgeRuntime/python/lib/python3.13/_sysconfigdata__darwin_darwin.py"
coolscanpy_pyproject="$relocated_app/Contents/Resources/CorrespondingSource/coolscanpy/pyproject.toml"
if [[ ! -f "$runtime_sysconfig" || -L "$runtime_sysconfig" ]] \
    || grep -a -q -E '/(private/)?var/folders/|/(private/)?tmp/|/Users/' "$runtime_sysconfig"; then
    print -u2 "packaged bridge check failed: bundled CPython sysconfig retains a private build path"
    exit 1
fi
coolscanpy_version="$(
    "$runtime_python" -I -B - "$coolscanpy_pyproject" <<'PYTHON'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["project"]["version"])
PYTHON
)"
coolscanpy_version_regex="${coolscanpy_version//./\\.}"
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
uv_executable="$(command -v uv || true)"
uv_version_output="${uv_executable:+$("$uv_executable" --version 2>/dev/null || true)}"
if [[ -z "$uv_executable" || ! -x "$uv_executable" \
    || "${${(z)uv_version_output}[1,2]}" != "uv 0.11.30" ]]; then
    print -u2 "packaged bridge check failed: exact uv 0.11.30 is required to verify corresponding source"
    exit 1
fi
source_verify_home="$workdir/source-verify-home"
mkdir -m 700 "$source_verify_home"
if ! (
    cd "$source_verify/scanstudio-bridge"
    env -i \
        HOME="$source_verify_home" PATH="${uv_executable:h}:/usr/bin:/bin" \
        LANG=C LC_ALL=C UV_PYTHON_DOWNLOADS=never \
        "$uv_executable" --no-config lock --check --offline --no-cache \
            --python "$runtime_python"
); then
    print -u2 "packaged bridge check failed: corresponding-source lock does not prove its shipped sibling CoolScanPy source relation"
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
    || ! grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"$coolscanpy_version_regex\"" "$telemetry_file" \
    || ! grep -Eq '"head_sha"[[:space:]]*:[[:space:]]*null' "$telemetry_file"; then
    print -u2 "packaged bridge check failed: provenance did not report sealed CoolscanPy $coolscanpy_version with no borrowed checkout SHA"
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
# Exercise the same fail-closed identity gate the source-based capture worker
# runs before scanner access.  Bind runtime metadata and corresponding-source
# pyproject to the same version while verifying every sealed source/resource
# byte from the exact relocated package.
if ! "$runtime_python" -I -B - "$coolscanpy_pyproject" <<'PYTHON'
from importlib.metadata import version
from pathlib import Path
import sys
import tomllib

import coolscanpy
from coolscanpy.protocol.ls5000_single_pass.bundle import (
    CAPTURE_BUNDLE_SHA256,
    verify_capture_bundle,
)

with Path(sys.argv[1]).open("rb") as handle:
    project_version = tomllib.load(handle)["project"]["version"]
metadata_version = version("coolscanpy")
if coolscanpy.__version__ != project_version or metadata_version != project_version:
    raise SystemExit(
        "CoolscanPy runtime, dist-info, and corresponding-source versions disagree"
    )
if verify_capture_bundle(require_python_sources=True) != CAPTURE_BUNDLE_SHA256:
    raise SystemExit("CoolscanPy capture-bundle identity changed")
PYTHON
then
    print -u2 "packaged bridge check failed: CoolscanPy version or capture identity disagrees"
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
