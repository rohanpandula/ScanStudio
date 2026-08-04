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

# Exact versions compatible with the shipped source declarations. Packages
# are downloaded at build time and installed with --no-index at user install
# time. python-sane ships as its source archive and is compiled inside WSL
# against Ubuntu's libsane-dev for CPython 3.13.
WSL_REQUIREMENTS=(
    "setuptools==83.0.0"
    "numpy==2.5.1"
    "tifffile==2026.7.31"
    "imagecodecs==2026.6.26"
    "opencv-python-headless==4.14.0.94"
    "pyusb==1.3.1"
    "jinja2==3.1.6"
    "MarkupSafe==3.0.3"
    "python-sane==2.9.2"
)

# GPL corresponding source + license preconditions. The source trees are
# copied (never edited) from the port/cross-platform branches at build time.
require_directory "bridge source (SCANSTUDIO_BRIDGE_SOURCE)" "$SCANSTUDIO_BRIDGE_SOURCE"
require_directory "CoolscanPy source (COOLSCANPY_SOURCE)" "$COOLSCANPY_SOURCE"
require_file "bridge source LICENSE" "$SCANSTUDIO_BRIDGE_SOURCE/LICENSE"
require_file "CoolscanPy source LICENSE" "$COOLSCANPY_SOURCE/LICENSE"
require_file "frontend package lock" "$SCANSTUDIO_APP_SOURCE/package-lock.json"
require_file "Tauri app Cargo lock" "$SCANSTUDIO_APP_SOURCE/src-tauri/Cargo.lock"

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
curl -fL --retry 3 -o "$cpython_tarball" "$CPYTHON_URL"
verify_sha256 "$CPYTHON_SHA256" "$cpython_tarball"
printf '%s  %s\n' "$CPYTHON_SHA256" "$CPYTHON_ARCHIVE" \
    > "$STAGING_ROOT/BridgeRuntime/SHA256SUMS"

wheelhouse="$STAGING_ROOT/Wheelhouse"
wheel_args=(download --no-deps --only-binary=:all: --python-version 313 \
    --implementation cp --abi cp313 --platform manylinux_2_28_x86_64 \
    --dest "$wheelhouse")
for requirement in "${WSL_REQUIREMENTS[@]:0:8}"; do
    "$HOST_PYTHON" -m pip "${wheel_args[@]}" "$requirement"
done
python_sane_sdist="$wheelhouse/python_sane-2.9.2.tar.gz"
curl -fL --retry 3 -o "$python_sane_sdist" \
    "https://files.pythonhosted.org/packages/source/p/python-sane/python_sane-2.9.2.tar.gz"
verify_sha256 \
    "50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe" \
    "$python_sane_sdist"

# A wheelhouse checksum ledger makes offline installation fail closed on any
# corruption after packaging. The requirements file also pins every identity
# and hash consumed by pip; no transitive or floating resolution remains.
"$HOST_PYTHON" - "$wheelhouse" "$STAGING_ROOT/wsl-requirements.txt" <<'PYTHON'
import hashlib
import re
import sys
from pathlib import Path

wheelhouse = Path(sys.argv[1])
requirements_path = Path(sys.argv[2])
artifacts = sorted(p for p in wheelhouse.iterdir() if p.is_file())

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

(wheelhouse / "SHA256SUMS").write_text(
    "".join(f"{digest(path)}  {path.name}\n" for path in artifacts)
)

pins = {
    "setuptools": "83.0.0",
    "numpy": "2.5.1",
    "tifffile": "2026.7.31",
    "imagecodecs": "2026.6.26",
    "opencv-python-headless": "4.14.0.94",
    "pyusb": "1.3.1",
    "jinja2": "3.1.6",
    "MarkupSafe": "3.0.3",
    "python-sane": "2.9.2",
}

def normalized(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()

lines = []
for name, version in pins.items():
    prefix = normalized(name).replace("-", "_")
    matches = [
        path for path in artifacts
        if normalized(path.name).startswith(normalized(prefix + "-" + version))
    ]
    if len(matches) != 1:
        raise SystemExit(f"expected one wheelhouse artifact for {name}=={version}, got {matches}")
    lines.append(f"{name}=={version} --hash=sha256:{digest(matches[0])}\n")
requirements_path.write_text("".join(lines))
PYTHON

# (4) the WSL2-side bridge installer and user-facing setup material, shipped
# together so an extracted portable zip is self-explanatory offline.
install -m 755 "$script_dir/install-bridge-wsl.sh" "$STAGING_ROOT/install-bridge-wsl.sh"
mkdir -p "$STAGING_ROOT/Documentation"
install -m 644 "$script_dir/README.md" "$STAGING_ROOT/Documentation/README-WINDOWS.md"
install -m 644 "$repo_root/runbooks/WINDOWS-WSL-LANE.md" \
    "$STAGING_ROOT/Documentation/WINDOWS-WSL-LANE.md"
install -m 644 "$repo_root/runbooks/WINDOWS-LIVE-VALIDATION.md" \
    "$STAGING_ROOT/Documentation/WINDOWS-LIVE-VALIDATION.md"

# (5) provenance: records package-time git HEAD SHAs of both GPL sources,
# version strings matching package_app.sh:180-185.
write_provenance_json "$STAGING_ROOT/provenance.json" \
    scanstudio-bridge "$SCANSTUDIO_BRIDGE_SOURCE" "0.1.0" \
    coolscanpy "$COOLSCANPY_SOURCE" "0.1.3"

# (6) license texts + README.
mkdir -p "$STAGING_ROOT/Licenses"
install -m 644 "$repo_root/LICENSE" "$STAGING_ROOT/Licenses/ScanStudio-MIT.txt"
install -m 644 "$SCANSTUDIO_BRIDGE_SOURCE/LICENSE" "$STAGING_ROOT/Licenses/scanstudio-bridge-GPL-3.0.txt"
install -m 644 "$COOLSCANPY_SOURCE/LICENSE" "$STAGING_ROOT/Licenses/CoolscanPy-GPL-3.0.txt"
tar -xOf "$cpython_tarball" python/lib/python3.13/LICENSE.txt \
    > "$STAGING_ROOT/Licenses/CPython-3.13.txt"

mkdir -p "$license_extract/site-packages"
while IFS= read -r -d '' wheel; do
    "$HOST_PYTHON" -m zipfile -e "$wheel" "$license_extract/site-packages"
done < <(find "$wheelhouse" -maxdepth 1 -type f -name '*.whl' -print0)
collect_python_wheel_licenses \
    "$license_extract/site-packages" "$STAGING_ROOT/Licenses/python-wheelhouse"
tar -xzf "$python_sane_sdist" -C "$license_extract"
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

printf 'Windows staging assembled at %s\n' "$STAGING_ROOT"
