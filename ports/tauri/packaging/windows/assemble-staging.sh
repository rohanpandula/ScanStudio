#!/usr/bin/env bash
set -euo pipefail

# Windows staging assembler: builds packaging/.staging/windows — the resource
# tree the NSIS installer bundles. The native app stays Python-free, while its
# WSL2 lane carries a pinned Linux CPython and an offline wheelhouse. The WSL
# installer never depends on Ubuntu's Python or on package-index resolution.
# This script replicates the macOS package_app.sh GPL/licensing guarantees on
# Windows: GPL corresponding source, complete Licenses/ tree, Rust crate
# notices, and provenance. Consumes the shared helper library from
# packaging/lib/common.sh.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
STAGING_ROOT="$repo_root/packaging/.staging/windows"

source "$repo_root/packaging/lib/common.sh"

# --- package-time configuration (defaults mirror package_app.sh:12-13) ---
SCANSTUDIO_BRIDGE_SOURCE="${SCANSTUDIO_BRIDGE_SOURCE:-$repo_root/vendor/scanstudio-bridge}"
COOLSCANPY_SOURCE="${COOLSCANPY_SOURCE:-$repo_root/vendor/coolscanpy}"
SCANSTUDIO_ENGINE_SOURCE="${SCANSTUDIO_ENGINE_SOURCE:-$repo_root/vendor/engine}"
SCANSTUDIO_APP_SOURCE="${SCANSTUDIO_APP_SOURCE:-$repo_root/app}"

CPYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260728/cpython-3.13.14%2B20260728-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
CPYTHON_SHA256="6734c3e643c75e860c36ee3a7904e8e6bafbf3232d89b17ffd5fbfa72ab2816c"
CPYTHON_ARCHIVE="cpython-3.13.14+20260728-x86_64-unknown-linux-gnu.tar.gz"

# Every package artifact is bound before use to a committed package/version,
# target ABI, exact filename, size, and SHA-256. python-sane has no CPython
# 3.13 wheel, so its reviewed sdist is compiled inside WSL against
# Ubuntu's libsane-dev.
PYTHON_ARTIFACT_LOCK="$repo_root/packaging/python-artifacts-linux-cp313-x86_64.lock.json"
PYTHON_ARTIFACT_SHA256="$repo_root/packaging/python-artifacts-linux-cp313-x86_64.sha256"
PYTHON_WHEEL_REQUIREMENTS="$repo_root/packaging/python-wheels-linux-cp313-x86_64.requirements.txt"
PYTHON_SANE_REQUIREMENTS="$repo_root/packaging/python-sane-linux-cp313-x86_64.requirements.txt"
PYTHON_ARTIFACT_VERIFIER="$repo_root/packaging/verify_python_artifact_lock.py"
PYTHON_SANE_URL="https://files.pythonhosted.org/packages/source/p/python-sane/python_sane-2.9.2.tar.gz"

# GPL corresponding source + license preconditions. The source trees are
# copied (never edited) from the port/cross-platform branches at build time.
require_directory "bridge source (SCANSTUDIO_BRIDGE_SOURCE)" "$SCANSTUDIO_BRIDGE_SOURCE"
require_directory "CoolscanPy source (COOLSCANPY_SOURCE)" "$COOLSCANPY_SOURCE"
require_file "bridge source LICENSE" "$SCANSTUDIO_BRIDGE_SOURCE/LICENSE"
require_file "CoolscanPy source LICENSE" "$COOLSCANPY_SOURCE/LICENSE"
require_file "frontend package lock" "$SCANSTUDIO_APP_SOURCE/package-lock.json"
require_file "Tauri app Cargo lock" "$SCANSTUDIO_APP_SOURCE/src-tauri/Cargo.lock"
require_file "Windows hardware-session PowerShell launcher" \
    "$script_dir/Start-ScanStudio-Hardware-Session.ps1"
require_file "Windows hardware-session double-click launcher" \
    "$script_dir/Start-ScanStudio-Hardware-Session.cmd"
require_file "Windows hardware-session WSL latch helper" \
    "$script_dir/scanstudio-hardware-session-latch.sh"
require_file "Windows hardware-session NSIS hooks" "$script_dir/installer-hooks.nsh"
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

# (2) GPL corresponding-source snapshots for both components.
mkdir -p "$STAGING_ROOT/CorrespondingSource"
copy_corresponding_source "$SCANSTUDIO_BRIDGE_SOURCE" "$STAGING_ROOT/CorrespondingSource/scanstudio-bridge"
copy_corresponding_source "$COOLSCANPY_SOURCE" "$STAGING_ROOT/CorrespondingSource/coolscanpy"

# (3) pinned relocatable CPython plus an offline, exact-version wheelhouse.
download_dir="$(mktemp -d)"
license_extract="$(mktemp -d)"
trap 'rm -rf "$download_dir" "$license_extract"' EXIT
mkdir -p "$STAGING_ROOT/BridgeRuntime" "$STAGING_ROOT/Wheelhouse"
cpython_tarball="$STAGING_ROOT/BridgeRuntime/$CPYTHON_ARCHIVE"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 600 --speed-limit 1024 --speed-time 60 \
    --max-filesize 268435456 --retry 3 --retry-delay 1 --retry-all-errors \
    --output "$cpython_tarball" "$CPYTHON_URL"
verify_sha256 "$CPYTHON_SHA256" "$cpython_tarball"
printf '%s  %s\n' "$CPYTHON_SHA256" "$CPYTHON_ARCHIVE" \
    > "$STAGING_ROOT/BridgeRuntime/SHA256SUMS"

wheelhouse="$STAGING_ROOT/Wheelhouse"
"$HOST_PYTHON" -I -B -m pip --isolated --disable-pip-version-check \
    --no-cache-dir download --require-hashes --no-deps --only-binary=:all: \
    --python-version 313 --implementation cp --abi cp313 \
    --platform manylinux_2_28_x86_64 --index-url https://pypi.org/simple \
    --dest "$wheelhouse" --requirement "$PYTHON_WHEEL_REQUIREMENTS"
python_sane_sdist="$wheelhouse/python_sane-2.9.2.tar.gz"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 180 --speed-limit 1024 --speed-time 30 \
    --max-filesize 1048576 --retry 3 --retry-delay 1 --retry-all-errors \
    --output "$python_sane_sdist" "$PYTHON_SANE_URL"

"$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
    --lock "$PYTHON_ARTIFACT_LOCK" \
    --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
    --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
    --sha256sums "$PYTHON_ARTIFACT_SHA256" \
    --directory "$wheelhouse"

# The runtime ledger is the reviewed committed ledger, not a build-generated
# description of whatever the package index happened to return. The combined
# requirements file remains usable by pip --require-hashes inside WSL.
install -m 644 "$PYTHON_ARTIFACT_SHA256" "$wheelhouse/SHA256SUMS"
{
    cat "$PYTHON_WHEEL_REQUIREMENTS"
    printf '\n'
    cat "$PYTHON_SANE_REQUIREMENTS"
} > "$STAGING_ROOT/wsl-requirements.txt"
"$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
    --lock "$PYTHON_ARTIFACT_LOCK" \
    --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
    --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
    --combined-requirements "$STAGING_ROOT/wsl-requirements.txt" \
    --sha256sums "$PYTHON_ARTIFACT_SHA256" \
    --directory "$wheelhouse" --allow-ledger

# (4) the WSL2-side bridge installer and user-facing setup material, shipped
# together so an extracted portable zip is self-explanatory offline.
install -m 755 "$script_dir/install-bridge-wsl.sh" "$STAGING_ROOT/install-bridge-wsl.sh"
install -m 644 "$script_dir/Start-ScanStudio-Hardware-Session.ps1" \
    "$STAGING_ROOT/Start-ScanStudio-Hardware-Session.ps1"
install -m 644 "$script_dir/Start-ScanStudio-Hardware-Session.cmd" \
    "$STAGING_ROOT/Start-ScanStudio-Hardware-Session.cmd"
install -m 755 "$script_dir/scanstudio-hardware-session-latch.sh" \
    "$STAGING_ROOT/scanstudio-hardware-session-latch.sh"
mkdir -p "$STAGING_ROOT/Documentation"
install -m 644 "$script_dir/README.md" "$STAGING_ROOT/Documentation/README-WINDOWS.md"
install -m 644 "$repo_root/runbooks/WINDOWS-WSL-LANE.md" \
    "$STAGING_ROOT/Documentation/WINDOWS-WSL-LANE.md"
install -m 644 "$repo_root/runbooks/WINDOWS-LIVE-VALIDATION.md" \
    "$STAGING_ROOT/Documentation/WINDOWS-LIVE-VALIDATION.md"

# (5) provenance: records package-time git HEAD SHAs of both GPL sources,
# version parsed from the exact source pyproject and lock.
write_provenance_json "$STAGING_ROOT/provenance.json" \
    scanstudio-bridge "$SCANSTUDIO_BRIDGE_SOURCE" "0.1.0" \
    coolscanpy "$COOLSCANPY_SOURCE" "$COOLSCANPY_VERSION"

# (6) license texts + README.
mkdir -p "$STAGING_ROOT/Licenses"
install -m 644 "$repo_root/LICENSE" "$STAGING_ROOT/Licenses/ScanStudio-MIT.txt"
install -m 644 "$SCANSTUDIO_BRIDGE_SOURCE/LICENSE" "$STAGING_ROOT/Licenses/scanstudio-bridge-GPL-3.0.txt"
install -m 644 "$COOLSCANPY_SOURCE/LICENSE" "$STAGING_ROOT/Licenses/CoolscanPy-GPL-3.0.txt"
tar -xOf "$cpython_tarball" python/lib/python3.13/LICENSE.txt \
    > "$STAGING_ROOT/Licenses/CPython-3.13.txt"

mkdir -p "$license_extract/site-packages"
"$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
    --lock "$PYTHON_ARTIFACT_LOCK" \
    --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
    --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
    --sha256sums "$PYTHON_ARTIFACT_SHA256" \
    --directory "$wheelhouse" --allow-ledger \
    --extract-wheels "$license_extract/site-packages" --wheel-role all
collect_python_wheel_licenses \
    "$license_extract/site-packages" "$STAGING_ROOT/Licenses/python-wheelhouse"
"$HOST_PYTHON" -I -B "$PYTHON_ARTIFACT_VERIFIER" \
    --lock "$PYTHON_ARTIFACT_LOCK" \
    --wheel-requirements "$PYTHON_WHEEL_REQUIREMENTS" \
    --sdist-requirements "$PYTHON_SANE_REQUIREMENTS" \
    --sha256sums "$PYTHON_ARTIFACT_SHA256" \
    --directory "$wheelhouse" --allow-ledger \
    --extract-sdist "$license_extract"
python_sane_source="$(find "$license_extract" -maxdepth 1 -type d -name 'python_sane-*' -print -quit)"
mkdir -p "$STAGING_ROOT/Licenses/python-wheelhouse/python_sane-2.9.2"
install -m 644 "$python_sane_source/COPYING" \
    "$STAGING_ROOT/Licenses/python-wheelhouse/python_sane-2.9.2/COPYING"
install -m 644 "$python_sane_source/PKG-INFO" \
    "$STAGING_ROOT/Licenses/python-wheelhouse/python_sane-2.9.2/PKG-INFO"
cat > "$STAGING_ROOT/Licenses/README.txt" <<'LICENSES'
ScanStudio contains mixed-license components.

ScanStudio's original code is MIT (ScanStudio-MIT.txt).
The hardware bridge and CoolscanPy are GPL-3.0-only. Their complete
corresponding source snapshots are in the CorrespondingSource/ directory next
to this one, with their GPL texts in this directory. The WSL lane carries a
sha256-pinned CPython 3.13.14 archive and a checksummed offline wheelhouse.
Their notices are under CPython-3.13.txt and python-wheelhouse/. CoolscanPy is
installed before scanstudio-bridge from the shipped source snapshots, with
dependency resolution disabled. Runtime frontend dependency notices are under
npm-production/. Full-text Rust dependency reports and their exact Cargo locks
are the Rust-App-* and Rust-Engine-* files. THIRD_PARTY_NOTICES.md explains the
boundary, and dependency-notices-manifest.json authenticates every notice.
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

# (9) developer-path hygiene (T-09-07 / manifest forbiddenPathSubstrings).
# The shipped tree must not disclose the builder's machine paths, so the
# staging copy of the GPL corresponding source is neutralized: every "/Users/"
# in a non-NUL text file is replaced with "/src" — the same remap convention
# the Linux assembler and package_app.sh use, and the same class of staged-
# copy rewrite their corresponding-source handling already performs.
"$HOST_PYTHON" - "$STAGING_ROOT/CorrespondingSource" <<'PYTHON'
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

# Re-run against the post-scrub assembled source bytes and generated
# provenance.  A one-byte change to any capture component fails packaging.
"$HOST_PYTHON" -I -B "$COOLSCANPY_IDENTITY_VERIFIER" \
    "$STAGING_ROOT/CorrespondingSource/coolscanpy" \
    --provenance "$STAGING_ROOT/provenance.json"

printf 'Windows staging assembled at %s\n' "$STAGING_ROOT"
