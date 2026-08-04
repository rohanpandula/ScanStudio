#!/usr/bin/env bash
set -euo pipefail

# Offline bundle verifier for the Windows staging tree (macOS/Linux-runnable
# twin of verify-bundle.ps1). Loads the shared GPL / path guarantees from
# packaging/license-manifest.json (via python3 json) and asserts them against
# an assembled bundle root. Layout checks are pure path assertions, so this
# runs anywhere the staging dir exists — no Windows machine required.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
manifest="$repo_root/packaging/license-manifest.json"

source "$repo_root/packaging/lib/common.sh"

[[ $# -ge 1 ]] || {
    printf 'usage: %s <bundle-root>\n' "$0" >&2
    exit 64
}
root="$1"

[[ -d "$root" ]] || {
    printf 'FAIL: bundle root does not exist: %s\n' "$root" >&2
    exit 64
}

failures=0

# sharedRequiredPaths + perPlatform.windows.additionalRequiredPaths.
paths="$("$HOST_PYTHON" -c '
import json, sys
m = json.load(open(sys.argv[1]))
for p in m["sharedRequiredPaths"] + m["perPlatform"]["windows"]["additionalRequiredPaths"]:
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

if "$HOST_PYTHON" "$repo_root/packaging/lib/verify_dependency_notices.py" "$root"; then
    :
else
    failures=$((failures + 1))
fi

# The offline wheelhouse must contain every pinned requirement, and its
# installer must preserve the local-project ordering and fail-closed flags.
requirements="$root/wsl-requirements.txt"
for requirement in \
    'setuptools==83.0.0' \
    'numpy==2.5.1' \
    'tifffile==2026.7.31' \
    'imagecodecs==2026.6.26' \
    'opencv-python-headless==4.14.0.94' \
    'pyusb==1.3.1' \
    'jinja2==3.1.6' \
    'MarkupSafe==3.0.3' \
    'python-sane==2.9.2'; do
    if [[ -f "$requirements" ]] && grep -Fq "$requirement --hash=sha256:" "$requirements"; then
        printf 'PASS  pinned offline requirement %s\n' "$requirement"
    else
        printf 'FAIL  pinned offline requirement %s\n' "$requirement" >&2
        failures=$((failures + 1))
    fi
done

installer="$root/install-bridge-wsl.sh"
if [[ -f "$installer" ]] && grep -Fq -- '--no-index' "$installer" \
    && grep -Fq -- '--no-deps' "$installer"; then
    printf 'PASS  WSL installer disables remote/local dependency resolution\n'
else
    printf 'FAIL  WSL installer must use --no-index and --no-deps\n' >&2
    failures=$((failures + 1))
fi

coolscan_line="$(grep -n 'Installing CoolscanPy from shipped' "$installer" 2>/dev/null | head -1 | cut -d: -f1 || true)"
bridge_line="$(grep -n 'Installing scanstudio-bridge from shipped' "$installer" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$coolscan_line" && -n "$bridge_line" && "$coolscan_line" -lt "$bridge_line" ]]; then
    printf 'PASS  CoolscanPy local install precedes bridge local install\n'
else
    printf 'FAIL  CoolscanPy must install before scanstudio-bridge\n' >&2
    failures=$((failures + 1))
fi

if [[ -f "$root/Wheelhouse/SHA256SUMS" ]]; then
    missing_wheels=0
    while IFS= read -r line; do
        artifact="${line#*  }"
        if [[ -z "$artifact" || ! -f "$root/Wheelhouse/$artifact" ]]; then
            printf 'FAIL  wheelhouse checksum entry has no artifact: %s\n' "$artifact" >&2
            missing_wheels=$((missing_wheels + 1))
        fi
    done < "$root/Wheelhouse/SHA256SUMS"
    if [[ "$missing_wheels" -eq 0 ]]; then
        printf 'PASS  wheelhouse checksum ledger resolves locally\n'
    else
        failures=$((failures + missing_wheels))
    fi
fi

# No /Users/ absolute developer paths may leak into the bundle.
if assert_no_developer_paths "$root"; then
    printf 'PASS  no developer path leakage\n'
else
    failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
    printf 'verify-bundle: %d check(s) FAILED\n' "$failures" >&2
    exit 1
fi
printf 'verify-bundle: all checks passed\n'
