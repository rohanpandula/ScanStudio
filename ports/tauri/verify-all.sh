#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ENGINE_REPO="$REPO_ROOT/vendor/engine"
BRIDGE_REPO="$REPO_ROOT/vendor/scanstudio-bridge"

RESULTS=()

print_summary() {
  echo ""
  echo "=== verify-all.sh summary ==="
  for r in "${RESULTS[@]}"; do echo "$r"; done
}

run_section() {
  local name="$1" script="$2"
  echo "=== $name ==="
  if [[ ! -x "$script" ]]; then
    echo "FAIL: $name -- $script not found or not executable" >&2
    RESULTS+=("FAIL: $name -- script not found")
    print_summary
    exit 1
  fi
  if "$script"; then
    RESULTS+=("PASS: $name")
  else
    RESULTS+=("FAIL: $name")
    print_summary
    exit 1
  fi
}

echo "=== engine ==="
if cargo test --locked --manifest-path "$ENGINE_REPO/Cargo.toml"; then
  RESULTS+=("PASS: engine")
else
  RESULTS+=("FAIL: engine")
  print_summary
  exit 1
fi
run_section "bridge (Phase 2, bridge repo)" "$BRIDGE_REPO/scripts/verify-bridge.sh"
run_section "app (this repo)" "$REPO_ROOT/verify-app.sh"
run_section "macOS bundle + smoke (this repo)" "$REPO_ROOT/packaging/macos/build-and-smoke.sh"

print_summary
echo "verify-all.sh: ALL SECTIONS PASSED"
