#!/usr/bin/env bash
# Functional simulation for the install-bridge-wsl.sh shebang-swap fix.
#
# THE BUG THIS GUARDS: pip/distlib write every console-script entrypoint
# (python/bin/scanstudio-bridge and friends) with a `#!` shebang that embeds,
# literally and unresolved, the exact interpreter path used to invoke pip.
# The pre-fix script ran every pip install against the mktemp staging
# python, then renamed the staging directory into place -- so every shebang
# it wrote pointed at a `.wsl-bridge-install.XXXXXX` path that no longer
# existed once the rename (and the script's own EXIT trap) were done. Every
# real install produced a bridge wrapper that could not execute.
#
# WHAT THIS PROVES, self-contained, no WSL/root/network/real-pip required:
#   1. Swapping the verified staging tree into $install_root BEFORE any pip
#      install runs, then running pip against $install_root's own python,
#      makes every generated shebang embed the path that will still exist
#      once the script finishes.
#   2. A failure after that swap restores the previous install (or removes
#      the broken attempt when there was no previous install) -- no
#      half-installed state is left behind either way.
#   3. The EUID-0 refusal is present and would block before any install step
#      runs.
#
# HOW: this is a simulation, not a replay of install-bridge-wsl.sh's exact
# checksum/apt-get/system-install gates -- those need the real pinned
# CPython tarball's SHA-256, real apt, and a real write to the shared
# /usr/local/bin, none of which belong in a sandboxed test. Scenarios A-E
# below instead reproduce the staging/swap/pip/verify/rollback control flow
# install-bridge-wsl.sh runs from its `stage_root=$(mktemp ...)` line
# onward -- same variable names, same restore_broken_install /
# cleanup_and_maybe_rollback trap functions, same shebang-parsing snippet,
# copied to read side by side with that script -- against a real gzipped
# tarball, real `mv`/`tar`, and a fake python3.13 whose one job is to mimic
# the one pip/distlib behavior this fix depends on: writing a console-script
# whose first line is `#!<the exact path it was invoked as>`.
#
# Run manually:
#   bash ports/tauri/packaging/windows/tests/simulate-shebang-swap-order.sh
#
# Exit 0 and "ALL SCENARIOS PASSED" on success; nonzero and a PASS/FAIL
# ledger otherwise. Not wired into .github/workflows/ports.yml -- none of
# its jobs currently execute install-bridge-wsl.sh's own logic (the
# windows-resources job only assembles/verifies bundle *contents*, and the
# actual install only ever runs for real inside WSL2 on the windows job via
# build-and-verify.ps1). Wiring a dedicated linux-runnable step for this
# script would be a small, separate change to ports.yml; until then, run it
# manually after touching install-bridge-wsl.sh.

set -euo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$tests_dir/../install-bridge-wsl.sh"

[[ -f "$installer" ]] || {
    printf 'FAIL  cannot find install-bridge-wsl.sh next to tests/ at %s\n' "$installer" >&2
    exit 66
}

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

line_of() {
    # First line number in $1 that contains the literal (non-regex) text
    # $2, or empty if not found.
    grep -n -F -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# Root refusal (item 6). Actually becoming EUID 0 to test this for real is
# neither safe nor necessary to script; instead: (a) confirm the guard is
# present, verbatim, in the shipped script, and runs before anything is
# created on disk; (b) exercise its exact boundary condition (0 refused,
# anything else allowed) via a function with an identical condition and exit
# code, so an off-by-one in the condition itself would still be caught.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # intentional: grepping the installer for this
# literal shell text, not expanding $EUID in this test script.
if grep -Fq 'if [[ "$EUID" -eq 0 ]]; then' "$installer" && grep -Fq 'exit 77' "$installer"; then
    pass "shipped script contains the EUID-0 refusal guard (exit 77)"
else
    fail "shipped script is missing the literal EUID-0 refusal guard"
fi

# shellcheck disable=SC2016 # same as above: literal text to grep for.
euid_line="$(line_of "$installer" '"$EUID" -eq 0')"
# shellcheck disable=SC2016 # same as above: literal text to grep for.
mktemp_line="$(line_of "$installer" 'stage_root="$(mktemp -d')"
if [[ -n "$euid_line" && -n "$mktemp_line" ]] && (( euid_line < mktemp_line )); then
    pass "EUID-0 refusal (line $euid_line) runs before the staging directory is created (line $mktemp_line)"
else
    fail "EUID-0 refusal ordering check failed (euid_line=${euid_line:-<missing>} mktemp_line=${mktemp_line:-<missing>})"
fi

refuse_if_root_like_installer() {
    # Mirrors install-bridge-wsl.sh's exact condition and exit code.
    local simulated_euid="$1"
    if [[ "$simulated_euid" -eq 0 ]]; then
        return 77
    fi
    return 0
}

rc=0
refuse_if_root_like_installer 0 || rc=$?
if [[ "$rc" -eq 77 ]]; then
    pass "root-refusal condition blocks EUID 0 (exit 77)"
else
    fail "root-refusal condition did not block EUID 0 as expected (got exit $rc)"
fi

rc=0
refuse_if_root_like_installer 1000 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "root-refusal condition allows a non-root EUID (1000) through"
else
    fail "root-refusal condition incorrectly blocked a non-root EUID (got exit $rc)"
fi

# ---------------------------------------------------------------------------
# Sandbox root. Deliberately short and rooted directly at /tmp rather than
# derived from $TMPDIR or the current working directory: a shebang line has
# a real, OS-enforced maximum length (macOS and Linux both impose one, values
# differ by kernel), and this repo's own CWD can be deeply nested. A long
# sandbox path would make this test fail on shebang-length grounds that have
# nothing to do with the fix under test -- confirmed empirically while
# writing this script. Real installs are not at risk: the production path is
# a short, fixed depth under $XDG_DATA_HOME/scanstudio/wsl-bridge/.
# ---------------------------------------------------------------------------
all_sandboxes=()
new_sandbox() {
    local d
    d="$(mktemp -d /tmp/scanstudio-wsl-sim.XXXXXX)"
    all_sandboxes+=("$d")
    printf '%s\n' "$d"
}
cleanup_sandboxes() {
    # set +e: this runs as an EXIT trap under `set -e`. A bare
    # `[[ cond ]] && cmd` whose condition is ever false makes the whole
    # statement's status nonzero and would abort this trap mid-loop (same
    # class of pitfall as cleanup_and_maybe_rollback's own set +e guard
    # above, and the reason it has one) -- skipping the rest of the cleanup
    # and, since nothing here calls exit explicitly, silently turning this
    # script's true 0/1 pass/fail result into a spurious 1 regardless of
    # how the scenarios actually went. Confirmed empirically.
    set +e
    local d
    for d in "${all_sandboxes[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup_sandboxes EXIT

# ---------------------------------------------------------------------------
# Fake python3.13. Every invocation is appended to $FAKE_PYTHON_LOG as
# "INVOKED_AS=... PWD=... ARGS=...". $FAKE_PYTHON_FAIL_AT selects which real
# pip/import-smoke step (if any) should fail, to drive the rollback
# scenarios below.
# ---------------------------------------------------------------------------
fake_python_src="$(new_sandbox)/fake-python3.13.sh"
cat > "$fake_python_src" <<'FAKEPY'
#!/usr/bin/env bash
# Fake python3.13 used ONLY by simulate-shebang-swap-order.sh. Mimics the one
# real CPython/pip/distlib behavior this fix depends on: a generated
# console-script's first line is `#!<the exact interpreter path invoked>` --
# not a path resolved, canonicalized, or looked up any other way.
set -euo pipefail
invoked_as="$0"
if [[ -n "${FAKE_PYTHON_LOG:-}" ]]; then
    printf 'INVOKED_AS=%s PWD=%s ARGS=%s\n' "$invoked_as" "$(pwd)" "$*" >> "$FAKE_PYTHON_LOG"
fi
fail_marker="${FAKE_PYTHON_FAIL_AT:-}"

case "${1:-}" in
    -c)
        case "${2:-}" in
            *sys.version_info*)
                printf '3.13.14\n'
                exit 0
                ;;
            *)
                printf 'fake-python: unrecognized -c payload: %s\n' "${2:-}" >&2
                exit 1
                ;;
        esac
        ;;
    -I)
        # -I -c '<import smoke payload>'
        if [[ "$fail_marker" == "import-smoke" ]]; then
            printf 'fake-python: simulated import-smoke failure\n' >&2
            exit 1
        fi
        printf 'bridge imports: OK\n'
        exit 0
        ;;
    -m)
        # -m pip install ... [--find-links|--requirement <path> | <source-dir>]
        last="${*: -1}"
        case "$last" in
            */scanstudio-bridge)
                if [[ "$fail_marker" == "pip-bridge" ]]; then
                    printf 'fake-python: simulated pip failure installing scanstudio-bridge\n' >&2
                    exit 1
                fi
                bin_dir="$(dirname "$invoked_as")"
                {
                    printf '#!%s\n' "$invoked_as"
                    printf '# fake console-script entrypoint (simulation only) -- real pip/distlib\n'
                    printf '# write exactly this: a literal, unresolved interpreter path on line 1,\n'
                    printf '# taken verbatim from the interpreter that ran pip.\n'
                } > "$bin_dir/scanstudio-bridge"
                chmod 755 "$bin_dir/scanstudio-bridge"
                printf 'Successfully installed scanstudio-bridge (fake)\n'
                exit 0
                ;;
            */coolscanpy)
                if [[ "$fail_marker" == "pip-coolscanpy" ]]; then
                    printf 'fake-python: simulated pip failure installing coolscanpy\n' >&2
                    exit 1
                fi
                printf 'Successfully installed coolscanpy (fake)\n'
                exit 0
                ;;
            *)
                # The wheelhouse/--requirement install: no local project dir.
                if [[ "$fail_marker" == "pip-wheelhouse" ]]; then
                    printf 'fake-python: simulated pip failure installing wheelhouse deps\n' >&2
                    exit 1
                fi
                printf 'Successfully installed wheelhouse dependencies (fake)\n'
                exit 0
                ;;
        esac
        ;;
    *)
        if [[ -n "${1:-}" && -f "${1:-}" ]]; then
            # Invoked as the shebang interpreter for a generated console
            # script: argv = [<script-path>, <original args...>]. This
            # proves the OS actually resolved and ran the shebang this fake
            # pip wrote, via the real kernel #! mechanism -- not a string
            # comparison inside this test.
            script="$1"; shift
            if [[ "$fail_marker" == "wrapper-version" ]]; then
                printf 'fake-python: simulated entrypoint failure for %s\n' "$script" >&2
                exit 1
            fi
            printf 'scanstudio-bridge (fake, simulation) invoked-as=%s script=%s args=%s\n' \
                "$invoked_as" "$script" "$*"
            exit 0
        fi
        printf 'fake-python: unrecognized invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
FAKEPY
chmod +x "$fake_python_src"

build_fake_cpython_tarball() {
    # $1 = output tarball path. Real gzipped tarball, real tar -xzf below --
    # only the CPython build itself is faked, not the archive format.
    local out="$1" version_report="${2:-3.13.14}" build
    build="$(mktemp -d /tmp/scanstudio-wsl-sim-build.XXXXXX)"
    mkdir -p "$build/python/bin"
    if [[ "$version_report" == "3.13.14" ]]; then
        cp "$fake_python_src" "$build/python/bin/python3.13"
    else
        # A "bad" archive whose interpreter reports the wrong version, for
        # the pre-swap-failure scenario (E).
        cat > "$build/python/bin/python3.13" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-c" ]]; then printf '%s\n' "$version_report"; exit 0; fi
exit 0
EOF
    fi
    chmod +x "$build/python/bin/python3.13"
    tar -czf "$out" -C "$build" python
    rm -rf -- "$build"
}

# ---------------------------------------------------------------------------
# Core simulation. Mirrors install-bridge-wsl.sh from `stage_root=$(mktemp
# ...)` through the post-install verification -- keep this in lockstep with
# that script if its control flow changes.
# ---------------------------------------------------------------------------
run_simulated_install() {
    local install_parent="$1" cpython_tarball="$2" coolscanpy_source="$3" bridge_source="$4"
    local install_root="$install_parent/wsl-bridge"
    mkdir -p "$install_parent"

    local stage_root rollback_root="" swap_started=0
    stage_root="$(mktemp -d "$install_parent/.wsl-bridge-install.XXXXXX")"

    # shellcheck disable=SC2329 # invoked from cleanup_and_maybe_rollback below, itself trap-invoked.
    restore_broken_install() {
        if [[ -n "$stage_root" && -d "$stage_root" ]]; then
            rm -rf -- "$stage_root"
        fi
        if [[ -e "$install_root" ]]; then
            rm -rf -- "$install_root"
        fi
        if [[ -n "$rollback_root" && -e "$rollback_root" ]]; then
            mv "$rollback_root" "$install_root"
            printf 'Restored the previous install at %s\n' "$install_root" >&2
        else
            printf 'No usable install was left in place (no previous install to restore).\n' >&2
        fi
    }

    # shellcheck disable=SC2329 # invoked via `trap ... EXIT` immediately below.
    cleanup_and_maybe_rollback() {
        local exit_code=$?
        set +e
        if [[ "$swap_started" -ne 1 ]]; then
            if [[ -n "$stage_root" && -d "$stage_root" ]]; then
                rm -rf -- "$stage_root"
            fi
            exit "$exit_code"
        fi
        if [[ "$exit_code" -eq 0 ]]; then
            exit 0
        fi
        printf '\n%s\n' '=== Install failed after the new runtime was swapped in; rolling back ===' >&2
        restore_broken_install
        exit "$exit_code"
    }
    trap cleanup_and_maybe_rollback EXIT

    tar -xzf "$cpython_tarball" -C "$stage_root"
    local python_bin="$stage_root/python/bin/python3.13"
    [[ -x "$python_bin" ]] || { printf 'fake cpython archive missing python/bin/python3.13\n' >&2; exit 65; }
    if [[ "$("$python_bin" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')" != "3.13.14" ]]; then
        printf 'fake python did not report the pinned version\n' >&2
        exit 65
    fi

    mkdir -p "$stage_root/sources/coolscanpy" "$stage_root/sources/scanstudio-bridge"
    cp -a "$coolscanpy_source/." "$stage_root/sources/coolscanpy/"
    cp -a "$bridge_source/." "$stage_root/sources/scanstudio-bridge/"

    # The swap: identical ordering/guard placement to install-bridge-wsl.sh.
    if [[ -e "$install_root" ]]; then
        rollback_root="$install_parent/wsl-bridge.previous.$(date -u +%Y%m%dT%H%M%SZ).$$"
        mv "$install_root" "$rollback_root"
    fi
    # $install_root is now guaranteed empty (never existed, or just vacated
    # above), so swap_started=1 from here on can always safely reclaim it --
    # never the still-good previous install. See install-bridge-wsl.sh's
    # comment at the same point for the full reasoning (this ordering is the
    # part a "failure exactly between the two mv's" edge case depends on).
    swap_started=1
    mv "$stage_root" "$install_root"
    stage_root=""
    local install_sources="$install_root/sources"
    python_bin="$install_root/python/bin/python3.13"

    CC=gcc CXX=g++ "$python_bin" -m pip install \
        --disable-pip-version-check --no-index --find-links "$install_parent" \
        --require-hashes --requirement "$install_parent/fake-requirements.txt"

    "$python_bin" -m pip install \
        --disable-pip-version-check --no-index --no-deps --no-build-isolation \
        "$install_sources/coolscanpy"

    "$python_bin" -m pip install \
        --disable-pip-version-check --no-index --no-deps --no-build-isolation \
        "$install_sources/scanstudio-bridge"

    "$python_bin" -I -c \
        'import coolscanpy, sane, scanstudio_bridge; print("bridge imports: OK")'

    local wrapper_tmp
    wrapper_tmp="$(mktemp)"
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_root/python/bin/scanstudio-bridge" > "$wrapper_tmp"
    chmod 755 "$wrapper_tmp"
    mkdir -p "$install_parent/usr-local-bin"
    install -m 755 "$wrapper_tmp" "$install_parent/usr-local-bin/scanstudio-bridge"
    rm -f -- "$wrapper_tmp"

    # Post-install verification: identical snippet to install-bridge-wsl.sh.
    local bridge_entrypoint="$install_root/python/bin/scanstudio-bridge"
    [[ -f "$bridge_entrypoint" ]] || { printf 'post-install check failed: missing %s\n' "$bridge_entrypoint" >&2; exit 70; }
    local shebang_line shebang_interpreter
    shebang_line="$(head -n 1 -- "$bridge_entrypoint")"
    case "$shebang_line" in
        '#!'*)
            shebang_interpreter="${shebang_line#\#!}"
            shebang_interpreter="${shebang_interpreter%% *}"
            ;;
        *)
            shebang_interpreter=""
            ;;
    esac
    if [[ -z "$shebang_interpreter" || ! -x "$shebang_interpreter" ]]; then
        printf 'post-install check failed: %s has no usable #! interpreter (got %q)\n' \
            "$bridge_entrypoint" "$shebang_interpreter" >&2
        exit 70
    fi
    if [[ "$shebang_interpreter" != "$python_bin" ]]; then
        printf 'post-install check failed: %s shebang is %q, expected %q\n' \
            "$bridge_entrypoint" "$shebang_interpreter" "$python_bin" >&2
        exit 70
    fi
    if ! "$install_parent/usr-local-bin/scanstudio-bridge" --version </dev/null; then
        printf 'post-install check failed: wrapper --version exited nonzero\n' >&2
        exit 70
    fi

    printf 'SIMULATED INSTALL OK: %s\n' "$install_root"
    # Explicit exit, not a plain return: `trap ... EXIT` above was registered
    # on this (sub)shell, not scoped to this function. A plain `return` would
    # leave the function's `local`s (swap_started, stage_root, ...) popped by
    # the time the subshell reaches its own natural end and the same trap
    # fires again -- an unbound-variable crash under `set -u`, confirmed
    # empirically while writing this harness. Exiting here, still inside
    # this function's dynamic scope, makes the trap fire exactly once with
    # every variable it reads still live -- exactly how every failure exit
    # above already behaves, and how install-bridge-wsl.sh's own top-level
    # (non-function) trap naturally behaves throughout.
    exit 0
}

seed_previous_install() {
    # Plants a fake "already installed" tree at $1/wsl-bridge with a marker
    # file, so restore-fidelity assertions can tell old content from new.
    local install_root="$1/wsl-bridge"
    mkdir -p "$install_root/python/bin"
    printf 'old-install-content\n' > "$install_root/OLD-MARKER"
    printf '#!/usr/bin/env bash\necho old-fake-python\n' > "$install_root/python/bin/python3.13"
    chmod +x "$install_root/python/bin/python3.13"
}

seed_bundle_sources() {
    # $1 = install_parent. Minimal source/wheelhouse placeholders; the fake
    # python never reads their contents, only argv shape, so these just need
    # to exist and look plausible.
    mkdir -p "$1/CorrespondingSource/coolscanpy" "$1/CorrespondingSource/scanstudio-bridge"
    printf '[project]\nname = "coolscanpy"\n' > "$1/CorrespondingSource/coolscanpy/pyproject.toml"
    printf '[project]\nname = "scanstudio-bridge"\n' > "$1/CorrespondingSource/scanstudio-bridge/pyproject.toml"
    : > "$1/fake-requirements.txt"
}

# Runs `run_simulated_install "$@"` in its own subshell (so its trap, its
# `local`s, and any `set +e`/`set -e` it does stay contained to that one
# install attempt) and leaves its exit code in $SCENARIO_RC, without letting
# a nonzero result abort this outer script. Two non-obvious bash pitfalls,
# both confirmed empirically while writing this harness, shape how this has
# to be written:
#
# 1. The obvious `( run_simulated_install "$@" ) || rc=$?` looks equivalent
#    but is NOT: POSIX/bash exempt the left side of `||` (and an `if`
#    condition) from errexit entirely, and that exemption recurses into
#    every command the subshell runs -- so every injected pip/import-smoke
#    failure inside run_simulated_install was silently swallowed (execution
#    just carried on to the next line) instead of aborting at the point of
#    failure the way install-bridge-wsl.sh's own top-level `set -e` does.
# 2. Fixing #1 by re-asserting `set -euo pipefail` as the subshell's first
#    command (`( set -euo pipefail; run_simulated_install "$@" )`) gets
#    errexit working again, but broke something else just as badly the
#    moment that subshell's own stdout/stderr were redirected to a file (as
#    they are below, for scenario-by-scenario evidence): the EXIT trap
#    inside run_simulated_install then fired with its enclosing function's
#    `local`s already gone (an unbound-variable crash) AND with the trap's
#    own output escaping the redirect straight to this script's terminal
#    instead of the log file. Root cause not fully isolated -- some bash
#    interaction between an explicit `set -e` restatement, a redirected
#    subshell, and an EXIT trap that fires via errexit rather than a normal
#    return -- but reliably reproduced and just as reliably avoided by not
#    combining all three: run the subshell as a plain, non-redirected-at-
#    the-subshell-boundary background job instead, so it inherits errexit
#    from this function's *pre*-`set +e` state naturally (no restatement
#    needed) rather than from a context already testing its exit status.
#
# One more placement detail that turned out not to be interchangeable,
# also confirmed empirically: the redirects have to sit directly on this
# `( ... ) &` line itself. Redirecting a *caller's* call to run_scenario
# instead (`run_scenario ... >out 2>err`) reintroduces the exact same
# lost-locals-and-escaped-output failure this function exists to avoid,
# even though the backgrounded subshell inherits run_scenario's file
# descriptors either way for every *other* purpose. Hence out_log/err_log
# are explicit parameters here rather than left to the caller's redirect.
run_scenario() {
    local out_log="$1" err_log="$2"; shift 2
    ( run_simulated_install "$@" ) > "$out_log" 2> "$err_log" &
    local scenario_pid=$!
    set +e
    wait "$scenario_pid"
    SCENARIO_RC=$?
    set -e
}

# ---------------------------------------------------------------------------
# Scenario A: fresh install (no previous install_root), full success.
# ---------------------------------------------------------------------------
{
    parent="$(new_sandbox)"
    seed_bundle_sources "$parent"
    tarball="$parent/cpython.tar.gz"
    build_fake_cpython_tarball "$tarball"
    export FAKE_PYTHON_LOG="$parent/fake-python.log"
    unset FAKE_PYTHON_FAIL_AT || true

    run_scenario "$parent/stdout.log" "$parent/stderr.log" "$parent" "$tarball" \
        "$parent/CorrespondingSource/coolscanpy" "$parent/CorrespondingSource/scanstudio-bridge"
    rc="$SCENARIO_RC"

    install_root="$parent/wsl-bridge"
    python_bin="$install_root/python/bin/python3.13"
    entrypoint="$install_root/python/bin/scanstudio-bridge"

    if [[ "$rc" -eq 0 ]]; then pass "A: fresh install exits 0"; else fail "A: fresh install exited $rc (see $parent/stderr.log)"; fi
    if [[ -f "$entrypoint" ]]; then
        shebang="$(head -1 "$entrypoint")"
        if [[ "$shebang" == "#!$python_bin" ]]; then
            pass "A: generated shebang embeds the FINAL install_root path ($shebang)"
        else
            fail "A: generated shebang is '$shebang', expected '#!$python_bin'"
        fi
    else
        fail "A: entrypoint $entrypoint was never created"
    fi
    if compgen -G "$parent/.wsl-bridge-install.*" > /dev/null 2>&1; then
        fail "A: a staging directory was left behind"
    else
        pass "A: no leftover staging directory"
    fi
    if compgen -G "$parent/wsl-bridge.previous.*" > /dev/null 2>&1; then
        fail "A: an unexpected rollback copy was created for a fresh install"
    else
        pass "A: no rollback copy created (nothing to roll back from)"
    fi
    if [[ -x "$parent/usr-local-bin/scanstudio-bridge" ]] && "$parent/usr-local-bin/scanstudio-bridge" --version </dev/null >/dev/null 2>&1; then
        pass "A: wrapper --version resolves the full two-level shebang chain and exits 0"
    else
        fail "A: wrapper --version did not run cleanly"
    fi
    if [[ -s "$FAKE_PYTHON_LOG" ]] && [[ "$(grep -c '^INVOKED_AS=' "$FAKE_PYTHON_LOG")" -ge 5 ]]; then
        pass "A: fake python logged CWD/argv for every invocation (>=5 recorded)"
    else
        fail "A: expected >=5 logged fake-python invocations, see $FAKE_PYTHON_LOG"
    fi
}

# ---------------------------------------------------------------------------
# Scenario B: --force-style reinstall over an existing install, full success.
# ---------------------------------------------------------------------------
{
    parent="$(new_sandbox)"
    seed_bundle_sources "$parent"
    seed_previous_install "$parent"
    tarball="$parent/cpython.tar.gz"
    build_fake_cpython_tarball "$tarball"
    export FAKE_PYTHON_LOG="$parent/fake-python.log"
    unset FAKE_PYTHON_FAIL_AT || true

    run_scenario "$parent/stdout.log" "$parent/stderr.log" "$parent" "$tarball" \
        "$parent/CorrespondingSource/coolscanpy" "$parent/CorrespondingSource/scanstudio-bridge"
    rc="$SCENARIO_RC"

    install_root="$parent/wsl-bridge"
    python_bin="$install_root/python/bin/python3.13"
    entrypoint="$install_root/python/bin/scanstudio-bridge"
    rollback_dir="$(compgen -G "$parent/wsl-bridge.previous.*" || true)"

    if [[ "$rc" -eq 0 ]]; then pass "B: reinstall-over-existing exits 0"; else fail "B: reinstall-over-existing exited $rc (see $parent/stderr.log)"; fi
    if [[ -n "$rollback_dir" && -f "$rollback_dir/OLD-MARKER" ]]; then
        pass "B: previous install preserved intact as a timestamped rollback copy ($rollback_dir)"
    else
        fail "B: expected exactly one wsl-bridge.previous.* dir containing OLD-MARKER, got '$rollback_dir'"
    fi
    if [[ -e "$install_root/OLD-MARKER" ]]; then
        fail "B: install_root still has the OLD install's marker; new tree did not actually swap in"
    else
        pass "B: install_root holds the NEW tree, not the old one"
    fi
    if [[ -f "$entrypoint" ]] && [[ "$(head -1 "$entrypoint")" == "#!$python_bin" ]]; then
        pass "B: new shebang embeds the final install_root path (not staging, not the old rollback path)"
    else
        fail "B: new entrypoint shebang is wrong: $(head -1 "$entrypoint" 2>/dev/null || echo '<missing>')"
    fi
}

# ---------------------------------------------------------------------------
# Scenario C: failure AFTER the swap, WITH a previous install -> must
# restore it exactly, leaving no orphaned staging or rollback directory.
# ---------------------------------------------------------------------------
{
    parent="$(new_sandbox)"
    seed_bundle_sources "$parent"
    seed_previous_install "$parent"
    tarball="$parent/cpython.tar.gz"
    build_fake_cpython_tarball "$tarball"
    export FAKE_PYTHON_LOG="$parent/fake-python.log"
    export FAKE_PYTHON_FAIL_AT="pip-bridge"

    run_scenario "$parent/stdout.log" "$parent/stderr.log" "$parent" "$tarball" \
        "$parent/CorrespondingSource/coolscanpy" "$parent/CorrespondingSource/scanstudio-bridge"
    rc="$SCENARIO_RC"
    unset FAKE_PYTHON_FAIL_AT

    install_root="$parent/wsl-bridge"
    if [[ "$rc" -eq 1 ]]; then
        pass "C: post-swap pip failure propagates the original exit code (1) through the rollback trap"
    else
        fail "C: expected exit 1 from the injected post-swap failure, got $rc"
    fi
    if [[ -e "$install_root/OLD-MARKER" ]]; then
        pass "C: previous install was restored to install_root after the post-swap failure"
    else
        fail "C: install_root was not restored to the previous install (see $parent/stderr.log)"
    fi
    if compgen -G "$parent/.wsl-bridge-install.*" > /dev/null 2>&1; then
        fail "C: a staging directory was left behind after rollback"
    else
        pass "C: no leftover staging directory after rollback"
    fi
    if compgen -G "$parent/wsl-bridge.previous.*" > /dev/null 2>&1; then
        fail "C: rollback copy was left orphaned instead of being moved back"
    else
        pass "C: rollback copy was consumed (moved back), none left orphaned"
    fi
}

# ---------------------------------------------------------------------------
# Scenario D: failure AFTER the swap, with NO previous install -> broken
# tree is removed, nothing is restored (item 4's explicit no-previous-install
# clause), no orphaned directories of any kind.
# ---------------------------------------------------------------------------
{
    parent="$(new_sandbox)"
    seed_bundle_sources "$parent"
    tarball="$parent/cpython.tar.gz"
    build_fake_cpython_tarball "$tarball"
    export FAKE_PYTHON_LOG="$parent/fake-python.log"
    export FAKE_PYTHON_FAIL_AT="import-smoke"

    run_scenario "$parent/stdout.log" "$parent/stderr.log" "$parent" "$tarball" \
        "$parent/CorrespondingSource/coolscanpy" "$parent/CorrespondingSource/scanstudio-bridge"
    rc="$SCENARIO_RC"
    unset FAKE_PYTHON_FAIL_AT

    install_root="$parent/wsl-bridge"
    if [[ "$rc" -eq 1 ]]; then
        pass "D: post-swap import-smoke failure propagates exit code 1"
    else
        fail "D: expected exit 1 from the injected post-swap failure, got $rc"
    fi
    if [[ -e "$install_root" ]]; then
        fail "D: broken install tree was left behind with no previous install to restore"
    else
        pass "D: broken install tree was removed cleanly (nothing to restore)"
    fi
    if compgen -G "$parent/.wsl-bridge-install.*" > /dev/null 2>&1; then
        fail "D: a staging directory was left behind"
    else
        pass "D: no leftover staging directory"
    fi
    if compgen -G "$parent/wsl-bridge.previous.*" > /dev/null 2>&1; then
        fail "D: a rollback copy exists despite there being no previous install"
    else
        pass "D: no rollback copy exists (there was never a previous install)"
    fi
}

# ---------------------------------------------------------------------------
# Scenario E: failure BEFORE the swap (bad CPython version) with a previous
# install present -> must behave exactly like the pre-fix script: discard
# the staging attempt, leave the previous install completely untouched. This
# is the sub-case the swap_started guard placement (set right after the
# old-install-to-rollback move, before the stage-to-install_root move) is
# specifically for -- see the comment at that point in install-bridge-wsl.sh.
# ---------------------------------------------------------------------------
{
    parent="$(new_sandbox)"
    seed_bundle_sources "$parent"
    seed_previous_install "$parent"
    tarball="$parent/cpython-bad-version.tar.gz"
    build_fake_cpython_tarball "$tarball" "9.9.9"
    export FAKE_PYTHON_LOG="$parent/fake-python.log"
    unset FAKE_PYTHON_FAIL_AT || true

    run_scenario "$parent/stdout.log" "$parent/stderr.log" "$parent" "$tarball" \
        "$parent/CorrespondingSource/coolscanpy" "$parent/CorrespondingSource/scanstudio-bridge"
    rc="$SCENARIO_RC"

    install_root="$parent/wsl-bridge"
    if [[ "$rc" -eq 65 ]]; then
        pass "E: pre-swap version-check failure exits 65 (matches the shipped script's checksum/version exit code)"
    else
        fail "E: expected exit 65 from the pre-swap version mismatch, got $rc"
    fi
    if [[ -e "$install_root/OLD-MARKER" ]]; then
        pass "E: previous install at install_root is completely untouched by a pre-swap failure"
    else
        fail "E: previous install was disturbed by a failure that happened before the swap"
    fi
    if compgen -G "$parent/.wsl-bridge-install.*" > /dev/null 2>&1; then
        fail "E: a staging directory was left behind after a pre-swap failure"
    else
        pass "E: staging directory was cleaned up after the pre-swap failure"
    fi
    if compgen -G "$parent/wsl-bridge.previous.*" > /dev/null 2>&1; then
        fail "E: a rollback copy was created even though the swap never started"
    else
        pass "E: no rollback copy created (the swap never started)"
    fi
}

# Note on coverage: a failure landing exactly between the two `mv` calls in
# the swap (old-install-to-rollback succeeds, stage-to-install_root then
# fails) is reasoned correct by construction -- swap_started only flips to 1
# once install_root is already guaranteed empty -- but is not separately
# exercised here: reliably injecting a failure only in that one-`mv`-wide
# window needs shadowing `mv` itself, which was judged not worth the added
# harness fragility given C/D already prove the "both moves done" rollback
# path and E already proves the "neither move attempted" path.

echo
if [[ "$failures" -gt 0 ]]; then
    printf '%d check(s) FAILED\n' "$failures" >&2
    exit 1
fi
echo "ALL SCENARIOS PASSED"
