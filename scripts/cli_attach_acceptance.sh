#!/usr/bin/env bash
# cli_attach_acceptance.sh — phase gate for SSCLI-02 (Control Socket & CLI,
# Attach Mode) and SSCLI-03 (Headless Mode & Parity)'s D-18 automation
# surfaces.
#
# What this proves: the real `scanstudio-cli` binary drives a real,
# in-process host bound to the real `scanstudio-engine` binary end to end
# against `sim-ls5000-0` over the real control socket -- connect, status,
# preview, frame selection, settings/outputs, save, stop, resume, scan,
# eject, diagnostics export, events --follow, plus the CONFIRMATION_REQUIRED
# and HOST_UNREACHABLE negative paths. This is `ControlSocketEndToEndTests`
# (app/ScanStudio/Tests/ScanStudioKitTests/ControlSocketEndToEndTests.swift).
#
# D-18 (plan 03-07): the suite's own second `@Test`, `d18AutomationSurfaces`,
# additionally proves seven automation surfaces this phase's other plans
# added, all against `sim-ls5000-0` with the simulator's `boundaryAndBlank`
# preview fixture armed: `status --refresh` reporting `scanner`; pre-project
# `frames list` carrying a non-null `blankConfidence` for every frame;
# `frames select --skip-blank` skipping the blank fixture frame while
# keeping the flagged-but-textured one; `roll save` pausing at
# `manualReviewPending` with a numeric `contentConfidence`; `roll save
# --auto-approve` resolving that same pause (and refusing without
# `--confirm-motion` before any connection); `roll run`'s own receipt
# (every D-15 step present, terminal `jobState`, the on-disk copy beside an
# untouched `manifest.json`); and a measured, non-fabricated `etaSeconds`
# together with at least one `--wait` progress line on stderr.
#
# D-19..D-24 (plan 03-08): the suite's own third `@Test`,
# `aBatchAbortIsAttributedAndRecoverableThroughTheCLIAlone`, replays the
# 2026-09-07 real-hardware batch-abort-at-frame-10 recovery against
# `sim-ls5000-0`'s batch-abort test affordance and proves the whole
# recovery is possible from the CLI alone: the aborted frame is attributed
# to the bridge condition that raised it (never flattened to INTERNAL),
# every later frame is reported `notAttempted` (not `failed`), `job get`
# and `status --job` return the same terminal snapshot after `jobId`
# clears, the failed frame is excluded without reopening the roll, the
# rest of the roll resumes and completes, and `frames exclude` reports
# which of the requested frames it actually applied.
#
# Order actually run vs. D-17c: D-17c's literal shape is "... -> save ->
# scan --wait -> ...". This suite runs connect -> preview -> frames select
# --all -> save (which itself starts a job) -> stop -> frames list/exclude/
# include -> re-preview -> resume --wait -> scan --wait -> eject ->
# diagnostics -> events, with two required deviations from D-17c's literal
# order, both recorded in full in that file's own header: frames list/
# exclude/include move to after save (they need an open project, which a
# preview alone never creates), and a re-preview is inserted between stop
# and resume (a stopped job clears its own preview registration by design).
# `frames select --all` (CR-02, a code-review fix) runs right after preview
# so a pure CLI-only session can populate the selection `save` requires
# without any host-side bridge. Coverage, not order, is the contract either
# way.
# What this does NOT prove: no real hardware, no packaging, no signing, no
# notarization, no GUI. `scripts/verify_mac_acceptance.py` and
# `scripts/verify_updater.sh` cover other parts of the acceptance surface.
#
# Touches only its own $WORK temp directory and the two build trees it owns
# (engine/target, .build). Never a real scanner, `~/.scanstudio/`, or
# `~/ScanStudio Projects` -- the suite's own in-process host isolates that
# (a short /tmp socket, an overridden HOME for the engine subprocess).
#
# Environment overrides:
#   HOST_MODE   which host the suite drives its CLI subprocesses against.
#               Defaults to "in-process" (Phase 2's only value; Phase 3
#               adds "headless", Phase 4 "bundle"). Read by the suite
#               itself via the identically-named variable.
#
# Exit code is nonzero on any failure; a green run ends with VERIFY_CLI_ATTACH OK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT/app/ScanStudio"
ENGINE_DIR="$SWIFT_DIR/engine"

HOST_MODE="${HOST_MODE:-in-process}"
case "$HOST_MODE" in
  in-process) ;;
  *)
    printf 'FAIL unknown HOST_MODE "%s" (Phase 2 implements only "in-process"; Phase 3 adds "headless", Phase 4 adds "bundle")\n' "$HOST_MODE" >&2
    exit 1
    ;;
esac
export HOST_MODE

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# T-02-37/T-02-38: never hand the engine or the CLI a developer environment
# that could reach real hardware or a hook script, mirroring
# verify_mac_acceptance.py's isolated_environment(root). The suite's own
# in-process host applies the same scrub (and a scoped HOME override) a
# second time around the real engine subprocess it spawns directly --
# belt and suspenders, not a substitute for either layer.
unset SCANSTUDIO_BRIDGE_CMD SCANSTUDIO_HW_MOTION SCANSTUDIO_BRIDGE_SOURCE \
    SCANSTUDIO_BRIDGE_PYTHON SCANSTUDIO_BRIDGE_TRANSPORT SCANSTUDIO_BRIDGE_BASE_DIR

if ! command -v cargo >/dev/null 2>&1; then
    fail "Rust Cargo is required; install it and make sure cargo is on PATH"
fi
if ! command -v swift >/dev/null 2>&1; then
    fail "the Swift toolchain is required; install it and make sure swift is on PATH"
fi
pass "toolchain: cargo and swift found on PATH"

# ---- Stage 1: build the debug engine, and point the suite at it ----------
# Debug, not release: this is what the plan's own verify command builds
# and what plan 02-07's own development runs proved fast enough (a debug
# build's own compile cost is the only tradeoff, and this script pays it
# once). Never a packaged bundle's engine (D-05's fallback order) --
# SCANSTUDIO_ENGINE_PATH wins outright over every other resolution step.
printf '[cli_attach_acceptance] building engine (debug)...\n'
if ! (cd "$ENGINE_DIR" && cargo build) >"$WORK/cargo-build.log" 2>&1; then
    tail -60 "$WORK/cargo-build.log" >&2
    fail "cargo build (engine)"
fi
ENGINE_BIN="$ENGINE_DIR/target/debug/scanstudio-engine"
[ -x "$ENGINE_BIN" ] || fail "engine binary not found at $ENGINE_BIN after build"
export SCANSTUDIO_ENGINE_PATH="$ENGINE_BIN"
pass "engine built: $ENGINE_BIN"

# ---- Stage 2: build the CLI ------------------------------------------------
printf '[cli_attach_acceptance] building scanstudio-cli...\n'
if ! (cd "$SWIFT_DIR" && swift build --product scanstudio-cli) >"$WORK/swift-build.log" 2>&1; then
    tail -60 "$WORK/swift-build.log" >&2
    fail "swift build --product scanstudio-cli"
fi
CLI_BIN="$SWIFT_DIR/.build/debug/scanstudio-cli"
[ -x "$CLI_BIN" ] || fail "scanstudio-cli binary not found at $CLI_BIN after build"
pass "CLI built: $CLI_BIN"

# ---- Stage 3: run the end-to-end suite ------------------------------------
# Opt-in for a bare `swift test` (SCANSTUDIO_CLI_E2E=1), but mandatory
# here -- this is the one place in the repository this suite is required
# to run. No retry: a single run, once, fails the whole script if it fails.
printf '[cli_attach_acceptance] running: swift test --filter ScanStudioKitTests.ControlSocketEndToEndTests\n'
if ! (cd "$SWIFT_DIR" && SCANSTUDIO_CLI_E2E=1 swift test --filter ScanStudioKitTests.ControlSocketEndToEndTests) >"$WORK/swift-test.log" 2>&1; then
    tail -100 "$WORK/swift-test.log" >&2
    fail "ControlSocketEndToEndTests"
fi
grep -q "Control socket end to end" "$WORK/swift-test.log" || fail "suite did not report running (opt-in gate misconfigured?)"
# D-18 (plan 03-07): a second, independent name check so a filtered-out or
# silently-skipped d18AutomationSurfaces test cannot pass this gate --
# mirrors the suite-name check immediately above. "D-18:" is this test's
# own display-name prefix (ControlSocketEndToEndTests.swift), unique to it.
grep -q "D-18:" "$WORK/swift-test.log" || fail "the D-18 automation-surfaces test did not report running (opt-in gate misconfigured, or the test was filtered out)"
# D-19..D-24 (plan 03-08): a third, independent name check so a filtered-out
# or silently-skipped batch-abort-recovery test cannot pass this gate --
# mirrors the D-18 check immediately above. "D-19..D-24:" is this test's own
# display-name prefix (ControlSocketEndToEndTests.swift), unique to it.
grep -q "D-19..D-24:" "$WORK/swift-test.log" || fail "the D-19..D-24 batch-abort-recovery test (aBatchAbortIsAttributedAndRecoverableThroughTheCLIAlone) did not report running (opt-in gate misconfigured, or the test was filtered out)"
pass "harness: ControlSocketEndToEndTests (connect -> preview -> save -> stop -> resume -> scan -> eject -> diagnostics -> events, plus D-18: status --refresh, pre-project blankConfidence, skip-blank, manual review + auto-approve, roll run's own receipt, measured progress/ETA, and D-19..D-24: batch-abort attribution + CLI-only recovery) green"

# ---- Stage 4: acceptance evidence -----------------------------------------
printf 'VERIFY_CLI_ATTACH OK (host-mode=%s, engine=%s, cli=%s)\n' "$HOST_MODE" "$ENGINE_BIN" "$CLI_BIN"
