#!/usr/bin/env bash
#
# Install the GPL bridge lane inside WSL2 from the files shipped with the
# Windows ScanStudio bundle. Python and every Python package are bundle-owned:
# this script never uses the distro Python and never resolves a project or a
# dependency from a package index.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
FORCE=0
CPYTHON_ARCHIVE="cpython-3.13.14+20260728-x86_64-unknown-linux-gnu.tar.gz"
CPYTHON_SHA256="6734c3e643c75e860c36ee3a7904e8e6bafbf3232d89b17ffd5fbfa72ab2816c"

usage() {
    cat <<'USAGE'
usage: install-bridge-wsl.sh [--bundle-dir <bundle-root>] [--force]

Run this inside WSL2 Ubuntu-24.04. The bundle root is the directory containing
BridgeRuntime/, Wheelhouse/, CorrespondingSource/, and this script. When the
script is run from that directory, --bundle-dir is optional.
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
cleanup_stage() {
    if [[ -d "$stage_root" ]]; then
        rm -rf -- "$stage_root"
    fi
}
trap cleanup_stage EXIT

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
install_sources="$stage_root/sources"
mkdir -p "$install_sources/coolscanpy" "$install_sources/scanstudio-bridge"
cp -a "$coolscanpy_source/." "$install_sources/coolscanpy/"
cp -a "$bridge_source/." "$install_sources/scanstudio-bridge/"

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

rollback_root=""
if [[ -e "$install_root" ]]; then
    rollback_root="$install_parent/wsl-bridge.previous.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$install_root" "$rollback_root"
fi
mv "$stage_root" "$install_root"
stage_root=""

# `wsl.exe -e scanstudio-bridge` does not run a login shell, so relying on
# ~/.local/bin would be fragile. Install one tiny global wrapper whose target
# remains the per-user, bundle-owned runtime. The wrapper never arms motion.
wrapper_tmp="$(mktemp)"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' \
    "$install_root/python/bin/scanstudio-bridge" > "$wrapper_tmp"
chmod 755 "$wrapper_tmp"
"${SUDO[@]}" install -m 755 "$wrapper_tmp" /usr/local/bin/scanstudio-bridge
rm -f -- "$wrapper_tmp"

printf '\nInstallation complete.\n'
printf 'Python: %s\n' "$install_root/python/bin/python3.13"
printf 'Bridge: %s\n' /usr/local/bin/scanstudio-bridge
if [[ -n "$rollback_root" ]]; then
    printf 'Rollback copy: %s\n' "$rollback_root"
fi
printf '%s\n' 'Launch/import smoke check: scanstudio-bridge --version < /dev/null'
printf 'Next: read %s\n' "$BUNDLE_DIR/Documentation/WINDOWS-WSL-LANE.md"
