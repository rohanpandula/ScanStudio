#!/bin/zsh
# verify_updater.sh — seeded, end-to-end updater verification gate (01-06).
#
# Proves the whole delivered auto-update pipeline on fake, on-disk fixtures:
#   emit release assets -> resolve pointer -> check -> download -> SHA-256
#   verify -> snapshot -> swap -> rollback.
#
# The metadata emitter is checked against bytes from the supplied packaged app.
# The Swift suite separately exercises install, rollback, and cross-architecture
# rejection using its own offline fixtures. Neither step proves notarization.
#
# THIS SCRIPT TOUCHES ONLY TEMP DIRECTORIES. It never writes to /Applications,
# never mutates this repo, never touches the scanner, and makes no network
# calls. The flow itself is driven in-process by the offline Swift harness
# `UpdateFlowIntegrationTests` (a normal `swift test` target), which wires
# GitHubUpdateChecker -> UpdateDownloader -> UpdateInstaller against seeded
# fake bundles.
#
# Environment overrides:
#   SCANSTUDIO_UPDATER_CURRENT_APP  path to a ScanStudio.app to treat as the
#                                   "current install" (default: synthetic)
#   SCANSTUDIO_UPDATER_NEW_APP      path to a ScanStudio.app to treat as the
#                                   "new release" whose bytes seed the feed
#                                   (default: synthetic)
#   SCANSTUDIO_UPDATER_VERSION      release version string for the seeded feed
#                                   (default: 0.3.0-beta.1)
#
# Exit code is nonzero on any failure; a green run ends with
#   VERIFY_UPDATER OK
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITTER="$ROOT/app/ScanStudio/scripts/emit_release_assets.sh"
SWIFT_DIR="$ROOT/app/ScanStudio"

VERSION="${SCANSTUDIO_UPDATER_VERSION:-0.3.0-beta.1}"

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# Builds a minimal ScanStudio.app bundle stamped with a release version and a
# distinguishing marker file (bash/zsh-portable; python3 is present on macOS).
make_fake_app() {
    local app="$1" release="$2" marker="$3"
    mkdir -p "$app/Contents/MacOS"
    python3 - "$release" "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
release, outfile = sys.argv[1], sys.argv[2]
with open(outfile, "wb") as f:
    plistlib.dump({"CFBundleShortVersionString": release, "ScanStudioRelease": release}, f)
PY
    printf '%s' "$marker" > "$app/Contents/MacOS/ScanStudio"
}

# ---- Step 1: resolve the "current install" and "new release" bundles --------
if [[ -n "${SCANSTUDIO_UPDATER_CURRENT_APP:-}" || -n "${SCANSTUDIO_UPDATER_NEW_APP:-}" ]]; then
    if [[ -z "${SCANSTUDIO_UPDATER_CURRENT_APP:-}" || -z "${SCANSTUDIO_UPDATER_NEW_APP:-}" ]]; then
        fail "SCANSTUDIO_UPDATER_CURRENT_APP and SCANSTUDIO_UPDATER_NEW_APP must be set together"
    fi
    current_app="$SCANSTUDIO_UPDATER_CURRENT_APP"
    new_app="$SCANSTUDIO_UPDATER_NEW_APP"
else
    current_app="$WORK/current/ScanStudio.app"
    new_app="$WORK/new/ScanStudio.app"
    make_fake_app "$current_app" "0.3.0-alpha.10" "old"
    make_fake_app "$new_app" "0.3.0-beta.1" "new"
fi

for app in "$current_app" "$new_app"; do
    [[ -d "$app" ]] || fail "app bundle missing: $app"
done
pass "resolve: current=$current_app new=$new_app"

# ---- Step 2: check Apple Silicon release metadata against known bytes -----
host_arch="$(uname -m)"
[[ "$host_arch" == arm64 ]] || fail "Apple Silicon macOS is required"
# Only hashing is under test here: zip bytes stand in for a DMG. This fixture
# is never mounted or installed; real DMG verification lives in package_dmg.sh.
host_zip="$WORK/ScanStudio-$VERSION-macOS-arm64.dmg"
ditto -c -k --keepParent "$new_app" "$host_zip" || fail "ditto $new_app -> $host_zip"

staging="$WORK/staging"
if ! "$EMITTER" "$host_zip" "$VERSION" "$staging" "$host_arch" >"$WORK/emit.log" 2>&1; then
    cat "$WORK/emit.log" >&2
    fail "emit_release_assets.sh (01-01 emitter, host arch)"
fi
[[ -f "$staging/latest.json" ]]  || fail "emitter produced no latest.json"
[[ -f "$staging/SHA256SUMS" ]]   || fail "emitter produced no SHA256SUMS"
grep -q "\"version\": \"$VERSION\"" "$staging/latest.json" || fail "latest.json version mismatch"
host_expected="$(shasum -a 256 "$host_zip" | awk '{print $1}')"
recorded="$(awk '{print $1}' "$staging/SHA256SUMS")"
[[ "$host_expected" == "$recorded" ]] || fail "SHA256SUMS does not match the seeded host artifact"
pass "seed: emit_release_assets.sh -> latest.json + SHA256SUMS ($VERSION, host=$host_arch, sha256 $recorded)"

python3 - "$staging/latest.json" "$VERSION" "$host_expected" <<'PYCODE'
import json, sys
with open(sys.argv[1]) as handle:
    pointer = json.load(handle)
assert set(pointer["architectures"]) == {"arm64"}
entry = pointer["architectures"]["arm64"]
assert entry["sha256"] == sys.argv[3]
assert entry["url"].endswith(f"/ScanStudio-{sys.argv[2]}-macOS-arm64.dmg")
PYCODE
pass "seed: latest.json contains only the Apple Silicon artifact"

# ---- Step 3: drive the wired flow in-process (Swift harness) ----------------
# UpdateFlowIntegrationTests runs pointer -> GitHubUpdateChecker ->
# UpdateDownloader (SHA-256 verified) -> UpdateInstaller (snapshot / swap /
# rollback, corrupt-checksum rejection) fully offline against synthetic
# fixtures. Phase 02: the suite's arch-selected cases prove the updater
# selects + installs the HOST architecture's entry from the arch-keyed
# pointer, rejects cross-arch byte mismatches at the checksum gate, and
# surfaces the typed unsupported-architecture error for a missing arch — the
# Phase-01 swap/rollback integrity is unchanged. Fail-loud: a non-green run
# aborts here, so a bad wiring cannot reach VERIFY_UPDATER OK.
printf '[verify_updater] running: swift test --filter UpdateFlowIntegrationTests\n'
if ! (cd "$SWIFT_DIR" && swift test --filter UpdateFlowIntegrationTests >"$WORK/swift-test.log" 2>&1); then
    tail -60 "$WORK/swift-test.log" >&2
    fail "UpdateFlowIntegrationTests harness"
fi
grep -q "Executed " "$WORK/swift-test.log" || fail "harness produced no test summary"
summary="$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failure' "$WORK/swift-test.log" | tail -1 || true)"
[[ -n "$summary" ]] && printf '%s\n' "$summary"
pass "harness: UpdateFlowIntegrationTests (pointer -> check -> download -> verify -> snapshot -> swap -> rollback) green"

# ---- Step 4: acceptance evidence ---------------------------------------------
printf 'VERIFY_UPDATER OK (host=%s, arch-selected flow offline)\n' "$host_arch"
