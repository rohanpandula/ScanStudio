#!/usr/bin/env bash
set -euo pipefail

# Linux staging assembler: builds packaging/.staging/linux — the resource tree
# bundled into the Linux AppImage/tarball. Ports the macOS package_app.sh
# GPL/licensing guarantees: pinned relocatable CPython (sha256-verified before
# extraction), curated site-packages, GPL corresponding source, complete
# Licenses/ tree, Rust crate notices, and provenance. Consumes the shared
# helper library from packaging/lib/common.sh.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
STAGING_ROOT="$repo_root/packaging/.staging/linux"

source "$script_dir/../lib/common.sh"

# --- package-time configuration (defaults mirror package_app.sh:12-13) ---
SCANSTUDIO_BRIDGE_SOURCE="${SCANSTUDIO_BRIDGE_SOURCE:-$repo_root/vendor/scanstudio-bridge}"
COOLSCANPY_SOURCE="${COOLSCANPY_SOURCE:-$repo_root/vendor/coolscanpy}"
SCANSTUDIO_ENGINE_SOURCE="${SCANSTUDIO_ENGINE_SOURCE:-$repo_root/vendor/engine}"
SCANSTUDIO_APP_SOURCE="${SCANSTUDIO_APP_SOURCE:-$repo_root/app}"

# Pinned relocatable CPython runtime (STACK.md / plan Interfaces). The exact
# URL + sha256 are verified live against the GitHub Releases API before use;
# the sha256 is checked BEFORE any extraction.
CPYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260728/cpython-3.13.14%2B20260728-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
CPYTHON_SHA256="6734c3e643c75e860c36ee3a7904e8e6bafbf3232d89b17ffd5fbfa72ab2816c"

# Committed target-specific lock for every package artifact used below. The
# verifier binds package/version, target ABI, exact filename, byte size, and
# SHA-256 before any wheel is extracted or any sdist is built.
PYTHON_ARTIFACT_LOCK="$repo_root/packaging/python-artifacts-linux-cp313-x86_64.lock.json"
PYTHON_ARTIFACT_SHA256="$repo_root/packaging/python-artifacts-linux-cp313-x86_64.sha256"
PYTHON_WHEEL_REQUIREMENTS="$repo_root/packaging/python-wheels-linux-cp313-x86_64.requirements.txt"
PYTHON_SANE_REQUIREMENTS="$repo_root/packaging/python-sane-linux-cp313-x86_64.requirements.txt"
PYTHON_ARTIFACT_VERIFIER="$repo_root/packaging/verify_python_artifact_lock.py"
PYTHON_SANE_URL="https://files.pythonhosted.org/packages/source/p/python-sane/python_sane-2.9.2.tar.gz"

SITE_PACKAGES_DIR="$STAGING_ROOT/BridgeRuntime/site-packages"
PYTHON_BIN="$STAGING_ROOT/BridgeRuntime/python/bin/python3.13"

# GPL corresponding source + license preconditions. The source trees are
# copied (never edited) from the port/cross-platform branches at build time.
require_directory "bridge source (SCANSTUDIO_BRIDGE_SOURCE)" "$SCANSTUDIO_BRIDGE_SOURCE"
require_directory "CoolscanPy source (COOLSCANPY_SOURCE)" "$COOLSCANPY_SOURCE"
require_file "bridge source LICENSE" "$SCANSTUDIO_BRIDGE_SOURCE/LICENSE"
require_file "CoolscanPy source LICENSE" "$COOLSCANPY_SOURCE/LICENSE"
require_file "frontend package lock" "$SCANSTUDIO_APP_SOURCE/package-lock.json"
require_file "Tauri app Cargo lock" "$SCANSTUDIO_APP_SOURCE/src-tauri/Cargo.lock"
require_file "Python artifact lock" "$PYTHON_ARTIFACT_LOCK"
require_file "Python artifact checksum ledger" "$PYTHON_ARTIFACT_SHA256"
require_file "Python wheel requirements" "$PYTHON_WHEEL_REQUIREMENTS"
require_file "python-sane requirements" "$PYTHON_SANE_REQUIREMENTS"
require_file "Python artifact verifier" "$PYTHON_ARTIFACT_VERIFIER"

"$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
    --lock "$PYTHON_ARTIFACT_LOCK" \
    --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
    --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
    --sha256sums "$PYTHON_ARTIFACT_SHA256"

COOLSCANPY_IDENTITY_VERIFIER="$repo_root/../../scripts/verify_coolscanpy_source.py"
require_file "CoolscanPy package identity verifier" "$COOLSCANPY_IDENTITY_VERIFIER"
COOLSCANPY_VERSION="$(
    "$HOST_PYTHON" -I -B "$COOLSCANPY_IDENTITY_VERIFIER" \
        "$COOLSCANPY_SOURCE" --print-version
)"

# (1) fresh staging root.
rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT"

# (2) relocatable CPython: download, verify, extract.
download_dir="$(mktemp -d)"
extract_tmp="$(mktemp -d)"
trap 'rm -rf "$download_dir" "$extract_tmp"' EXIT
cpython_tarball="$download_dir/cpython.tar.gz"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 600 --speed-limit 1024 --speed-time 60 \
    --max-filesize 268435456 --retry 3 --retry-delay 1 --retry-all-errors \
    --output "$cpython_tarball" "$CPYTHON_URL"
verify_sha256 "$CPYTHON_SHA256" "$cpython_tarball"
tar -xzf "$cpython_tarball" -C "$extract_tmp"
mkdir -p "$STAGING_ROOT/BridgeRuntime"
mv "$extract_tmp/python" "$STAGING_ROOT/BridgeRuntime/python"
rmdir "$extract_tmp"
require_file "bundled CPython interpreter" "$PYTHON_BIN"

# The bundled python's `_tkinter` extension links libtcl9.0.so, which
# linuxdeploy cannot bundle during AppImage creation (Tcl 9 is not in Ubuntu
# 22.04's repos, so no apt package satisfies it). The bridge never uses Tk, so
# strip _tkinter and the Tcl/Tk runtime from the bundled Linux python so the
# AppImage bundle stays resolvable.
PYTHON_ROOT="$STAGING_ROOT/BridgeRuntime/python"
rm -f \
    "$PYTHON_ROOT"/lib/python3.13/lib-dynload/_tkinter*.so \
    "$PYTHON_ROOT"/lib/libtcl*.so* \
    "$PYTHON_ROOT"/lib/libtk*.so*
rm -rf "$PYTHON_ROOT"/lib/tcl*/ "$PYTHON_ROOT"/lib/tk*/

# (3) GPL corresponding source snapshots.
mkdir -p "$STAGING_ROOT/CorrespondingSource"
copy_corresponding_source "$SCANSTUDIO_BRIDGE_SOURCE" "$STAGING_ROOT/CorrespondingSource/scanstudio-bridge"
copy_corresponding_source "$COOLSCANPY_SOURCE" "$STAGING_ROOT/CorrespondingSource/coolscanpy"

# (4) curated site-packages. The seven runtime wheels are selected from one
# committed, hash-required target download and verified as an exact artifact
# set before the bounded no-link extractor writes anything into site-packages.
mkdir -p "$SITE_PACKAGES_DIR"
# The bundled CPython is a Linux-only binary and cannot execute on non-Linux
# hosts (the local macOS packaging gate). `pip download` with explicit
# --python-version/--abi/--platform is a pure network resolution and fetches
# the identical target wheels from any interpreter, so fall back to the host
# python3's pip on such hosts while keeping the bundled interpreter's pip
# authoritative on a real Linux build host.
pip_python="$PYTHON_BIN"
if [[ "$(uname -s)" != "Linux" ]] && ! "$PYTHON_BIN" -I -c 'import sys' >/dev/null 2>&1; then
    pip_python="$HOST_PYTHON"
fi
python_artifacts="$download_dir/python-artifacts"
mkdir -p "$python_artifacts"
"$pip_python" -I -B -m pip --isolated --disable-pip-version-check \
    --no-cache-dir download --require-hashes --no-deps --only-binary=:all: \
    --python-version 313 --implementation cp --abi cp313 \
    --platform manylinux_2_28_x86_64 --index-url https://pypi.org/simple \
    --dest "$python_artifacts" --requirement "$PYTHON_WHEEL_REQUIREMENTS"

sane_sdist="$python_artifacts/python_sane-2.9.2.tar.gz"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 180 --speed-limit 1024 --speed-time 30 \
    --max-filesize 1048576 --retry 3 --retry-delay 1 --retry-all-errors \
    --output "$sane_sdist" "$PYTHON_SANE_URL"

"$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
    --lock "$PYTHON_ARTIFACT_LOCK" \
    --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
    --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
    --sha256sums "$PYTHON_ARTIFACT_SHA256" \
    --directory "$python_artifacts" \
    --extract-wheels "$SITE_PACKAGES_DIR" --wheel-role runtime

# python-sane has no prebuilt wheel. A real Linux bundle must compile it for
# the bundled CPython 3.13 against the build host's libsane-dev. The exact
# source and build-backend wheel are hash-pinned before use. A non-Linux host
# may assemble a staging-only tree, but strict verification will reject it.
if [[ "$(uname -s)" == "Linux" ]]; then
    if [[ ! -f /usr/include/sane/sane.h ]]; then
        printf '%s\n' 'Linux bundle build requires libsane-dev (/usr/include/sane/sane.h is missing).' >&2
        exit 66
    fi

    sane_build="$download_dir/python-sane-build"
    build_tools="$download_dir/python-build-tools"
    mkdir -p "$sane_build" "$build_tools"

    "$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
        --lock "$PYTHON_ARTIFACT_LOCK" \
        --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
        --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
        --sha256sums "$PYTHON_ARTIFACT_SHA256" \
        --directory "$python_artifacts" \
        --extract-wheels "$build_tools" --wheel-role build

    CC=gcc CXX=g++ PYTHONPATH="$build_tools" "$PYTHON_BIN" -m pip wheel \
        --disable-pip-version-check --no-index --no-deps --no-build-isolation \
        --wheel-dir "$sane_build" "$sane_sdist"
    sane_wheel="$(find "$sane_build" -maxdepth 1 -type f -name 'python_sane-2.9.2-cp313-*.whl' -print -quit)"
    require_file "python-sane CPython 3.13 wheel" "$sane_wheel"
    python3 -m zipfile -e "$sane_wheel" "$SITE_PACKAGES_DIR"
    require_file "python-sane module" "$SITE_PACKAGES_DIR/sane.py"
    sane_extension="$(find "$SITE_PACKAGES_DIR" -maxdepth 1 -type f -name '_sane*.so' -print -quit)"
    require_file "python-sane native extension" "$sane_extension"
else
    printf '%s\n' 'skipping python-sane build on non-Linux staging host; strict Linux verification requires it'
fi

# (4b) Make the curated site-packages and the GPL coolscanpy source resolvable
# by the bundled interpreter's OWN default sys.path. The bridge process injects
# these two directories at runtime, but the capture worker is spawned as an
# isolated `python -I -B` child (protocol/ls5000_single_pass/capture_process.py)
# that inherits none of that injection -- so without this it dies with
# `ModuleNotFoundError: No module named 'coolscanpy'` (and would then miss numpy
# et al. too) and no real preview/scan can run. `-I` implies `-E -s -P` but not
# `-S`, so site.py still processes this .pth. Paths are derived from sys.prefix
# at startup because the AppImage mountpoint (/tmp/.mount_*) is only known then.
# coolscanpy is NOT copied here: it stays solely under CorrespondingSource so
# the GPL corresponding-source boundary is unchanged.
INTERP_SITE_PACKAGES="$STAGING_ROOT/BridgeRuntime/python/lib/python3.13/site-packages"
require_directory "bundled interpreter site-packages" "$INTERP_SITE_PACKAGES"
cat > "$INTERP_SITE_PACKAGES/scanstudio-bridge-runtime.pth" <<'PTH'
import os,sys; _br=os.path.dirname(sys.prefix); _p=[os.path.join(_br,'site-packages'),os.path.join(os.path.dirname(_br),'CorrespondingSource','coolscanpy','src')]; sys.path[:0]=[q for q in _p if os.path.isdir(q) and q not in sys.path]
PTH

# Source-based Linux packages still carry distribution metadata so runtime
# provenance, importlib.metadata, and the corresponding source all report the
# same version.  The value is parsed once from the shipped project metadata.
coolscanpy_dist_info="$SITE_PACKAGES_DIR/coolscanpy-$COOLSCANPY_VERSION.dist-info"
mkdir -p "$coolscanpy_dist_info"
printf 'Metadata-Version: 2.1\nName: coolscanpy\nVersion: %s\nLicense-Expression: GPL-3.0-only\n' \
    "$COOLSCANPY_VERSION" > "$coolscanpy_dist_info/METADATA"

# (5) per-wheel license collection.
collect_python_wheel_licenses "$SITE_PACKAGES_DIR" "$STAGING_ROOT/Licenses/python-wheels"

# (6) license texts + README (adapts package_app.sh:370-381's wording to
# Linux: mixed-license bundle, GPL corresponding source under
# CorrespondingSource/, no system SANE/libusb bundled).
mkdir -p "$STAGING_ROOT/Licenses"
install -m 644 "$repo_root/LICENSE" "$STAGING_ROOT/Licenses/ScanStudio-MIT.txt"
install -m 644 "$SCANSTUDIO_BRIDGE_SOURCE/LICENSE" "$STAGING_ROOT/Licenses/scanstudio-bridge-GPL-3.0.txt"
install -m 644 "$COOLSCANPY_SOURCE/LICENSE" "$STAGING_ROOT/Licenses/CoolscanPy-GPL-3.0.txt"
install -m 644 "$STAGING_ROOT/BridgeRuntime/python/lib/python3.13/LICENSE.txt" "$STAGING_ROOT/Licenses/CPython-3.13.txt"
cat > "$STAGING_ROOT/Licenses/README.txt" <<'LICENSES'
ScanStudio contains mixed-license components.

ScanStudio's original code is MIT (ScanStudio-MIT.txt).
The bundled hardware bridge and CoolscanPy are GPL-3.0-only. Their complete
corresponding source snapshots are in ../CorrespondingSource/scanstudio-bridge
and ../CorrespondingSource/coolscanpy, with their GPL texts in this directory.
CPython 3.13 and each included Python wheel's metadata/license material are
listed in python-wheels. The Linux build includes python-sane, but not the
system SANE/libusb libraries or scanner backend. Real hardware additionally
requires compatible system SANE/libusb packages. See packaging/linux/README.md
for prerequisites and bridge configuration. Runtime frontend dependency
notices are under npm-production/. Full-text Rust dependency reports and their
exact Cargo locks are the Rust-App-* and Rust-Engine-* files.
THIRD_PARTY_NOTICES.md explains the boundary, and
dependency-notices-manifest.json authenticates every notice.
LICENSES

# (7) Runtime frontend notices from the exact production npm closure.
(
    cd "$SCANSTUDIO_APP_SOURCE"
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund
)
collect_npm_runtime_licenses \
    "$SCANSTUDIO_APP_SOURCE/package-lock.json" \
    "$SCANSTUDIO_APP_SOURCE" \
    "$STAGING_ROOT/Licenses/npm-production"

# (8) Full-text Rust notices for both exact locked native graphs.
generate_rust_dependency_report \
    "$SCANSTUDIO_APP_SOURCE/src-tauri/Cargo.toml" \
    "$SCANSTUDIO_APP_SOURCE/src-tauri/Cargo.lock" \
    "$STAGING_ROOT/Licenses/Rust-App-THIRD-PARTY.txt" \
    "$STAGING_ROOT/Licenses/Rust-App-Cargo.lock" \
    "$repo_root/packaging/about.toml" \
    "$repo_root/packaging/about.hbs"
generate_rust_dependency_report \
    "$SCANSTUDIO_ENGINE_SOURCE/Cargo.toml" \
    "$SCANSTUDIO_ENGINE_SOURCE/Cargo.lock" \
    "$STAGING_ROOT/Licenses/Rust-Engine-THIRD-PARTY.txt" \
    "$STAGING_ROOT/Licenses/Rust-Engine-Cargo.lock" \
    "$repo_root/packaging/about.toml" \
    "$repo_root/packaging/about.hbs"
install -m 644 "$repo_root/THIRD_PARTY_NOTICES.md" \
    "$STAGING_ROOT/Licenses/THIRD_PARTY_NOTICES.md"
write_dependency_notices_manifest "$STAGING_ROOT/Licenses"

# (9) developer-path hygiene. The shipped tree must not disclose the builder's
# machine paths (CONTEXT decision 2 / manifest forbiddenPathSubstrings), so the
# staging copy is neutralized: every "/Users/" in a text file under the GPL
# corresponding source and the bundled CPython distribution is replaced with
# "/src" -- the same remap convention package_app.sh uses
# (--remap-path-prefix=$HOME=/src) and the same class of staged-copy rewrite
# its corresponding-source handling already performs. Only non-NUL text files
# are touched; the CPython download was sha256-verified against the pinned hash
# BEFORE this stage, so supply-chain integrity is unaffected.
python3 - "$STAGING_ROOT/CorrespondingSource" "$STAGING_ROOT/BridgeRuntime/python" <<'PYTHON'
import sys
from pathlib import Path

for root in sys.argv[1:]:
    for path in Path(root).rglob("*"):
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\x00" in data or b"/Users/" not in data:
            continue
        path.write_bytes(data.replace(b"/Users/", b"/src/"))
PYTHON

# (9b) provenance: records package-time git HEAD SHAs of both GPL sources.
write_provenance_json "$STAGING_ROOT/provenance.json" \
    scanstudio-bridge "$SCANSTUDIO_BRIDGE_SOURCE" "0.1.0" \
    coolscanpy "$COOLSCANPY_SOURCE" "$COOLSCANPY_VERSION"

# Verify the final assembled source, dist-info, and provenance together.
# This runs even on a non-Linux staging host and needs only the host stdlib.
"$HOST_PYTHON" -I -B "$COOLSCANPY_IDENTITY_VERIFIER" \
    "$STAGING_ROOT/CorrespondingSource/coolscanpy" \
    --provenance "$STAGING_ROOT/provenance.json" \
    --metadata-root "$SITE_PACKAGES_DIR"

# (10) launcher (Task 4's output; tolerated if this runs standalone first).
launcher_src="$script_dir/launcher/scanstudio-launcher.sh"
if [[ -f "$launcher_src" ]]; then
    install -m 755 "$launcher_src" "$STAGING_ROOT/scanstudio-launcher.sh"
else
    printf 'warning: %s not found yet; skipping launcher copy (Task 4 must produce it)\n' "$launcher_src" >&2
fi

# (11) bundled bridge executable — the Linux port of the macOS
# packaging/ScanStudioBridge. This is what the launcher's "bundled" resolution
# step (step 3 of the four-step order) finds as a sibling.
cat > "$STAGING_ROOT/scanstudio-bridge" <<'BRIDGE'
#!/usr/bin/env bash
# The bundled GPL hardware bridge. Keep this a transparent launcher rather
# than a one-file freezer: support and license inspection can use the shipped
# CPython runtime, site-packages and corresponding-source directories directly.
set -euo pipefail

helper_dir="$(cd "$(dirname "$0")" && pwd)"
python="$helper_dir/BridgeRuntime/python/bin/python3.13"
bridge_source="$helper_dir/CorrespondingSource/scanstudio-bridge/src"
coolscanpy_source="$helper_dir/CorrespondingSource/coolscanpy/src"
site_packages="$helper_dir/BridgeRuntime/site-packages"

if [[ ! -x "$python" ]]; then
    printf 'ScanStudio: bundled bridge runtime is incomplete (missing Python 3.13).\n' >&2
    exit 78
fi
if [[ ! -d "$bridge_source" || ! -d "$coolscanpy_source" || ! -d "$site_packages" ]]; then
    printf 'ScanStudio: bundled bridge source or dependencies are incomplete.\n' >&2
    exit 78
fi

# Never import a user-installed bridge or user site packages by accident. -I
# ignores PYTHONHOME/PYTHONPATH, user site packages, and the current working
# directory; the sealed bootstrap adds only the three bundle-owned locations.
# Do not set SCANSTUDIO_HW_MOTION and do not create/touch the armed latch here;
# SAFE-02 remains wholly inside the bridge for motion-capable operations.
bootstrap='import runpy, sys; paths = sys.argv[1:4]; sys.path[:0] = paths; sys.argv = ["scanstudio-bridge", *sys.argv[4:]]; runpy.run_module("scanstudio_bridge.cli", run_name="__main__")'
exec "$python" -I -B -c "$bootstrap" "$bridge_source" "$coolscanpy_source" "$site_packages" "$@"
BRIDGE
chmod 755 "$STAGING_ROOT/scanstudio-bridge"

printf 'Linux staging assembled at %s\n' "$STAGING_ROOT"
