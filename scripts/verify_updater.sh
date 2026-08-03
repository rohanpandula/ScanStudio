#!/bin/zsh
# verify_updater.sh — seeded, end-to-end updater verification gate (01-06).
#
# Proves the whole delivered auto-update pipeline on fake, on-disk fixtures:
#   emit release assets -> resolve pointer -> check -> download -> SHA-256
#   verify -> snapshot -> swap -> rollback.
#
# Phase 02 (02-03): the seeded pointer is arch-keyed — the 01-01 emitter is
# invoked for the HOST architecture and then a second fake x86_64 entry with a
# distinct sha is injected, so the pointer carries BOTH architectures exactly
# as the matrix publish job produces. The script asserts the host entry is
# present and correct, and the Swift harness (whose arch-selected e2e cases
# run here) proves the updater selects + installs the HOST architecture's
# artifact while cross-arch / unsupported-arch cases are rejected. Real Intel
# (x86_64) bundle execution only happens on the CI x86_64 leg, never here
# (no Rosetta on this arm64 host — see 02-CONTEXT.md); local proof is
# host-arch selection + SHA-256 hash integrity, fully offline.
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

# ---- Step 2: seed the "release" via the 01-01 emitter (arch-keyed) ---------
# The emitter's CDN story is irrelevant offline; it only hashes its file
# argument. The new bundle zipped stands in for the DMG. The pointer is
# arch-keyed: first emit for the HOST arch, then inject a fake second arch
# entry (distinct sha) so the pointer carries both archs like the CI matrix
# publish job.
host_arch="$(uname -m)"
case "$host_arch" in
    arm64)  other_arch="x86_64" ;;
    x86_64) other_arch="arm64"  ;;
    *) fail "unsupported host architecture: $host_arch" ;;
esac

host_zip="$WORK/ScanStudio-$VERSION-macOS-$host_arch.zip"
other_zip="$WORK/ScanStudio-$VERSION-macOS-$other_arch.zip"
ditto -c -k --keepParent "$new_app" "$host_zip" || fail "ditto $new_app -> $host_zip"
other_app="$WORK/other/ScanStudio.app"
make_fake_app "$other_app" "$VERSION" "intel"
ditto -c -k --keepParent "$other_app" "$other_zip" || fail "ditto $other_app -> $other_zip"

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

# ---- Step 2b: inject the second arch entry (distinct sha) ------------------
# Re-invoking the emitter with the SAME version + the OTHER arch merges the
# entry in (merge-don't-clobber), mirroring the matrix publish job's combined
# pointer. The two arch entries must describe distinct artifacts.
if ! "$EMITTER" "$other_zip" "$VERSION" "$staging" "$other_arch" >"$WORK/emit2.log" 2>&1; then
    cat "$WORK/emit2.log" >&2
    fail "emit_release_assets.sh (01-01 emitter, other arch)"
fi
other_expected="$(shasum -a 256 "$other_zip" | awk '{print $1}')"
[[ "$host_expected" != "$other_expected" ]] || fail "the two arch entries must have distinct shas"
grep -q "\"$host_arch\":"  "$staging/latest.json" || fail "latest.json missing host-arch ($host_arch) entry"
grep -q "\"$other_arch\":" "$staging/latest.json" || fail "latest.json missing other-arch ($other_arch) entry"
grep -q "ScanStudio-$VERSION-macOS-$host_arch.zip"  "$staging/latest.json" || fail "latest.json host url mismatch"
grep -q "ScanStudio-$VERSION-macOS-$other_arch.zip" "$staging/latest.json" || fail "latest.json other url mismatch"
grep -q "$host_expected" "$staging/latest.json"  || fail "latest.json host sha mismatch"
grep -q "$other_expected" "$staging/latest.json" || fail "latest.json other sha mismatch"
pass "seed: arch-keyed latest.json carries BOTH $host_arch + $other_arch (host selection asserted)"

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
