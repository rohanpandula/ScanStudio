#!/usr/bin/env bash
set -euo pipefail

# Offline bundle verifier for the Linux staging tree. Loads the shared GPL /
# path guarantees from packaging/license-manifest.json (via python3 json) and
# asserts them against an assembled bundle root. Pass --staging-only (or run
# on a non-Linux host) to relax the checks that need a real Linux build: the
# python-sane compiled binding and the isolated bridge import.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$script_dir/../license-manifest.json"

source "$script_dir/../lib/common.sh"

[[ $# -ge 1 ]] || {
    printf 'usage: %s <bundle-root> [--staging-only]\n' "$0" >&2
    exit 64
}
root="$1"
staging_only=0
if [[ $# -ge 2 && "$2" == "--staging-only" ]]; then
    staging_only=1
fi

[[ -d "$root" ]] || {
    printf 'FAIL: bundle root does not exist: %s\n' "$root" >&2
    exit 64
}

failures=0
host_is_linux=0
if [[ "$(uname -s)" == "Linux" ]]; then
    host_is_linux=1
fi

# sharedRequiredPaths + perPlatform.linux.additionalRequiredPaths.
paths="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for p in m["sharedRequiredPaths"] + m["perPlatform"]["linux"]["additionalRequiredPaths"]:
    print(p)
' "$manifest")"
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ -e "$root/$p" ]]; then
        printf 'PASS  %s\n' "$p"
    else
        printf 'FAIL  %s\n' "$p" >&2
        failures=$((failures + 1))
    fi
done <<< "$paths"

if "$HOST_PYTHON" "$script_dir/../lib/verify_dependency_notices.py" "$root"; then
    :
else
    failures=$((failures + 1))
fi

# perPlatform.linux.requiredSitePackageEntries (under BridgeRuntime/site-packages).
entries="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for e in m["perPlatform"]["linux"]["requiredSitePackageEntries"]:
    print(e)
' "$manifest")"
while IFS= read -r e; do
    [[ -n "$e" ]] || continue
    if [[ -e "$root/BridgeRuntime/site-packages/$e" ]]; then
        printf 'PASS  site-packages/%s\n' "$e"
    else
        printf 'FAIL  site-packages/%s\n' "$e" >&2
        failures=$((failures + 1))
    fi
done <<< "$entries"

# perPlatform.linux.strictOnlyPaths. Skipped (not required) with
# --staging-only or on a non-Linux host; required on a real Linux bundle.
strict_paths="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for p in m["perPlatform"]["linux"]["strictOnlyPaths"]:
    print(p)
' "$manifest")"
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ "$staging_only" -eq 1 || "$host_is_linux" -eq 0 ]]; then
        printf 'SKIP  %s (staging-only or non-Linux host)\n' "$p"
    elif [[ -e "$root/$p" ]]; then
        printf 'PASS  %s\n' "$p"
    else
        printf 'FAIL  %s\n' "$p" >&2
        failures=$((failures + 1))
    fi
done <<< "$strict_paths"

if [[ -x "$root/scanstudio-bridge" ]]; then
    printf 'PASS  bundled scanstudio-bridge is executable\n'
else
    printf 'FAIL  bundled scanstudio-bridge is missing or not executable\n' >&2
    failures=$((failures + 1))
fi

# No /Users/ absolute developer paths may leak into the bundle.
if assert_no_developer_paths "$root"; then
    printf 'PASS  no developer path leakage\n'
else
    failures=$((failures + 1))
fi

# Strict Linux checks execute the exact bundled interpreter and add only the
# three bundle-owned import roots. This proves both python-sane's native module
# and the bridge dependency chain load without user/site-package leakage.
if [[ "$host_is_linux" -eq 1 ]]; then
    sane_extension="$(find "$root/BridgeRuntime/site-packages" -maxdepth 1 -type f -name '_sane*.so' -print -quit)"
    if [[ -n "$sane_extension" ]]; then
        printf 'PASS  python-sane native extension\n'
    else
        printf 'FAIL  python-sane native extension (_sane*.so)\n' >&2
        failures=$((failures + 1))
    fi
    bridge_source="$root/CorrespondingSource/scanstudio-bridge/src"
    coolscanpy_source="$root/CorrespondingSource/coolscanpy/src"
    site_packages="$root/BridgeRuntime/site-packages"
    bootstrap='import sys; sys.path[:0] = sys.argv[1:4]; import sane, coolscanpy, scanstudio_bridge'
    if "$root/BridgeRuntime/python/bin/python3.13" -I -B -c "$bootstrap" \
        "$bridge_source" "$coolscanpy_source" "$site_packages" 2>/dev/null; then
        printf 'PASS  isolated bridge + python-sane import\n'
    else
        printf 'FAIL  isolated bridge + python-sane import\n' >&2
        failures=$((failures + 1))
    fi
    # The capture worker is spawned as `python -I -B` with NO path injection
    # (protocol/ls5000_single_pass/capture_process.py), so it must resolve
    # coolscanpy + its whole runtime chain from the interpreter's own default
    # sys.path -- the scanstudio-bridge-runtime.pth is what makes that true.
    # This is the check whose absence let the packaging gap ship: the injected
    # import above passes even when the worker cannot start. Import the worker
    # module itself, exactly as the child does, with no argv paths.
    worker_bootstrap='import coolscanpy, numpy, cv2, tifffile, sane, usb; import coolscanpy.protocol.ls5000_single_pass.worker'
    if "$root/BridgeRuntime/python/bin/python3.13" -I -B -c "$worker_bootstrap" 2>/dev/null; then
        printf 'PASS  isolated capture-worker import (no path injection)\n'
    else
        printf 'FAIL  isolated capture-worker import (no path injection) -- coolscanpy/deps not on the bundled interpreter default path\n' >&2
        failures=$((failures + 1))
    fi
    if [[ -x "$root/scanstudio-bridge" ]] \
        && timeout 15s "$root/scanstudio-bridge" --version </dev/null >/dev/null 2>&1; then
        printf 'PASS  bundled bridge launch/import smoke\n'
    else
        printf 'FAIL  bundled bridge launch/import smoke\n' >&2
        failures=$((failures + 1))
    fi
else
    printf 'SKIP  isolated bridge + python-sane import (requires a Linux host)\n'
fi

if [[ "$failures" -gt 0 ]]; then
    printf 'verify-bundle: %d check(s) FAILED\n' "$failures" >&2
    exit 1
fi
printf 'verify-bundle: all checks passed\n'
