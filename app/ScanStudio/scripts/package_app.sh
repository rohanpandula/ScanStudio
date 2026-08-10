#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
output="${1:-$package_root/.build/ScanStudio.app}"

# These inputs are deliberately package-time configuration, never paths baked
# into scanstudio-bridge metadata. The defaults use the bridge and CoolscanPy
# sources shipped in this repository; release automation may still override
# either path and pin its revisions in the release record.
bridge_source="${SCANSTUDIO_BRIDGE_SOURCE:-$package_root/../../bridge}"
coolscanpy_source="${COOLSCANPY_SOURCE:-$package_root/../../coolscanpy}"
# Use the bridge venv's base interpreter by default. Its uv-managed CPython
# links libpython through @executable_path, unlike the machine's Homebrew
# Framework Python, whose absolute Cellar linkage cannot be relocated.
bridge_python="${SCANSTUDIO_BRIDGE_PYTHON:-$bridge_source/.venv/bin/python}"
bridge_site_packages="${SCANSTUDIO_BRIDGE_SITE_PACKAGES:-$bridge_source/.venv/lib/python3.13/site-packages}"

require_directory() {
    local label="$1"
    local path="$2"
    if [[ ! -d "$path" ]]; then
        print -u2 "ScanStudio package prerequisite missing: $label directory '$path'. Set the documented package-time override."
        exit 66
    fi
}

# GPL corresponding source must be useful, but should never be a raw checkout:
# local agent settings, worktrees, caches, logs and plans are not build input
# and may contain private machine paths. This allowlist covers package code,
# tests, build metadata, lockfiles and the project scripts needed to inspect
# or rebuild the shipped GPL components.
copy_corresponding_source() {
    local source="$1"
    local destination="$2"
    mkdir -p "$destination"
    local directory
    for directory in src tests scripts tools; do
        [[ -d "$source/$directory" ]] || continue
        rsync -a --delete --exclude '__pycache__/' --exclude '*.egg-info/' \
            "$source/$directory/" "$destination/$directory/"
    done
    local file
    for file in pyproject.toml uv.lock README.md CHANGELOG.md LICENSE COPYING; do
        [[ -f "$source/$file" ]] || continue
        install -m 644 "$source/$file" "$destination/$file"
    done
}

copy_python_runtime_dependencies() {
    setopt local_options null_glob
    local source="$1"
    local destination="$2"
    mkdir -p "$destination"
    local entry
    # Deliberately production-only: do not ship pytest, ruff, editable .pth
    # files, or a developer venv. Native companion directories are included
    # where their wheel uses them at runtime.
    for entry in numpy numpy.libs tifffile imagecodecs imagecodecs.libs cv2 \
        usb jinja2 markupsafe sane.py '_sane*.so'; do
        for candidate in "$source"/$~entry; do
            [[ -e "$candidate" ]] || continue
            rsync -a --exclude '__pycache__/' "$candidate" "$destination/"
        done
    done
    local dist_glob
    for dist_glob in 'numpy-*.dist-info' 'tifffile-*.dist-info' 'imagecodecs-*.dist-info' \
        'opencv_python_headless-*.dist-info' 'pyusb-*.dist-info' 'jinja2-*.dist-info' \
        'markupsafe-*.dist-info' 'python_sane-*.dist-info'; do
        for candidate in "$source"/$~dist_glob; do
            [[ -d "$candidate" ]] || continue
            rsync -a "$candidate" "$destination/"
        done
    done
}

require_directory "bridge source (SCANSTUDIO_BRIDGE_SOURCE)" "$bridge_source"
require_directory "CoolscanPy source (COOLSCANPY_SOURCE)" "$coolscanpy_source"
require_directory "bridge site-packages (SCANSTUDIO_BRIDGE_SITE_PACKAGES)" "$bridge_site_packages"
if [[ ! -x "$bridge_python" ]]; then
    print -u2 "ScanStudio package prerequisite missing: Python 3.13 ('$bridge_python'). Set SCANSTUDIO_BRIDGE_PYTHON to an installed Python 3.13 interpreter."
    exit 127
fi
if [[ ! -f "$bridge_source/LICENSE" || ! -f "$coolscanpy_source/LICENSE" ]]; then
    print -u2 "Refusing to package bridge without its GPL source license and CoolscanPy's GPL source license."
    exit 66
fi
if [[ ! -f "$bridge_site_packages/sane.py" ]] \
    || ! find "$bridge_site_packages" -maxdepth 1 -type d -name 'python_sane-*.dist-info' -print -quit | grep -q .; then
    print -u2 "Refusing to package the optional plain-scan/eject compatibility binding without python-sane. Install the scanner extra into SCANSTUDIO_BRIDGE_SITE_PACKAGES."
    exit 66
fi

bridge_runtime_prefix="$($bridge_python -c 'import sys; print(sys.base_prefix)')"
if [[ ! -x "$bridge_runtime_prefix/bin/python3.13" ]]; then
    print -u2 "Refusing to package a non-relocatable Python runtime: expected '$bridge_runtime_prefix/bin/python3.13'."
    exit 66
fi
if otool -L "$bridge_runtime_prefix/bin/python3.13" | tail -n +2 | grep -qE '/(opt/homebrew|usr/local|Users)/'; then
    print -u2 "Refusing to package Python runtime with machine-absolute linkage. Supply a relocatable CPython 3.13 runtime through SCANSTUDIO_BRIDGE_PYTHON."
    exit 66
fi

if [[ "${output:t}" != "ScanStudio.app" ]]; then
    print -u2 "Refusing to replace an output not named ScanStudio.app: $output"
    exit 64
fi

mkdir -p "${output:h}"
output="${output:A}"
# Stage beside the destination so the final move is a same-volume atomic
# rename rather than a potentially interruptible cross-volume copy.
staging_root="$(mktemp -d "${output:h}/.scanstudio-package.XXXXXX")"
staged_app="$staging_root/ScanStudio.app"
previous_app="$staging_root/previous-ScanStudio.app"
installed=0
replacement_started=0

cleanup() {
    if (( installed == 0 && replacement_started == 1 )); then
        # A post-swap verification failure still leaves an app at `output`.
        # Move it away first, then restore the previous known-good bundle.
        if [[ -e "$output" ]]; then
            mv "$output" "$staging_root/failed-ScanStudio.app"
        fi
        if [[ -d "$previous_app" ]]; then
            mv "$previous_app" "$output"
        fi
    fi
    rm -rf "$staging_root"
}
trap cleanup EXIT

# Build libusb from a hash-pinned upstream archive at the app's declared
# deployment target. Copying the builder's Homebrew dylib is not acceptable:
# its minimum macOS can be newer than this app's macOS 14 contract.
bundled_libusb_build="$staging_root/bundled-libusb"
"$script_dir/build_bundled_libusb.sh" "$bundled_libusb_build"

# Remap developer paths before compiling the distributable binaries. This is
# both privacy hygiene and a reproducibility aid: the shipped bundle must not
# disclose the builder's home directory through panic/file-location strings.
package_home="${HOME:-}"
if [[ -z "$package_home" || "$package_home" != /* ]]; then
    print -u2 "Refusing to package without an absolute HOME for compiler path remapping."
    exit 66
fi
(
    cd "$package_root/engine"
    RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$package_home=/src" cargo build --release
)
(
    cd "$package_root"
    swift build -c release \
        -Xswiftc -file-prefix-map -Xswiftc "$package_home=/src" \
        -Xswiftc -debug-prefix-map -Xswiftc "$package_home=/src"
)

mkdir -p "$staged_app/Contents/MacOS" \
    "$staged_app/Contents/Frameworks/coolscanpy/_native" \
    "$staged_app/Contents/Resources"
install -m 755 "$package_root/.build/release/ScanStudio" "$staged_app/Contents/MacOS/ScanStudio"
install -m 755 "$package_root/engine/target/release/scanstudio-engine" "$staged_app/Contents/MacOS/scanstudio-engine"
install -m 755 "$package_root/packaging/ScanStudioLauncher" "$staged_app/Contents/MacOS/ScanStudioLauncher"
install -m 755 "$package_root/packaging/ScanStudioBridge" "$staged_app/Contents/MacOS/scanstudio-bridge"
install -m 644 "$package_root/packaging/Info.plist" "$staged_app/Contents/Info.plist"

# Stamp the exact release version from the build environment, so the running
# app can report "I am 0.3.0-alpha.N". Best-effort: dev builds without
# SCANSTUDIO_RELEASE_VERSION keep the empty default.
if [[ -n "${SCANSTUDIO_RELEASE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :ScanStudioRelease '$SCANSTUDIO_RELEASE_VERSION'" \
        "$staged_app/Contents/Info.plist" \
        || { print -u2 "Failed to stamp ScanStudioRelease=$SCANSTUDIO_RELEASE_VERSION"; exit 1; }
fi

# Optional-runtime releases stamp only the raw Ed25519 trust anchor and the
# Developer ID TeamIdentifier. The runtime and PEM remain separate release
# material and are explicitly forbidden from this app below.
"$script_dir/stamp_web_runtime_trust.sh" "$staged_app/Contents/Info.plist"

bundled_libusb="$staged_app/Contents/Frameworks/coolscanpy/_native/libusb-1.0.dylib"
install -m 755 "$bundled_libusb_build/libusb-1.0.dylib" "$bundled_libusb"
app_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$staged_app/Contents/Info.plist")"
libusb_minimum="$(vtool -show-build "$bundled_libusb" | awk '$1 == "minos" { print $2; exit }')"
if [[ -z "$libusb_minimum" || "$libusb_minimum" != "$app_minimum" ]]; then
    print -u2 "Refusing bundled libusb with minimum macOS '$libusb_minimum'; the app declares '$app_minimum'."
    exit 1
fi
app_architectures="$(lipo -archs "$staged_app/Contents/MacOS/ScanStudio")"
libusb_architectures="$(lipo -archs "$bundled_libusb")"
if [[ "$libusb_architectures" != "$app_architectures" ]]; then
    print -u2 "Refusing bundled libusb architecture '$libusb_architectures'; the app is '$app_architectures'."
    exit 1
fi
if otool -L "$bundled_libusb" | tail -n +3 | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    print -u2 "Refusing bundled libusb with a non-system transitive dependency."
    otool -L "$bundled_libusb" >&2
    exit 1
fi

for resource in AppIcon-1024.png AppIcon.icns; do
    install -m 644 \
        "$package_root/Sources/ScanStudio/Resources/$resource" \
        "$staged_app/Contents/Resources/$resource"
done

# Bundle a transparent CPython runtime and the verified bridge dependency
# tree. The helper's PYTHONPATH points only at these shipped locations; it
# never follows development editable-path files or the user's site packages.
mkdir -p "$staged_app/Contents/Resources/BridgeRuntime" \
    "$staged_app/Contents/Resources/CorrespondingSource" \
    "$staged_app/Contents/Resources/Licenses/python-wheels"
rsync -a --delete --exclude '__pycache__/' --exclude '*.pyc' \
    "$bridge_runtime_prefix/" "$staged_app/Contents/Resources/BridgeRuntime/python/"
copy_python_runtime_dependencies "$bridge_site_packages" "$staged_app/Contents/Resources/BridgeRuntime/site-packages"
# The GPL source is intentionally imported from CorrespondingSource rather
# than an editable wheel. Retain just the neutral distribution metadata that
# the bridge uses to report its own version; it contains no local checkout
# path or maintainer email.
mkdir -p "$staged_app/Contents/Resources/BridgeRuntime/site-packages/scanstudio_bridge-0.1.0.dist-info"
print -r -- $'Metadata-Version: 2.1\nName: scanstudio-bridge\nVersion: 0.1.0\nLicense-Expression: GPL-3.0-only\n' \
    > "$staged_app/Contents/Resources/BridgeRuntime/site-packages/scanstudio_bridge-0.1.0.dist-info/METADATA"
mkdir -p "$staged_app/Contents/Resources/BridgeRuntime/site-packages/coolscanpy-0.1.3.dist-info"
print -r -- $'Metadata-Version: 2.1\nName: coolscanpy\nVersion: 0.1.3\nLicense-Expression: GPL-3.0-only\n' \
    > "$staged_app/Contents/Resources/BridgeRuntime/site-packages/coolscanpy-0.1.3.dist-info/METADATA"
copy_corresponding_source "$bridge_source" "$staged_app/Contents/Resources/CorrespondingSource/scanstudio-bridge"
copy_corresponding_source "$coolscanpy_source" "$staged_app/Contents/Resources/CorrespondingSource/coolscanpy"
# The capture adapter deliberately launches its scanner worker under
# `python -I` through a stdlib-only bootstrap.  `-I` correctly rejects a user's
# `PYTHONPATH` and working directory, but it also means the bridge helper's
# in-process `sys.path` bootstrap is not inherited by that child.  Install
# only relocation-safe, bundle-relative paths in CPython's *global*
# site-packages directory so isolated workers can resolve the exact shipped
# CoolscanPy source plus its curated runtime dependencies.  These are plain
# path lines (not executable .pth imports), and are resolved relative to the
# packaged interpreter, never to the launch CWD or an external installation.
runtime_global_site_packages="$staged_app/Contents/Resources/BridgeRuntime/python/lib/python3.13/site-packages"
mkdir -p "$runtime_global_site_packages"
print -r -- $'../../../../site-packages\n../../../../../CorrespondingSource/coolscanpy/src' \
    > "$runtime_global_site_packages/scanstudio-bundled-worker-paths.pth"
# Make the copied bridge source independently resolvable beside its copied
# CoolscanPy source. The source worktree deliberately has no machine-bound
# path in pyproject.toml; this package-local source map is the portable build
# relationship for recipients of the GPL corresponding-source directory.
staged_bridge_source="$staged_app/Contents/Resources/CorrespondingSource/scanstudio-bridge"
"$bridge_python" - "$staged_bridge_source/pyproject.toml" "$staged_bridge_source/uv.lock" <<'PYTHON'
from pathlib import Path
import sys

expected = "../coolscanpy"
for argument in sys.argv[1:]:
    path = Path(argument)
    contents = path.read_text()
    if expected not in contents:
        raise SystemExit(f"{path.name} did not contain the expected checkout-relative CoolscanPy source relation")
PYTHON
if ! command -v uv >/dev/null 2>&1; then
    print -u2 "Refusing to package GPL corresponding source without uv: it is required to generate the portable sibling-source lockfile."
    exit 127
fi
(cd "$staged_bridge_source" && uv lock --offline)
install_name_tool -id '@rpath/libpython3.13.dylib' \
    "$staged_app/Contents/Resources/BridgeRuntime/python/lib/libpython3.13.dylib"
# uv's generated sysconfig table records its build cache prefix. It is not a
# runtime search path, but leaving it would leak a private machine path into a
# public bundle. Replace it with an intentionally non-filesystem placeholder;
# CPython derives the real prefix from its relocated executable.
runtime_sysconfig="$staged_app/Contents/Resources/BridgeRuntime/python/lib/python3.13/_sysconfigdata__darwin_darwin.py"
"$bridge_python" - "$runtime_sysconfig" "$bridge_runtime_prefix" <<'PYTHON'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
build_prefix = sys.argv[2]
contents = config_path.read_text()
if build_prefix not in contents:
    raise SystemExit("packaged CPython sysconfig table did not contain its expected build prefix")
config_path.write_text(contents.replace(build_prefix, "/__SCANSTUDIO_BUNDLED_PYTHON__"))
PYTHON
"$staged_app/Contents/Resources/BridgeRuntime/python/bin/python3.13" -c 'import sysconfig; assert sysconfig.get_config_var("VERSION") == "3.13"'
# The import above validates the scrubbed table but can recreate bytecode with
# the build machine's filename metadata. Remove that generated bytecode before
# signing; CPython can regenerate ordinary caches after installation.
find "$staged_app/Contents/Resources/BridgeRuntime/python" -type f -name '*.pyc' -delete
find "$staged_app/Contents/Resources/BridgeRuntime/python" -type d -name '__pycache__' -empty -delete

# Licenses are intentionally visible outside the Python tree. Wheel metadata
# and any shipped LICENSE/COPYING files are retained alongside a manifest so a
# recipient can identify the exact included components without reverse
# engineering the app bundle.
install -m 644 "$package_root/../../LICENSE" "$staged_app/Contents/Resources/Licenses/ScanStudio-MIT.txt"
install -m 644 "$bridge_source/LICENSE" "$staged_app/Contents/Resources/Licenses/scanstudio-bridge-GPL-3.0.txt"
install -m 644 "$coolscanpy_source/LICENSE" "$staged_app/Contents/Resources/Licenses/CoolscanPy-GPL-3.0.txt"
install -m 644 "$bundled_libusb_build/COPYING" "$staged_app/Contents/Resources/Licenses/libusb-LGPL-2.1-or-later.txt"
install -m 644 "$bridge_runtime_prefix/lib/python3.13/LICENSE.txt" "$staged_app/Contents/Resources/Licenses/CPython-3.13.txt"
install -m 644 "$package_root/../../THIRD_PARTY_NOTICES.md" "$staged_app/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
install -m 644 "$package_root/engine/Cargo.lock" "$staged_app/Contents/Resources/Licenses/Rust-Cargo.lock"
mkdir -p "$staged_app/Contents/Resources/CorrespondingSource/libusb"
install -m 644 \
    "$bundled_libusb_build/libusb-1.0.30.tar.bz2" \
    "$staged_app/Contents/Resources/CorrespondingSource/libusb/libusb-1.0.30.tar.bz2"
install -m 755 \
    "$script_dir/build_bundled_libusb.sh" \
    "$staged_app/Contents/Resources/CorrespondingSource/libusb/build_bundled_libusb.sh"
print -r -- $'Rebuild the bundled libusb library on macOS with Apple command-line developer tools:\n\n  SCANSTUDIO_LIBUSB_DEPLOYMENT_TARGET=14.0 \\\n  SCANSTUDIO_LIBUSB_SOURCE_ARCHIVE="$PWD/libusb-1.0.30.tar.bz2" \\\n  ./build_bundled_libusb.sh "$PWD/rebuilt"\n\nThe script verifies the pinned source SHA-256, builds only the shared library with a fixed install prefix, fixes its app-relative install identity, and rejects non-system dependencies or a mismatched deployment target/architecture. The output is rebuilt/libusb-1.0.dylib.\n' \
    > "$staged_app/Contents/Resources/CorrespondingSource/libusb/REBUILD.txt"
print -r -- $'libusb 1.0.30\nLicense: LGPL-2.1-or-later\nSource: https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2\nSource SHA-256: fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf\nBundled library: Contents/Frameworks/coolscanpy/_native/libusb-1.0.dylib\nThe complete pinned source archive, exact build script, and rebuild instructions are under Contents/Resources/CorrespondingSource/libusb.\n' \
    > "$staged_app/Contents/Resources/Licenses/libusb-NOTICE.txt"
for dist_info in "$staged_app/Contents/Resources/BridgeRuntime/site-packages"/*.dist-info; do
    [[ -d "$dist_info" ]] || continue
    dist_name="${dist_info:t}"
    mkdir -p "$staged_app/Contents/Resources/Licenses/python-wheels/$dist_name"
    [[ -f "$dist_info/METADATA" ]] && install -m 644 "$dist_info/METADATA" "$staged_app/Contents/Resources/Licenses/python-wheels/$dist_name/METADATA"
    while IFS= read -r -d '' notice_file; do
        install -m 644 "$notice_file" "$staged_app/Contents/Resources/Licenses/python-wheels/$dist_name/${notice_file:t}"
    done < <(find "$dist_info" -maxdepth 1 -type f \
        \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0)
    [[ -d "$dist_info/licenses" ]] && rsync -a "$dist_info/licenses/" "$staged_app/Contents/Resources/Licenses/python-wheels/$dist_name/licenses/"
done
# imagecodecs ships its third-party notices inside the import package rather
# than its dist-info directory. Surface that corpus beside the wheel metadata
# so recipients do not need to inspect executable dependency directories.
imagecodecs_dist="$(find "$staged_app/Contents/Resources/BridgeRuntime/site-packages" -maxdepth 1 -type d -name 'imagecodecs-*.dist-info' -print -quit)"
if [[ -n "$imagecodecs_dist" && -d "$staged_app/Contents/Resources/BridgeRuntime/site-packages/imagecodecs/licenses" ]]; then
    rsync -a "$staged_app/Contents/Resources/BridgeRuntime/site-packages/imagecodecs/licenses/" \
        "$staged_app/Contents/Resources/Licenses/python-wheels/${imagecodecs_dist:t}/runtime-licenses/"
fi
# Keep full license/notice material for every Rust crate in the exact locked
# engine graph. Cargo's registry source manifests are copied too, preserving
# each package's declared SPDX/license context without silently choosing a
# license alternative on the distributor's behalf.
#
# The lockfile is a union over every target, so crates locked only for
# foreign platforms (wasm-only dependencies and the like) are never
# extracted into registry/src by a host build. `cargo fetch --locked`
# guarantees every locked crate's archive is at least present in
# registry/cache, and the collector below falls back to reading notices
# straight out of that archive when no extracted source exists. Both paths
# still fail closed when license material cannot be found.
cargo fetch --locked --manifest-path "$package_root/engine/Cargo.toml"
mkdir -p "$staged_app/Contents/Resources/Licenses/rust-crates"
"$bridge_python" - "$package_root/engine/Cargo.lock" \
    "${CARGO_HOME:-$HOME/.cargo}/registry" \
    "$staged_app/Contents/Resources/Licenses/rust-crates" <<'PYTHON'
from __future__ import annotations

import glob
from pathlib import Path
import shutil
import sys
import tarfile
import tomllib

lock_path, registry_root, destination = map(Path, sys.argv[1:])
packages = tomllib.loads(lock_path.read_text()).get("package", [])


def is_notice_name(name: str) -> bool:
    return name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "AUTHORS"))


def copy_from_source_dir(source: Path, target: Path) -> int:
    manifest = source / "Cargo.toml"
    if manifest.exists():
        shutil.copy2(manifest, target / "Cargo.toml")
    notices = [
        candidate for candidate in source.iterdir()
        if candidate.is_file() and is_notice_name(candidate.name)
    ]
    for notice in notices:
        shutil.copy2(notice, target / notice.name)
    return len(notices)


def copy_from_crate_archive(archive: Path, prefix: str, target: Path) -> int:
    copied = 0
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            parts = member.name.split("/")
            # Crate archives contain exactly one top-level directory,
            # "<name>-<version>/"; only its top-level files are of interest.
            if len(parts) != 2 or parts[0] != prefix:
                continue
            filename = parts[1]
            if filename != "Cargo.toml" and not is_notice_name(filename):
                continue
            extracted = tar.extractfile(member)
            if extracted is None:
                continue
            (target / filename).write_bytes(extracted.read())
            if filename != "Cargo.toml":
                copied += 1
    return copied


for package in packages:
    name = package["name"]
    version = package["version"]
    if name == "scanstudio-engine":
        continue
    prefix = f"{name}-{version}"
    target = destination / prefix
    target.mkdir(parents=True, exist_ok=True)

    src_matches = glob.glob(str(registry_root / "src" / "*" / prefix))
    if len(src_matches) > 1:
        raise SystemExit(f"ambiguous Cargo registry source for {name} {version}")
    if len(src_matches) == 1:
        notice_count = copy_from_source_dir(Path(src_matches[0]), target)
    else:
        cache_matches = glob.glob(str(registry_root / "cache" / "*" / f"{prefix}.crate"))
        if len(cache_matches) != 1:
            raise SystemExit(
                f"missing or ambiguous Cargo registry source for {name} {version} "
                f"(no extracted source, {len(cache_matches)} cached archives)"
            )
        notice_count = copy_from_crate_archive(Path(cache_matches[0]), prefix, target)
    if notice_count == 0:
        raise SystemExit(f"missing license/notice material for {name} {version}")
PYTHON
cat > "$staged_app/Contents/Resources/Licenses/README.txt" <<'LICENSES'
ScanStudio.app contains mixed-license components.

ScanStudio's original code is MIT (ScanStudio-MIT.txt).
The bundled hardware helper and CoolscanPy are GPL-3.0-only. Their complete
corresponding source snapshots are in ../CorrespondingSource/scanstudio-bridge
and ../CorrespondingSource/coolscanpy, with their GPL texts in this directory.
CPython 3.13 and each included Python wheel's metadata/license material are
listed in python-wheels. libusb 1.0.30 is dynamically loaded from the signed
app bundle under LGPL-2.1-or-later; its license and notice are here and its
complete pinned source archive is in ../CorrespondingSource/libusb. Normal
LS-5000 color-roll detection, preview, and capture require no host driver.
The bundled python-sane binding still needs a compatible system SANE backend
for its optional plain-scan and software-eject paths.
LICENSES

# Browser delivery is intentionally independent from the production app. A
# separately downloaded, independently signed runtime must never become an
# implicit nested payload of ScanStudio.app.
"$script_dir/assert_no_web_runtime.sh" "$staged_app"

# Swift links object provenance strings into the executable even in a release
# build. Remove local symbol/debug tables after the source-path remap and
# before signing so the distributed binary contains no builder filesystem
# paths. This does not alter executable code.
strip -S "$staged_app/Contents/MacOS/scanstudio-engine" "$staged_app/Contents/MacOS/ScanStudio"
codesign --force --sign - "$bundled_libusb"
codesign --verify --strict "$bundled_libusb"
codesign --force --sign - "$staged_app/Contents/MacOS/scanstudio-engine"
codesign --force --sign - "$staged_app/Contents/MacOS/ScanStudio"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

replacement_started=1
if [[ -e "$output" ]]; then
    mv "$output" "$previous_app"
fi
mv "$staged_app" "$output"
codesign --verify --deep --strict "$output"
installed=1

print "Packaged $output"
