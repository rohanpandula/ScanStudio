#!/bin/zsh
# Build the macOS-only, private SANE link SDK used to compile python-sane.
# The SDK is never a runtime dependency and must never be copied into the app.
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
repository_root="${package_root:h:h}"
sdk_destination="${1:-}"
binding_destination="${2:-}"
bridge_source="${3:-$repository_root/bridge}"
bridge_python="${4:-$bridge_source/.venv/bin/python}"

sane_version="1.4.0"
sane_source_url="https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-1.4.0.tar.gz"
sane_source_sha256="f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72"
sane_source_size="7505056"
sane_archive_entries="1295"
sane_archive_expanded_size="37519360"
python_sane_version="2.9.2"
python_sane_source_url="https://files.pythonhosted.org/packages/45/e9/e8baff69fc2347606c547201204d4b4843c7ad8ecb9164eceee42016eff6/python_sane-2.9.2.tar.gz"
python_sane_source_sha256="50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe"
python_sane_source_size="22513"
python_sane_archive_entries="22"
python_sane_archive_expanded_size="122880"
deployment_target="14.0"
source_date_epoch="1748131200"
sane_source_override="${SCANSTUDIO_SANE_SOURCE_ARCHIVE:-}"
python_sane_source_override="${SCANSTUDIO_PYTHON_SANE_SOURCE_ARCHIVE:-}"

die() {
    print -u2 "Pinned SANE link-SDK build refused: $*"
    exit 1
}

require_regular_file() {
    local label="$1"
    local target="$2"
    [[ -f "$target" && ! -L "$target" ]] || die "$label is missing, not regular, or a symlink: $target"
}

require_new_directory() {
    local label="$1"
    local target="$2"
    [[ "$target" == /* ]] || die "$label must be an absolute path: $target"
    local parent="${target:h}"
    [[ -d "$parent" && ! -L "$parent" ]] || die "$label parent is missing, not a directory, or a symlink: $parent"
    [[ ! -e "$target" && ! -L "$target" ]] || die "$label already exists: $target"
    mkdir -m 700 "$target" || die "could not create $label with create-only semantics: $target"
}

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

download_exact() {
    local label="$1"
    local url="$2"
    local expected_size="$3"
    local expected_sha256="$4"
    local destination="$5"
    local partial="${destination}.download"
    [[ ! -e "$partial" && ! -L "$partial" ]] || die "$label partial download path already exists"
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 180 \
        --max-filesize "$expected_size" \
        --output "$partial" "$url"
    require_regular_file "$label download" "$partial"
    local actual_size
    actual_size="$(stat -f '%z' "$partial")"
    [[ "$actual_size" == "$expected_size" ]] \
        || die "$label size mismatch: expected $expected_size, got $actual_size"
    local actual_sha256
    actual_sha256="$(sha256 "$partial")"
    [[ "$actual_sha256" == "$expected_sha256" ]] \
        || die "$label SHA-256 mismatch: expected $expected_sha256, got $actual_sha256"
    mv "$partial" "$destination"
}

copy_exact() {
    local label="$1"
    local source="$2"
    local expected_size="$3"
    local expected_sha256="$4"
    local destination="$5"
    local partial="${destination}.copy"
    require_regular_file "$label override" "$source"
    [[ ! -e "$partial" && ! -L "$partial" ]] || die "$label copy path already exists"
    [[ "$(stat -f '%z' "$source")" == "$expected_size" ]] \
        || die "$label override size does not match the pinned archive"
    install -m 600 "$source" "$partial"
    require_regular_file "$label copied archive" "$partial"
    [[ "$(stat -f '%z' "$partial")" == "$expected_size" ]] \
        || die "$label copied archive size changed"
    [[ "$(sha256 "$partial")" == "$expected_sha256" ]] \
        || die "$label copied archive SHA-256 does not match the pin"
    mv "$partial" "$destination"
}

validate_archive() {
    local label="$1"
    local archive="$2"
    local expected_prefix="$3"
    local expected_entries="$4"
    local expected_expanded_size="$5"
    local entries expanded
    entries="$(tar -tzf "$archive" | wc -l | tr -d ' ')"
    [[ "$entries" == "$expected_entries" ]] \
        || die "$label entry count mismatch: expected $expected_entries, got $entries"
    expanded="$(gzip -dc "$archive" | wc -c | tr -d ' ')"
    [[ "$expanded" == "$expected_expanded_size" ]] \
        || die "$label expanded size mismatch: expected $expected_expanded_size, got $expanded"
    if tar -tvzf "$archive" | awk 'substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { found=1 } END { exit !found }'; then
        die "$label contains an entry that is not a regular file or directory"
    fi
    if tar -tzf "$archive" | awk -v prefix="$expected_prefix/" '
        index($0, prefix) != 1 || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /\/\// { bad=1 }
        END { exit !bad }
    '; then
        die "$label contains an unexpected or unsafe member path"
    fi
}

verify_no_rpath() {
    local label="$1"
    local target="$2"
    if otool -l "$target" | awk '$2 == "LC_RPATH" { found=1 } END { exit !found }'; then
        die "$label contains LC_RPATH"
    fi
}

verify_arch_and_minos() {
    local label="$1"
    local target="$2"
    local expected_arch="$3"
    local architectures minimum
    architectures="$(lipo -archs "$target")"
    [[ "$architectures" == "$expected_arch" ]] \
        || die "$label architecture is '$architectures', expected '$expected_arch'"
    minimum="$(vtool -show-build "$target" | awk '$1 == "minos" { print $2; exit }')"
    [[ "$minimum" == "$deployment_target" ]] \
        || die "$label minimum macOS is '$minimum', expected '$deployment_target'"
}

[[ -n "$sdk_destination" ]] \
    || die "usage: build_sane_link_sdk.sh SDK_DESTINATION [BINDING_VENV BRIDGE_SOURCE PYTHON]"
if [[ -n "$binding_destination" && "$#" -ne 4 ]]; then
    die "binding preparation requires exactly SDK_DESTINATION BINDING_VENV BRIDGE_SOURCE PYTHON"
fi
if [[ -z "$binding_destination" && "$#" -ne 1 ]]; then
    die "SDK-only preparation accepts exactly one destination argument"
fi

host_arch="$(uname -m)"
case "$host_arch" in
    arm64)
        host_sane_path="/opt/homebrew/opt/sane-backends/lib/libsane.1.dylib"
        ;;
    x86_64)
        host_sane_path="/usr/local/opt/sane-backends/lib/libsane.1.dylib"
        ;;
    *)
        die "unsupported macOS build architecture: $host_arch"
        ;;
esac
sentinel_install_name="/__ScanStudio_SANE_Link_SDK_ONLY_${sane_version//./_}_${host_arch}__/libsane.1.dylib"

require_new_directory "SANE link SDK destination" "$sdk_destination"
sdk_destination="${sdk_destination:A}"
sdk_work="$sdk_destination/.work"
mkdir -m 700 "$sdk_work"
source_archive="$sdk_work/sane-backends-$sane_version.tar.gz"
if [[ -n "$sane_source_override" ]]; then
    copy_exact "sane-backends source" "$sane_source_override" "$sane_source_size" \
        "$sane_source_sha256" "$source_archive"
else
    download_exact "sane-backends source" "$sane_source_url" "$sane_source_size" \
        "$sane_source_sha256" "$source_archive"
fi
validate_archive "sane-backends source" "$source_archive" \
    "sane-backends-$sane_version" "$sane_archive_entries" "$sane_archive_expanded_size"

source_parent="$sdk_work/source"
build_root="$sdk_work/build"
build_home="$sdk_work/home"
build_tmp="$sdk_work/tmp"
mkdir -m 700 "$source_parent" "$build_root" "$build_home" "$build_tmp"
tar -xzf "$source_archive" -C "$source_parent"
source_root="$source_parent/sane-backends-$sane_version"
require_regular_file "sane-backends configure script" "$source_root/configure"
require_regular_file "SANE public header" "$source_root/include/sane/sane.h"
if find "$source_root" -type l -print -quit | grep -q .; then
    die "validated sane-backends source unexpectedly extracted a symlink"
fi

build_jobs="$(sysctl -n hw.ncpu)"
[[ "$build_jobs" == <-> && "$build_jobs" -ge 1 && "$build_jobs" -le 256 ]] \
    || die "invalid host CPU count: $build_jobs"
sdk_prefix="/__ScanStudio_SANE_Link_SDK_${sane_version//./_}_${host_arch}__"
configure_log="$sdk_work/configure.log"
build_log="$sdk_work/build.log"
secure_path="/usr/bin:/bin:/usr/sbin:/sbin"
if ! (
    cd "$build_root"
    env -i \
        HOME="$build_home" PATH="$secure_path" TMPDIR="$build_tmp" \
        LANG=C LC_ALL=C ZERO_AR_DATE=1 SOURCE_DATE_EPOCH="$source_date_epoch" \
        MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
        CC=/usr/bin/clang CXX=/usr/bin/clang++ \
        CFLAGS="-O2 -mmacosx-version-min=$deployment_target -fdebug-prefix-map=$sdk_work=/sane-sdk -ffile-prefix-map=$sdk_work=/sane-sdk" \
        CXXFLAGS="-O2 -mmacosx-version-min=$deployment_target -fdebug-prefix-map=$sdk_work=/sane-sdk -ffile-prefix-map=$sdk_work=/sane-sdk" \
        LDFLAGS="-mmacosx-version-min=$deployment_target" \
        BACKENDS=net PRELOADABLE_BACKENDS= \
        "$source_root/configure" \
            --prefix="$sdk_prefix" \
            --disable-dependency-tracking \
            --disable-static --enable-shared --disable-rpath \
            --disable-nls --disable-locking --disable-ipv6 \
            --disable-preload --disable-local-backends \
            --without-gphoto2 --without-v4l --without-avahi \
            --without-snmp --without-systemd --without-usb \
            --without-libcurl --without-poppler-glib \
            --without-usb-record-replay
) > "$configure_log" 2>&1; then
    print -u2 "Pinned sane-backends configure failed; final output follows:"
    tail -n 200 "$configure_log" >&2
    exit 1
fi
if ! env -i \
    HOME="$build_home" PATH="$secure_path" TMPDIR="$build_tmp" \
    LANG=C LC_ALL=C ZERO_AR_DATE=1 SOURCE_DATE_EPOCH="$source_date_epoch" \
    MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
    /usr/bin/make -C "$build_root" -j "$build_jobs" > "$build_log" 2>&1; then
    print -u2 "Pinned sane-backends build failed; final output follows:"
    tail -n 200 "$build_log" >&2
    exit 1
fi

built_library="$build_root/backend/.libs/libsane.1.dylib"
require_regular_file "built SANE link library" "$built_library"
verify_arch_and_minos "built SANE link library" "$built_library" "$host_arch"
verify_no_rpath "built SANE link library" "$built_library"
install_name_tool -id "$sentinel_install_name" "$built_library"
[[ "$(otool -D "$built_library" | tail -n +2 | head -n 1)" == "$sentinel_install_name" ]] \
    || die "SANE link library did not retain its unique SDK-only install identity"
if otool -L "$built_library" | tail -n +3 | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    otool -L "$built_library" >&2
    die "SANE link library has a non-system transitive dependency"
fi
if ! otool -L "$built_library" | sed -n '2p' | grep -qF '(compatibility version 6.0.0, current version 6.0.0)'; then
    otool -L "$built_library" >&2
    die "SANE link library ABI version is not the reviewed 6.0.0"
fi
for symbol in _sane_init _sane_exit _sane_get_devices _sane_open _sane_close \
    _sane_get_option_descriptor _sane_control_option _sane_get_parameters \
    _sane_start _sane_read _sane_cancel _sane_set_io_mode _sane_get_select_fd; do
    nm -gU "$built_library" | awk '{print $3}' | grep -Fxq "$symbol" \
        || die "SANE link library is missing required ABI symbol $symbol"
done
if strings -a "$built_library" | grep -Fq "$sdk_work"; then
    die "SANE link library retains its private build path"
fi

mkdir -m 700 "$sdk_destination/include" "$sdk_destination/include/sane" "$sdk_destination/lib"
install -m 644 "$source_root/include/sane/sane.h" "$sdk_destination/include/sane/sane.h"
install -m 755 "$built_library" "$sdk_destination/lib/libsane.1.dylib"
ln -s libsane.1.dylib "$sdk_destination/lib/libsane.dylib"
print -r -- "$sane_version" > "$sdk_destination/VERSION"
print -r -- "$sane_source_url" > "$sdk_destination/SOURCE_URL"
print -r -- "$sane_source_sha256" > "$sdk_destination/SOURCE_SHA256"
print -r -- "$sentinel_install_name" > "$sdk_destination/SENTINEL_INSTALL_NAME"
print -r -- "$host_sane_path" > "$sdk_destination/CANONICAL_HOST_SANE_PATH"
print -r -- "$(sha256 "$sdk_destination/include/sane/sane.h")" > "$sdk_destination/HEADER_SHA256"
print -r -- "$(sha256 "$sdk_destination/lib/libsane.1.dylib")" > "$sdk_destination/LIBRARY_SHA256"

# The source tree and compiled intermediate graph are private build inputs, not
# a runtime. Keep only the minimal header/library SDK and its immutable receipt.
rm -rf "$sdk_work"
if find "$sdk_destination" -mindepth 1 -maxdepth 1 \
    ! -name include ! -name lib ! -name VERSION ! -name SOURCE_URL \
    ! -name SOURCE_SHA256 ! -name SENTINEL_INSTALL_NAME \
    ! -name CANONICAL_HOST_SANE_PATH ! -name HEADER_SHA256 \
    ! -name LIBRARY_SHA256 -print -quit | grep -q .; then
    die "SANE link SDK contains an unexpected top-level entry"
fi

if [[ -z "$binding_destination" ]]; then
    print "Built private SANE $sane_version link SDK for macOS $deployment_target ($host_arch): $sdk_destination"
    exit 0
fi

require_directory_parent="${binding_destination:h}"
[[ -d "$require_directory_parent" && ! -L "$require_directory_parent" ]] \
    || die "python-sane venv parent is missing, not a directory, or a symlink: $require_directory_parent"
[[ "$binding_destination" == /* ]] || die "python-sane venv destination must be absolute"
[[ ! -e "$binding_destination" && ! -L "$binding_destination" ]] \
    || die "python-sane venv destination already exists: $binding_destination"
[[ -d "$bridge_source" && ! -L "$bridge_source" ]] \
    || die "bridge source is missing, not a directory, or a symlink: $bridge_source"
require_regular_file "bridge lockfile" "$bridge_source/uv.lock"
[[ -x "$bridge_python" && ! -L "$bridge_python" || -x "$bridge_python" ]] \
    || die "bridge Python is not executable: $bridge_python"

"$bridge_python" -I -B - "$bridge_source/uv.lock" <<'PYTHON'
from pathlib import Path
import platform
import sys
import tomllib

if platform.python_implementation() != "CPython" or sys.version_info[:3] != (3, 13, 14):
    raise SystemExit(
        f"python-sane must be compiled with exact CPython 3.13.14, got {platform.python_implementation()} {platform.python_version()}"
    )
lock = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
matches = [package for package in lock.get("package", []) if package.get("name") == "python-sane"]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one python-sane lock package, found {len(matches)}")
expected = {
    "version": "2.9.2",
    "url": "https://files.pythonhosted.org/packages/45/e9/e8baff69fc2347606c547201204d4b4843c7ad8ecb9164eceee42016eff6/python_sane-2.9.2.tar.gz",
    "hash": "sha256:50ab8e0b033cececad26c7231a7254f80ad8fe9ec6b5c25add2493d7e2a07bbe",
    "size": 22513,
    "upload-time": "2025-07-21T21:20:21.735Z",
}
package = matches[0]
actual = {"version": package.get("version"), **package.get("sdist", {})}
if actual != expected:
    raise SystemExit(f"python-sane lock provenance changed: {actual!r}")
if package.get("wheels"):
    raise SystemExit("python-sane lock unexpectedly gained a binary wheel")
PYTHON

uv_path="$(command -v uv || true)"
[[ -n "$uv_path" && -x "$uv_path" ]] || die "uv is required to install locked runtime dependencies"
uv_version_output="$($uv_path --version)"
[[ "${${(z)uv_version_output}[1,2]}" == "uv 0.11.30" ]] \
    || die "uv 0.11.30 is required, got '$uv_version_output'"

binding_work="$sdk_destination/.binding-work"
mkdir -m 700 "$binding_work"
binding_home="$binding_work/home"
binding_tmp="$binding_work/tmp"
python_source_parent="$binding_work/source"
mkdir -m 700 "$binding_home" "$binding_tmp" "$python_source_parent"
python_source_archive="$binding_work/python_sane-$python_sane_version.tar.gz"
if [[ -n "$python_sane_source_override" ]]; then
    copy_exact "python-sane source" "$python_sane_source_override" \
        "$python_sane_source_size" "$python_sane_source_sha256" "$python_source_archive"
else
    download_exact "python-sane source" "$python_sane_source_url" "$python_sane_source_size" \
        "$python_sane_source_sha256" "$python_source_archive"
fi
validate_archive "python-sane source" "$python_source_archive" \
    "python_sane-$python_sane_version" "$python_sane_archive_entries" \
    "$python_sane_archive_expanded_size"
tar -xzf "$python_source_archive" -C "$python_source_parent"
python_source_root="$python_source_parent/python_sane-$python_sane_version"
require_regular_file "python-sane C source" "$python_source_root/_sane.c"
require_regular_file "python-sane module" "$python_source_root/sane.py"
require_regular_file "python-sane metadata" "$python_source_root/PKG-INFO"
require_regular_file "python-sane license" "$python_source_root/COPYING"
if find "$python_source_root" -type l -print -quit | grep -q .; then
    die "validated python-sane source unexpectedly extracted a symlink"
fi

# Resolve every production dependency from the exact lock into a new venv.
# Local projects and python-sane are deliberately skipped: their source is
# copied separately, while python-sane is compiled below without a wheel,
# mutable PEP 517 build dependency, or cache.
uv_dir="${uv_path:h}"
if ! (
    cd "$bridge_source"
    env -i \
        HOME="$binding_home" PATH="$secure_path:$uv_dir" TMPDIR="$binding_tmp" \
        LANG=C LC_ALL=C \
        UV_PROJECT_ENVIRONMENT="$binding_destination" \
        UV_PYTHON="$bridge_python" UV_PYTHON_PREFERENCE=only-managed \
        UV_PYTHON_DOWNLOADS=never UV_NO_CONFIG=1 UV_NO_ENV_FILE=1 UV_NO_PROGRESS=1 \
        "$uv_path" sync --locked --extra scanner --no-dev --no-cache \
            --no-install-local --no-install-package python-sane \
            --python "$bridge_python"
); then
    die "locked production dependency sync failed"
fi

binding_python="$binding_destination/bin/python"
[[ -x "$binding_python" ]] || die "locked dependency sync did not create the private package venv"
site_packages="$binding_destination/lib/python3.13/site-packages"
[[ -d "$site_packages" && ! -L "$site_packages" ]] \
    || die "private package venv has no regular Python 3.13 site-packages directory"
python_include="$($bridge_python -I -B -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))')"
extension_suffix="$($bridge_python -I -B -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')"
[[ "$extension_suffix" == ".cpython-313-darwin.so" ]] \
    || die "unexpected CPython extension ABI suffix: $extension_suffix"
[[ -d "$python_include" && ! -L "$python_include" ]] \
    || die "CPython include directory is missing, not a directory, or a symlink: $python_include"

extension="$site_packages/_sane$extension_suffix"
[[ ! -e "$extension" && ! -L "$extension" ]] \
    || die "python-sane extension destination unexpectedly exists"
compile_log="$binding_work/python-sane-build.log"
if ! env -i \
    HOME="$binding_home" PATH="$secure_path" TMPDIR="$binding_tmp" \
    LANG=C LC_ALL=C ZERO_AR_DATE=1 SOURCE_DATE_EPOCH="$source_date_epoch" \
    MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
    /usr/bin/clang -bundle -undefined dynamic_lookup \
        -O2 -fPIC -arch "$host_arch" -mmacosx-version-min="$deployment_target" \
        -fdebug-prefix-map="$binding_work=/python-sane-$python_sane_version" \
        -ffile-prefix-map="$binding_work=/python-sane-$python_sane_version" \
        -I "$python_include" -I "$sdk_destination/include" \
        "$python_source_root/_sane.c" \
        -L "$sdk_destination/lib" -lsane \
        -o "$extension" > "$compile_log" 2>&1; then
    print -u2 "Pinned python-sane source build failed; final output follows:"
    tail -n 200 "$compile_log" >&2
    exit 1
fi
install -m 644 "$python_source_root/sane.py" "$site_packages/sane.py"
dist_info="$site_packages/python_sane-$python_sane_version.dist-info"
mkdir -m 755 "$dist_info" "$dist_info/licenses"
install -m 644 "$python_source_root/PKG-INFO" "$dist_info/METADATA"
install -m 644 "$python_source_root/COPYING" "$dist_info/licenses/COPYING"
print -r -- 'scanstudio-pinned-source-builder' > "$dist_info/INSTALLER"

extension_matches=("$site_packages"/_sane*.so(N))
dist_matches=("$site_packages"/python_sane-*.dist-info(N/))
(( ${#extension_matches} == 1 )) || die "private venv must contain exactly one regular _sane extension"
(( ${#dist_matches} == 1 )) || die "private venv must contain exactly one python-sane dist-info directory"
"$binding_python" -I -B - "$dist_info/METADATA" <<'PYTHON'
from email.parser import Parser
from pathlib import Path
import sys

metadata = Parser().parsestr(Path(sys.argv[1]).read_text(encoding="utf-8"))
if metadata["Name"] != "python-sane" or metadata["Version"] != "2.9.2":
    raise SystemExit("python-sane distribution metadata is not exactly python-sane 2.9.2")
PYTHON
verify_arch_and_minos "python-sane extension" "$extension" "$host_arch"
verify_no_rpath "python-sane extension" "$extension"
nm -g "$extension" | awk '{print $3}' | grep -Fxq _PyInit__sane \
    || die "python-sane extension does not export the CPython _sane initializer"
dependency_lines="$(otool -L "$extension" | tail -n +2 | awk '{print $1}')"
[[ "$(print -r -- "$dependency_lines" | grep -Fxc "$sentinel_install_name")" == 1 ]] \
    || die "python-sane extension did not link exactly once to the SDK sentinel identity"
if print -r -- "$dependency_lines" | grep -vFx "$sentinel_install_name" \
    | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    otool -L "$extension" >&2
    die "python-sane extension has a non-system dependency besides the SDK sentinel"
fi
if strings -a "$extension" | grep -Fq "$binding_work"; then
    die "python-sane extension retains its private build path"
fi

source_extension_sha256="$(sha256 "$extension")"
install_name_tool -change "$sentinel_install_name" "$host_sane_path" "$extension"
dependency_lines="$(otool -L "$extension" | tail -n +2 | awk '{print $1}')"
[[ "$(print -r -- "$dependency_lines" | grep -Fxc "$host_sane_path")" == 1 ]] \
    || die "python-sane extension does not reference exactly one canonical host SANE library"
if print -r -- "$dependency_lines" | grep -Fq '__ScanStudio_SANE_Link_SDK'; then
    die "python-sane extension retains the SDK sentinel after canonical rewrite"
fi
verify_arch_and_minos "rewritten python-sane extension" "$extension" "$host_arch"
verify_no_rpath "rewritten python-sane extension" "$extension"

provenance="$binding_destination/.scanstudio-python-sane-provenance"
mkdir -m 700 "$provenance"
install -m 644 "$python_source_archive" "$provenance/python_sane-$python_sane_version.tar.gz"
print -r -- "$python_sane_version" > "$provenance/VERSION"
print -r -- "$python_sane_source_url" > "$provenance/SOURCE_URL"
print -r -- "$python_sane_source_sha256" > "$provenance/SOURCE_SHA256"
print -r -- "$host_sane_path" > "$provenance/CANONICAL_HOST_SANE_PATH"
print -r -- "${extension:t}" > "$provenance/EXTENSION_BASENAME"
print -r -- "$source_extension_sha256" > "$provenance/EXTENSION_BEFORE_REWRITE_SHA256"
print -r -- "$(sha256 "$extension")" > "$provenance/EXTENSION_SHA256"

rm -rf "$binding_work"
if find "$binding_destination" -type f \
    \( -name 'libsane*.dylib' -o -name 'libsane*.so*' \) -print -quit | grep -q .; then
    die "private package venv accidentally contains a SANE runtime library"
fi
if grep -R -a -q -F "$sdk_destination" "$binding_destination"; then
    die "private package venv retains a SANE SDK build path"
fi

print "Built pinned python-sane $python_sane_version for macOS $deployment_target ($host_arch)"
print "Extension $extension"
print "Host SANE $host_sane_path"
