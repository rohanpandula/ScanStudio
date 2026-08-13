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
if [[ ! -x "$bridge_python" ]]; then
    print -u2 "ScanStudio package prerequisite missing: exact CPython 3.13.14 ('$bridge_python'). Set SCANSTUDIO_BRIDGE_PYTHON to the reviewed uv-managed interpreter."
    exit 127
fi
if ! "$bridge_python" -I -B -c 'import platform, sys; assert platform.python_implementation() == "CPython" and sys.version_info[:3] == (3, 13, 14)'; then
    print -u2 "Refusing to package with anything other than exact CPython 3.13.14."
    exit 66
fi
if [[ ! -f "$bridge_source/LICENSE" || ! -f "$coolscanpy_source/LICENSE" ]]; then
    print -u2 "Refusing to package bridge without its GPL source license and CoolscanPy's GPL source license."
    exit 66
fi
# Version and sealed capture identity have one source of truth: the exact
# CoolscanPy pyproject/lock/source tree copied below.  Run the stdlib-only gate
# before spending time on native builds, then use its parsed version for every
# generated metadata record.
coolscanpy_identity_verifier="$package_root/../../scripts/verify_coolscanpy_source.py"
if [[ ! -f "$coolscanpy_identity_verifier" ]]; then
    print -u2 "Refusing to package without the CoolscanPy identity verifier: $coolscanpy_identity_verifier"
    exit 66
fi
coolscanpy_version="$(
    "$bridge_python" -I -B "$coolscanpy_identity_verifier" \
        "$coolscanpy_source" --print-version
)"

bridge_runtime_prefix="$($bridge_python -I -B -c 'import sys; print(sys.base_prefix)')"
bridge_sysconfig_prefix="$($bridge_python -I -B -c 'import sysconfig; print(sysconfig.get_config_var("prefix"))')"
if [[ ! -x "$bridge_runtime_prefix/bin/python3.13" ]]; then
    print -u2 "Refusing to package a non-relocatable Python runtime: expected '$bridge_runtime_prefix/bin/python3.13'."
    exit 66
fi
if [[ "$bridge_sysconfig_prefix" != /* ]]; then
    print -u2 "Refusing to package a Python runtime with a non-absolute sysconfig prefix: '$bridge_sysconfig_prefix'."
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

# Build the optional python-sane compatibility extension from its exact
# locked 2.9.2 sdist against a private, source-built SANE 1.4.0 link SDK.
# The helper rewrites the SDK-only sentinel dependency to the canonical host
# SANE path only after proving the link provenance, ABI, architecture, and
# macOS floor. Neither the SDK nor a SANE runtime is copied into the app.
sane_link_sdk="$staging_root/sane-link-sdk"
package_venv="$staging_root/bridge-package-venv"
"$script_dir/build_sane_link_sdk.sh" \
    "$sane_link_sdk" "$package_venv" "$bridge_source" "$bridge_python"
bridge_site_packages="$package_venv/lib/python3.13/site-packages"
require_directory "private locked package site-packages" "$bridge_site_packages"
python_sane_provenance="$package_venv/.scanstudio-python-sane-provenance"
require_directory "pinned python-sane provenance" "$python_sane_provenance"
python_sane_extension_name="$(<"$python_sane_provenance/EXTENSION_BASENAME")"
python_sane_extension_sha256="$(<"$python_sane_provenance/EXTENSION_SHA256")"
python_sane_host_path="$(<"$python_sane_provenance/CANONICAL_HOST_SANE_PATH")"
source_python_sane_extension="$bridge_site_packages/$python_sane_extension_name"
if [[ ! -f "$source_python_sane_extension" || -L "$source_python_sane_extension" ]] \
    || [[ "$(shasum -a 256 "$source_python_sane_extension" | awk '{print $1}')" != "$python_sane_extension_sha256" ]]; then
    print -u2 "Refusing to package when the prepared python-sane extension disagrees with its pinned-source receipt."
    exit 1
fi

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
# app can report "I am 0.7.0-beta.N". Best-effort: dev builds without
# SCANSTUDIO_RELEASE_VERSION keep the empty default.
if [[ -n "${SCANSTUDIO_RELEASE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :ScanStudioRelease '$SCANSTUDIO_RELEASE_VERSION'" \
        "$staged_app/Contents/Info.plist" \
        || { print -u2 "Failed to stamp ScanStudioRelease=$SCANSTUDIO_RELEASE_VERSION"; exit 1; }
fi

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
staged_site_packages="$staged_app/Contents/Resources/BridgeRuntime/site-packages"
staged_python_sane_extensions=("$staged_site_packages"/_sane*.so(N.))
staged_python_sane_dist_info=("$staged_site_packages"/python_sane-*.dist-info(N/))
if (( ${#staged_python_sane_extensions} != 1 || ${#staged_python_sane_dist_info} != 1 )); then
    print -u2 "Refusing package: expected exactly one regular python-sane extension and one dist-info directory."
    exit 1
fi
staged_python_sane_extension="${staged_python_sane_extensions[1]}"
if [[ "${staged_python_sane_extension:t}" != "$python_sane_extension_name" ]] \
    || [[ "$(shasum -a 256 "$staged_python_sane_extension" | awk '{print $1}')" != "$python_sane_extension_sha256" ]]; then
    print -u2 "Refusing package: staged python-sane bytes differ from the pinned-source prepared extension."
    exit 1
fi
if [[ "$(lipo -archs "$staged_python_sane_extension")" != "$app_architectures" ]]; then
    print -u2 "Refusing package: python-sane extension architecture does not match the app."
    exit 1
fi
python_sane_minimum="$(vtool -show-build "$staged_python_sane_extension" | awk '$1 == "minos" { print $2; exit }')"
if [[ "$python_sane_minimum" != "$app_minimum" ]]; then
    print -u2 "Refusing package: python-sane minimum macOS is '$python_sane_minimum', expected '$app_minimum'."
    exit 1
fi
if otool -l "$staged_python_sane_extension" \
    | awk '$2 == "LC_RPATH" { found=1 } END { exit !found }'; then
    print -u2 "Refusing package: python-sane extension contains LC_RPATH."
    exit 1
fi
python_sane_dependencies="$(otool -L "$staged_python_sane_extension" | tail -n +2 | awk '{print $1}')"
if [[ "$(print -r -- "$python_sane_dependencies" | grep -Fxc "$python_sane_host_path")" != 1 ]] \
    || print -r -- "$python_sane_dependencies" | grep -Fq '__ScanStudio_SANE_Link_SDK' \
    || print -r -- "$python_sane_dependencies" | grep -vFx "$python_sane_host_path" \
        | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    print -u2 "Refusing package: python-sane linkage is not exactly the reviewed host-SANE ABI plus system libraries."
    otool -L "$staged_python_sane_extension" >&2
    exit 1
fi
if ! grep -q '^Name: python-sane$' "${staged_python_sane_dist_info[1]}/METADATA" \
    || ! grep -q '^Version: 2.9.2$' "${staged_python_sane_dist_info[1]}/METADATA"; then
    print -u2 "Refusing package: python-sane distribution metadata is not exactly 2.9.2."
    exit 1
fi
if find "$staged_site_packages" -maxdepth 1 -type f \
    \( -name 'libsane*.dylib' -o -name 'libsane*.so*' \) -print -quit | grep -q . \
    || grep -R -a -q -F "$sane_link_sdk" "$staged_site_packages"; then
    print -u2 "Refusing package: private SANE SDK or runtime material leaked into staged site-packages."
    exit 1
fi
# The GPL source is intentionally imported from CorrespondingSource rather
# than an editable wheel. Retain just the neutral distribution metadata that
# the bridge uses to report its own version; it contains no local checkout
# path or maintainer email.
mkdir -p "$staged_app/Contents/Resources/BridgeRuntime/site-packages/scanstudio_bridge-0.1.0.dist-info"
print -r -- $'Metadata-Version: 2.1\nName: scanstudio-bridge\nVersion: 0.1.0\nLicense-Expression: GPL-3.0-only\n' \
    > "$staged_app/Contents/Resources/BridgeRuntime/site-packages/scanstudio_bridge-0.1.0.dist-info/METADATA"
coolscanpy_dist_info="$staged_app/Contents/Resources/BridgeRuntime/site-packages/coolscanpy-$coolscanpy_version.dist-info"
mkdir -p "$coolscanpy_dist_info"
printf 'Metadata-Version: 2.1\nName: coolscanpy\nVersion: %s\nLicense-Expression: GPL-3.0-only\n' \
    "$coolscanpy_version" > "$coolscanpy_dist_info/METADATA"
copy_corresponding_source "$bridge_source" "$staged_app/Contents/Resources/CorrespondingSource/scanstudio-bridge"
copy_corresponding_source "$coolscanpy_source" "$staged_app/Contents/Resources/CorrespondingSource/coolscanpy"
"$bridge_python" -I -B "$coolscanpy_identity_verifier" \
    "$staged_app/Contents/Resources/CorrespondingSource/coolscanpy" \
    --metadata-root "$staged_app/Contents/Resources/BridgeRuntime/site-packages"
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
uv_executable="$(command -v uv)"
uv_lock_home="$staging_root/uv-lock-home"
mkdir -m 700 "$uv_lock_home"
(
    cd "$staged_bridge_source"
    env -i \
        HOME="$uv_lock_home" PATH="${uv_executable:h}:/usr/bin:/bin" \
        LANG=C LC_ALL=C UV_PYTHON_DOWNLOADS=never \
        "$uv_executable" --no-config lock --offline --no-cache \
            --managed-python --python "$bridge_python"
)
install_name_tool -id '@rpath/libpython3.13.dylib' \
    "$staged_app/Contents/Resources/BridgeRuntime/python/lib/libpython3.13.dylib"
# uv's generated sysconfig table records its build cache prefix. It is not a
# runtime search path, but leaving it would leak a private machine path into a
# public bundle. Replace it with an intentionally non-filesystem placeholder;
# CPython derives the real prefix from its relocated executable.
runtime_sysconfig="$staged_app/Contents/Resources/BridgeRuntime/python/lib/python3.13/_sysconfigdata__darwin_darwin.py"
"$bridge_python" -I -B - \
    "$runtime_sysconfig" "$bridge_runtime_prefix" "$bridge_sysconfig_prefix" <<'PYTHON'
import ast
from pathlib import Path
import pprint
import re
import sys

config_path = Path(sys.argv[1])
runtime_prefixes = sorted(set(sys.argv[2:]), key=len, reverse=True)
contents = config_path.read_text(encoding="utf-8")
module = ast.parse(contents, filename=str(config_path))
assignments = [
    node for node in module.body
    if isinstance(node, ast.Assign)
    and len(node.targets) == 1
    and isinstance(node.targets[0], ast.Name)
    and node.targets[0].id == "build_time_vars"
]
if len(assignments) != 1:
    raise SystemExit("packaged CPython sysconfig table has an unexpected structure")
build_time_vars = ast.literal_eval(assignments[0].value)
if not isinstance(build_time_vars, dict):
    raise SystemExit("packaged CPython sysconfig table is not a literal dictionary")

placeholder = "/__SCANSTUDIO_BUNDLED_PYTHON__"
path_component = r"[^/\s:;,'\"(){}\[\]<>]+"
ephemeral_roots = (
    re.compile(
        rf"/(?:private/)?var/folders/{path_component}/{path_component}/"
        rf"(?:T|C)/{path_component}"
    ),
    re.compile(rf"/(?:private/)?tmp/{path_component}"),
)
replacement_count = 0

def scrub(value):
    global replacement_count
    if isinstance(value, str):
        for prefix in runtime_prefixes:
            count = value.count(prefix)
            if count:
                value = value.replace(prefix, placeholder)
                replacement_count += count
        for pattern in ephemeral_roots:
            value, count = pattern.subn(placeholder, value)
            replacement_count += count
        return value
    if isinstance(value, dict):
        return {scrub(key): scrub(item) for key, item in value.items()}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, tuple):
        return tuple(scrub(item) for item in value)
    return value

sanitized = scrub(build_time_vars)
if replacement_count == 0:
    raise SystemExit("packaged CPython sysconfig table contained no expected build prefix")
rendered = (
    "# system configuration generated and used by the sysconfig module\n"
    "build_time_vars = "
    + pprint.pformat(sanitized, sort_dicts=True, width=120)
    + "\n"
)
if re.search(r"/(?:private/)?var/folders/|/(?:private/)?tmp/|/Users/", rendered):
    raise SystemExit("packaged CPython sysconfig table retains a private build path")
if any(prefix in rendered for prefix in runtime_prefixes):
    raise SystemExit("packaged CPython sysconfig table retains its runtime build prefix")
config_path.write_text(rendered, encoding="utf-8")
PYTHON
"$staged_app/Contents/Resources/BridgeRuntime/python/bin/python3.13" \
    -I -B -c 'import sysconfig; assert sysconfig.get_config_var("VERSION") == "3.13"'
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
mkdir -p "$staged_app/Contents/Resources/CorrespondingSource/python-sane"
install -m 644 \
    "$python_sane_provenance/python_sane-2.9.2.tar.gz" \
    "$staged_app/Contents/Resources/CorrespondingSource/python-sane/python_sane-2.9.2.tar.gz"
install -m 755 \
    "$script_dir/build_sane_link_sdk.sh" \
    "$staged_app/Contents/Resources/CorrespondingSource/python-sane/build_sane_link_sdk.sh"
print -r -- $'Rebuild the bundled python-sane extension on macOS with Apple command-line developer tools, exact uv 0.11.30, the ScanStudio bridge/CoolScanPy sibling source tree, and exact CPython 3.13.14:\n\n  SCANSTUDIO_PYTHON_SANE_SOURCE_ARCHIVE="$PWD/python_sane-2.9.2.tar.gz" \\\n  ./build_sane_link_sdk.sh \\\n    "$PWD/rebuilt-sane-link-sdk" "$PWD/rebuilt-python-sane-venv" \\\n    /path/to/scanstudio-bridge /path/to/exact/python3.13\n\nThe script verifies the adjacent source archive SHA-256 (50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe), downloads and verifies sane-backends 1.4.0 for a private build-only link SDK, and targets macOS deployment target 14.0. It proves the SDK-only Mach-O identity, architecture, minimum OS, ABI, dependencies, and lack of RPATH before rewriting the extension to the architecture-specific canonical host libsane.1.dylib path. No SANE runtime library is bundled.\n' \
    > "$staged_app/Contents/Resources/CorrespondingSource/python-sane/REBUILD.txt"
print -r -- $'python-sane 2.9.2\nLicense: permissive python-sane license; see the packaged COPYING text\nSource: https://files.pythonhosted.org/packages/45/e9/e8baff69fc2347606c547201204d4b4843c7ad8ecb9164eceee42016eff6/python_sane-2.9.2.tar.gz\nSource SHA-256: 50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe\nThe exact source archive and source-build instructions are under Contents/Resources/CorrespondingSource/python-sane. The package contains only the extension and Python module, never the private SANE link SDK or a SANE runtime.\n' \
    > "$staged_app/Contents/Resources/Licenses/python-sane-NOTICE.txt"
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
The python-sane 2.9.2 binding is built from the exact source and instructions
in ../CorrespondingSource/python-sane against a private SANE 1.4.0 link SDK.
The SDK and SANE runtime are not bundled; optional plain-scan and software-
eject paths still need a compatible system SANE backend.
LICENSES

# Final runtime-boundary proof before signing: source/rebuild material is
# visible, but neither the private SDK, its sentinel linkage, nor libsane may
# appear anywhere executable or loadable in the app.
runtime_scan_targets=(
    "$staged_app/Contents/MacOS"
    "$staged_app/Contents/Frameworks"
    "$staged_app/Contents/Resources/BridgeRuntime"
)
if find "${runtime_scan_targets[@]}" -type f \
    \( -name 'libsane*.dylib' -o -name 'libsane*.so*' \) -print -quit | grep -q . \
    || grep -R -a -q -F '__ScanStudio_SANE_Link_SDK' "${runtime_scan_targets[@]}" \
    || grep -R -a -q -F "$sane_link_sdk" "${runtime_scan_targets[@]}"; then
    print -u2 "Refusing package: private SANE SDK identity, path, or runtime leaked into executable app content."
    exit 1
fi

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
