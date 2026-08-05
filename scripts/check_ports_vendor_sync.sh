#!/usr/bin/env bash
# Verifies ports/tauri/vendor/{coolscanpy,scanstudio-bridge,engine,protocol}
# stay mirrors of their primary trees (coolscanpy/, bridge/,
# app/ScanStudio/engine/, app/ScanStudio/protocol/).
#
# WHAT THIS IS: a regression guard, not a claim of perfect byte-identity.
# An audit on 2026-08-05 (fix/beta2-batch pre-merge review, defect F2) found
# the mirror trees had already drifted from their primary trees well before
# this invariant was believed to hold -- verified empirically by diffing both
# sides at commit 886657c, which the drift predates. Some of that drift is
# genuinely necessary: ports/tauri/vendor ships the Linux/Windows/WSL lane
# (engine/wsl_io.rs's Windows capture-file handoff and its ~12 call sites in
# real_backend.rs, engine/domain.rs's USERPROFILE home-dir fallback,
# bridge/service.py's run-from-source BRIDGE_VERSION fallback, coolscanpy's
# Linux libusb discovery in usb_backend.py, and genuinely mirror-only
# CI/tooling -- .github/workflows/bridge.yml, scripts/probe-linux-env.py,
# scripts/verify-bridge.sh, and their tests) that has no reason to exist in
# the macOS-only primary trees. The rest of the KNOWN_DIFFERENCES below is
# additional pre-existing drift nobody has reconciled yet.
#
# This script does not bless that baseline as correct -- it FREEZES it, so
# any drift beyond this exact, literal list fails CI immediately instead of
# silently growing. Shrinking KNOWN_DIFFERENCES (by reconciling a file, or by
# moving permanently platform-specific code into its own dedicated module the
# way wsl_io.rs already is) is welcome cleanup, never required by this check.
#
# On a genuine, deliberate change to one side (e.g. porting a new primary fix
# into the mirror, or adding new platform-specific mirror-only code): run
# this script, and if it fails on a diff line you intend, paste that EXACT
# line (as printed) into the matching KNOWN_DIFFERENCES block below. Do not
# add a line you have not personally read and understood.

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0

EXCLUDES=(
  --exclude=.DS_Store
  --exclude=__pycache__
  --exclude="*.pyc"
  --exclude=.pytest_cache
  --exclude=.ruff_cache
  --exclude=.benchmarks
  --exclude="*.egg-info"
  --exclude=.venv
  --exclude=target
  --exclude=build
  --exclude=.claude
  --exclude=dist
)

# ---------------------------------------------------------------------------
# check_pair LABEL PRIMARY_DIR MIRROR_DIR
#
# Reads the pair's allowlist from stdin: one exact `diff -rq` output line per
# accepted difference (literal match, no path parsing). Anything `diff -rq`
# reports that is NOT in that list is new drift and fails the check.
# ---------------------------------------------------------------------------
check_pair() {
  local label="$1" primary="$2" mirror="$3"
  local allowlist raw line unexpected=0

  allowlist="$(cat)"
  raw="$(diff -rq "${EXCLUDES[@]}" "$primary" "$mirror" 2>&1 || true)"

  if [ -z "$raw" ]; then
    echo "OK   $label: byte-identical"
    return
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if printf '%s\n' "$allowlist" | grep -qxF -- "$line"; then
      continue
    fi
    echo "::error::$label: unexpected drift beyond the known baseline: $line"
    unexpected=1
  done <<EOF
$raw
EOF

  if [ "$unexpected" = 1 ]; then
    FAIL=1
  else
    echo "OK   $label: only known baseline divergence (see script header)"
  fi
}

check_pair "protocol" "app/ScanStudio/protocol" "ports/tauri/vendor/protocol" <<'EOF'
EOF

check_pair "engine" "app/ScanStudio/engine" "ports/tauri/vendor/engine" <<'EOF'
Files app/ScanStudio/engine/Cargo.lock and ports/tauri/vendor/engine/Cargo.lock differ
Files app/ScanStudio/engine/Cargo.toml and ports/tauri/vendor/engine/Cargo.toml differ
Files app/ScanStudio/engine/src/domain.rs and ports/tauri/vendor/engine/src/domain.rs differ
Files app/ScanStudio/engine/src/evidence_package.rs and ports/tauri/vendor/engine/src/evidence_package.rs differ
Files app/ScanStudio/engine/src/lib.rs and ports/tauri/vendor/engine/src/lib.rs differ
Files app/ScanStudio/engine/src/manifest.rs and ports/tauri/vendor/engine/src/manifest.rs differ
Files app/ScanStudio/engine/src/real_backend.rs and ports/tauri/vendor/engine/src/real_backend.rs differ
Files app/ScanStudio/engine/src/render.rs and ports/tauri/vendor/engine/src/render.rs differ
Only in ports/tauri/vendor/engine/src: wsl_io.rs
EOF

check_pair "bridge" "bridge" "ports/tauri/vendor/scanstudio-bridge" <<'EOF'
Only in ports/tauri/vendor/scanstudio-bridge: .github
Only in ports/tauri/vendor/scanstudio-bridge/scripts: probe-linux-env.py
Only in ports/tauri/vendor/scanstudio-bridge/scripts: verify-bridge.sh
Files bridge/src/scanstudio_bridge/cli.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/cli.py differ
Files bridge/src/scanstudio_bridge/safety.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/safety.py differ
Files bridge/src/scanstudio_bridge/service.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/service.py differ
Files bridge/src/scanstudio_bridge/transport/output_reservation.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/transport/output_reservation.py differ
Only in ports/tauri/vendor/scanstudio-bridge/tests: test_probe_linux_env.py
Files bridge/tests/test_safety.py and ports/tauri/vendor/scanstudio-bridge/tests/test_safety.py differ
Only in ports/tauri/vendor/scanstudio-bridge/tests: test_stdout_byte_discipline.py
Files bridge/tests/test_transport_mock.py and ports/tauri/vendor/scanstudio-bridge/tests/test_transport_mock.py differ
Files bridge/uv.lock and ports/tauri/vendor/scanstudio-bridge/uv.lock differ
EOF

check_pair "coolscanpy" "coolscanpy" "ports/tauri/vendor/coolscanpy" <<'EOF'
Files coolscanpy/src/coolscanpy/__init__.py and ports/tauri/vendor/coolscanpy/src/coolscanpy/__init__.py differ
Files coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/bundle.py and ports/tauri/vendor/coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/bundle.py differ
Files coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/usb_backend.py and ports/tauri/vendor/coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/usb_backend.py differ
Files coolscanpy/tests/test_usb_backend.py and ports/tauri/vendor/coolscanpy/tests/test_usb_backend.py differ
Only in ports/tauri/vendor/coolscanpy/tests: test_version.py
Files coolscanpy/tests/transport/test_scanner_eject.py and ports/tauri/vendor/coolscanpy/tests/transport/test_scanner_eject.py differ
EOF

if [ "$FAIL" = 1 ]; then
  echo
  echo "ports/tauri/vendor drift check FAILED: one or more pairs have drift"
  echo "beyond the documented baseline in this script. If the new difference"
  echo "is deliberate and reviewed, add its exact 'diff -rq' line to the"
  echo "matching allowlist above. If it is not deliberate, sync the file"
  echo "(primary -> mirror for a primary fix; never destroy mirror-only"
  echo "platform-specific code -- see the header comment)."
  exit 1
fi

echo
echo "ports/tauri/vendor drift check passed (baseline only)."
