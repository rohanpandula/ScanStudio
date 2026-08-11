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

# The explicit owner-session launcher must preserve the dual gate without
# changing normal app launches: an exact child-only environment value plus an
# atomically published, token-owned WSL latch that cannot follow a symlink.
launcher_ps="$root/Start-ScanStudio-Hardware-Session.ps1"
launcher_cmd="$root/Start-ScanStudio-Hardware-Session.cmd"
latch_helper="$root/scanstudio-hardware-session-latch.sh"

launcher_missing=0
# shellcheck disable=SC2016 # literal PowerShell source assertions
for expected_text in \
    "\$DistroName = 'Ubuntu-24.04'" \
    "Get-Process -Name 'scanstudio-app'" \
    '[System.Diagnostics.ProcessStartInfo]::new()' \
    "EnvironmentVariables['SCANSTUDIO_HW_MOTION'] = '1'" \
    '$process.WaitForExit()' \
    '-Operation release' \
    '-Operation check-orphans' \
    'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE' \
    'Start-CleanupGuardian' \
    '$guardianReadyEvent.WaitOne(10000)' \
    "'SCANSTUDIO_STATE_DIR'" \
    "'SCANSTUDIO_BRIDGE_BASE_DIR'" \
    "'HOME'"; do
    if [[ -f "$launcher_ps" ]] && grep -Fq -- "$expected_text" "$launcher_ps"; then
        :
    else
        printf 'FAIL  hardware-session PowerShell contract missing: %s\n' "$expected_text" >&2
        launcher_missing=$((launcher_missing + 1))
    fi
done
# shellcheck disable=SC2016 # literal PowerShell source assertion
if [[ "$launcher_missing" -eq 0 ]] \
    && ! grep -Eiq -- '(^|[^[:alnum:]_])setx([^[:alnum:]_]|$)' "$launcher_ps" \
    && ! grep -Eq -- '^[[:space:]]*\$env:SCANSTUDIO_HW_MOTION[[:space:]]*=' "$launcher_ps"; then
    printf 'PASS  hardware-session launcher uses child-only authorization\n'
else
    if [[ "$launcher_missing" -eq 0 ]]; then
        printf 'FAIL  hardware-session launcher must not persist or process-globally set authorization\n' >&2
        launcher_missing=$((launcher_missing + 1))
    fi
fi

helper_missing=0
# shellcheck disable=SC2016 # literal POSIX-shell source assertions
for expected_text in \
    'chmod 700 "$state_dir"' \
    'chmod 600 "$owner_file"' \
    'owner_size" -gt 4096' \
    'ln "$owner_file" "$latch_path"' \
    '[ -f "$latch_path" ] && [ ! -L "$latch_path" ]' \
    'cmp -s "$latch_path" "$owner_file"' \
    '.hw-motion-launcher-operation-lock' \
    'check-orphans)'; do
    if [[ -f "$latch_helper" ]] && grep -Fq -- "$expected_text" "$latch_helper"; then
        :
    else
        printf 'FAIL  WSL latch-helper contract missing: %s\n' "$expected_text" >&2
        helper_missing=$((helper_missing + 1))
    fi
done
if [[ "$helper_missing" -eq 0 ]]; then
    printf 'PASS  WSL latch helper is atomic, bounded, and token-owned\n'
fi
if grep -Fq -- 'SCANSTUDIO_STATE_DIR' "$latch_helper"; then
    printf 'FAIL  production latch helper must use only the shared HOME state lane\n' >&2
    helper_missing=$((helper_missing + 1))
fi

if [[ -f "$launcher_cmd" ]] \
    && grep -Fq -- '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' "$launcher_cmd" \
    && grep -Fq -- 'Start-ScanStudio-Hardware-Session.ps1' "$launcher_cmd" \
    && grep -Fq -- 'pause >nul' "$launcher_cmd"; then
    printf 'PASS  double-click hardware-session entrypoint uses packaged PowerShell\n'
else
    printf 'FAIL  double-click hardware-session entrypoint is incomplete\n' >&2
    launcher_missing=$((launcher_missing + 1))
fi
failures=$((failures + launcher_missing + helper_missing))

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
