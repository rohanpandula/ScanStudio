#!/usr/bin/env bash
#
# Install the GPL bridge lane inside WSL2 from the files shipped with the
# Windows ScanStudio bundle. Python and every Python package are bundle-owned:
# this script never uses the distro Python and never resolves a project or a
# dependency from a package index.
#
# Run this as your normal user -- not as root and not via sudo. The script
# calls sudo itself, narrowly, for apt-get and for installing the
# /usr/local/bin wrapper; a root/sudo invocation would install the bridge
# under /root's home directory and strand that wrapper for every real user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
FORCE=0
CPYTHON_ARCHIVE="cpython-3.13.14+20260728-x86_64-unknown-linux-gnu.tar.gz"
CPYTHON_SHA256="6734c3e643c75e860c36ee3a7904e8e6bafbf3232d89b17ffd5fbfa72ab2816c"

usage() {
    cat <<'USAGE'
usage: install-bridge-wsl.sh [--bundle-dir <bundle-root>] [--force]

Run this inside WSL2 Ubuntu-24.04, as your normal user -- not as root and not
via sudo (the script calls sudo itself for the pieces that need it). The
bundle root is the directory containing BridgeRuntime/, Wheelhouse/,
CorrespondingSource/, and this script. When the script is run from that
directory, --bundle-dir is optional.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-dir)
            [[ $# -ge 2 ]] || { printf '%s\n' 'missing value for --bundle-dir' >&2; usage >&2; exit 64; }
            BUNDLE_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'error: do not run install-bridge-wsl.sh as root or via sudo.' >&2
    printf '%s\n' 'Run it as your normal user -- it calls sudo itself for apt-get and for' >&2
    printf '%s\n' 'installing the /usr/local/bin wrapper. A root/sudo run installs the' >&2
    printf '%s\n' 'bridge under /root and strands that wrapper for every other user.' >&2
    exit 77
fi

BUNDLE_DIR="$(cd "$BUNDLE_DIR" 2>/dev/null && pwd)" || {
    printf 'bundle directory does not exist: %s\n' "$BUNDLE_DIR" >&2
    exit 66
}

bridge_source="$BUNDLE_DIR/CorrespondingSource/scanstudio-bridge"
coolscanpy_source="$BUNDLE_DIR/CorrespondingSource/coolscanpy"
cpython_tarball="$BUNDLE_DIR/BridgeRuntime/$CPYTHON_ARCHIVE"
wheelhouse="$BUNDLE_DIR/Wheelhouse"
requirements="$BUNDLE_DIR/wsl-requirements.txt"

for required in \
    "$bridge_source/pyproject.toml" \
    "$coolscanpy_source/pyproject.toml" \
    "$cpython_tarball" \
    "$wheelhouse/SHA256SUMS" \
    "$requirements"; do
    if [[ ! -f "$required" ]]; then
        printf 'missing shipped bundle file: %s\n' "$required" >&2
        exit 66
    fi
done

command -v sha256sum >/dev/null 2>&1 || {
    printf '%s\n' 'sha256sum is required (provided by Ubuntu coreutils).' >&2
    exit 69
}

actual_cpython_sha="$(sha256sum "$cpython_tarball" | awk '{print $1}')"
if [[ "$actual_cpython_sha" != "$CPYTHON_SHA256" ]]; then
    printf 'bundled CPython checksum mismatch: expected %s, got %s\n' \
        "$CPYTHON_SHA256" "$actual_cpython_sha" >&2
    exit 65
fi
(cd "$wheelhouse" && sha256sum --check --strict SHA256SUMS)

# Only the C-library and compiler prerequisites come from Ubuntu. Python,
# python-sane, CoolscanPy, the bridge, and their Python dependencies remain
# isolated in the bundle-owned runtime below.
SUDO=()
if [[ "$(id -u)" -ne 0 ]]; then
    SUDO=(sudo)
fi
printf '%s\n' '=== Installing WSL system prerequisites (SANE / libusb / compiler) ==='
"${SUDO[@]}" apt-get update
DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y --no-install-recommends \
    sane-utils libsane1 libsane-dev libusb-1.0-0 build-essential pkg-config

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
install_parent="$data_home/scanstudio"
install_root="$install_parent/wsl-bridge"
mkdir -p "$install_parent"

if [[ -e "$install_root" && "$FORCE" -ne 1 ]]; then
    printf 'ScanStudio WSL bridge is already installed at %s.\n' "$install_root" >&2
    printf '%s\n' 'Re-run with --force to replace it after keeping a rollback copy.' >&2
    exit 73
fi

stage_root="$(mktemp -d "$install_parent/.wsl-bridge-install.XXXXXX")"
rollback_root=""
swap_started=0

# Restores $install_root to a known-good state after a failure that happened
# once the staging tree had already been swapped into place (swap_started=1
# below). $install_root is guaranteed to be either the broken new tree or
# nothing at all by the time this can run -- never the still-good old
# install -- because swap_started only flips to 1 after the old install (if
# any) has already been safely moved aside to $rollback_root. `set +e` is in
# effect for the whole cleanup/rollback trap (see cleanup_and_maybe_rollback),
# so one failing step here (e.g. a permissions problem on the restore mv)
# cannot skip the rest of the restore or swallow the original exit code.
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

cleanup_and_maybe_rollback() {
    local exit_code=$?
    # Disable errexit for the remainder of this handler. Without this, a
    # failing command inside the trap (e.g. an `rm -rf` that hits a
    # permission error) would abort the trap immediately under `set -e`,
    # skip the rest of the restore, and replace the real exit code with a
    # generic 1 -- verified empirically against this bash.
    set +e
    if [[ "$swap_started" -ne 1 ]]; then
        # Nothing has touched $install_root yet. Only the staging directory
        # needs cleaning up -- this mirrors the pre-fix behavior exactly.
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
python_bin="$stage_root/python/bin/python3.13"
if [[ ! -x "$python_bin" ]]; then
    printf '%s\n' 'bundled CPython archive did not contain python/bin/python3.13' >&2
    exit 65
fi
if [[ "$($python_bin -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')" != "3.13.14" ]]; then
    printf '%s\n' 'bundled Python version is not the pinned 3.13.14' >&2
    exit 65
fi

# pip/setuptools may create a local build/ directory even for a non-editable
# install. Copy the two immutable installer resources into the private staging
# root first, so installation also works when the Windows bundle is mounted or
# installed read-only from WSL's point of view.
mkdir -p "$stage_root/sources/coolscanpy" "$stage_root/sources/scanstudio-bridge"
cp -a "$coolscanpy_source/." "$stage_root/sources/coolscanpy/"
cp -a "$bridge_source/." "$stage_root/sources/scanstudio-bridge/"

# Swap the verified staging tree into $install_root *before* any pip install
# runs below. pip/distlib write every console-script entrypoint (including
# python/bin/scanstudio-bridge) with a `#!` shebang that embeds the exact
# interpreter path used to invoke pip -- literally, not resolved at run time.
# Running pip against the mktemp staging path and renaming the directory
# afterward (the old order) left every generated shebang pointing at a
# .wsl-bridge-install.XXXXXX path that no longer existed once this script's
# EXIT trap cleaned it up, so /usr/local/bin/scanstudio-bridge would exec a
# script whose own interpreter had vanished. Doing the swap first and running
# every pip install against $install_root/python/bin/python3.13 makes the
# shebangs correct by construction.
if [[ -e "$install_root" ]]; then
    rollback_root="$install_parent/wsl-bridge.previous.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$install_root" "$rollback_root"
fi
# From here on $install_root is guaranteed to be empty (either it never
# existed, or it was just moved to $rollback_root above), so any failure from
# this point forward -- including the mv immediately below failing outright --
# can safely be handled by reclaiming $install_root: it is never the
# still-good previous install by the time swap_started can be seen as 1.
swap_started=1
mv "$stage_root" "$install_root"
stage_root=""
install_sources="$install_root/sources"
python_bin="$install_root/python/bin/python3.13"

printf '%s\n' '=== Installing pinned dependencies from the offline wheelhouse ==='
CC=gcc CXX=g++ "$python_bin" -m pip install \
    --disable-pip-version-check --no-index --find-links "$wheelhouse" \
    --require-hashes --requirement "$requirements"

# Order matters. Install CoolscanPy first, then the bridge, and disable
# dependency resolution for both local projects. That prevents the bridge's
# `coolscanpy[scanner]` declaration from ever selecting a similarly named
# project from an index or from a stale user environment.
printf '%s\n' '=== Installing CoolscanPy from shipped corresponding source ==='
"$python_bin" -m pip install \
    --disable-pip-version-check --no-index --no-deps --no-build-isolation \
    "$install_sources/coolscanpy"

printf '%s\n' '=== Installing scanstudio-bridge from shipped corresponding source ==='
"$python_bin" -m pip install \
    --disable-pip-version-check --no-index --no-deps --no-build-isolation \
    "$install_sources/scanstudio-bridge"

"$python_bin" -I -c \
    'import coolscanpy, sane, scanstudio_bridge; print("bridge imports: OK")'

# Execute the same fail-closed capture preflight under the exact installed
# isolated interpreter/import path the worker uses.  Bind runtime metadata to
# both the shipped pyproject and the package provenance before publishing the
# wrapper or declaring installation complete.
"$python_bin" -I -B - \
    "$install_sources/coolscanpy/pyproject.toml" \
    "$BUNDLE_DIR/provenance.json" <<'PYTHON'
from importlib.metadata import version
import json
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
provenance_version = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))[
    "sources"
]["coolscanpy"]["version"]
if not (
    coolscanpy.__version__
    == version("coolscanpy")
    == project_version
    == provenance_version
):
    raise SystemExit("CoolscanPy runtime/package/provenance versions disagree")
if verify_capture_bundle(require_python_sources=True) != CAPTURE_BUNDLE_SHA256:
    raise SystemExit("CoolscanPy capture-bundle identity changed after installation")
print("capture worker package preflight: OK")
PYTHON

# `wsl.exe -e scanstudio-bridge` does not run a login shell, so relying on
# ~/.local/bin would be fragile. Install one tiny global wrapper whose target
# remains the per-user, bundle-owned runtime. The wrapper never arms motion.
wrapper_tmp="$(mktemp)"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' \
    "$install_root/python/bin/scanstudio-bridge" > "$wrapper_tmp"
chmod 755 "$wrapper_tmp"
"${SUDO[@]}" install -m 755 "$wrapper_tmp" /usr/local/bin/scanstudio-bridge
rm -f -- "$wrapper_tmp"

# Post-install verification: prove the shebang fix actually landed rather
# than trusting the reorder above by construction alone, and prove the
# installed entrypoint actually runs end to end.
printf '%s\n' '=== Verifying the installed bridge entrypoint ==='
bridge_entrypoint="$install_root/python/bin/scanstudio-bridge"
if [[ ! -f "$bridge_entrypoint" ]]; then
    printf 'post-install check failed: missing %s\n' "$bridge_entrypoint" >&2
    exit 70
fi
shebang_line="$(head -n 1 -- "$bridge_entrypoint")"
case "$shebang_line" in
    '#!'*)
        shebang_interpreter="${shebang_line#\#!}"
        # A `#!` line can carry a trailing argument (e.g. `#!/usr/bin/env
        # python3.13`); pip/distlib always emit a bare absolute path here,
        # but tokenize defensively rather than assume that.
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
if ! /usr/local/bin/scanstudio-bridge --version </dev/null; then
    printf 'post-install check failed: /usr/local/bin/scanstudio-bridge --version exited nonzero\n' >&2
    exit 70
fi

printf '\nInstallation complete.\n'
printf 'Python: %s\n' "$python_bin"
printf 'Bridge: %s\n' /usr/local/bin/scanstudio-bridge
if [[ -n "$rollback_root" ]]; then
    printf 'Rollback copy: %s\n' "$rollback_root"
fi
printf '%s\n' 'Launch/import smoke check: scanstudio-bridge --version < /dev/null'
printf 'Next: read %s\n' "$BUNDLE_DIR/Documentation/WINDOWS-WSL-LANE.md"
