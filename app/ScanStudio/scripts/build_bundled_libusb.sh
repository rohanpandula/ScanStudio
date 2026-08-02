#!/bin/zsh
# Build the app-owned libusb from pinned source at ScanStudio's macOS floor.
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
destination="${1:-$package_root/.build/bundled-libusb}"

libusb_version="1.0.30"
libusb_source_sha256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"
libusb_source_url="https://github.com/libusb/libusb/releases/download/v${libusb_version}/libusb-${libusb_version}.tar.bz2"
deployment_target="${SCANSTUDIO_LIBUSB_DEPLOYMENT_TARGET:-}"
if [[ -z "$deployment_target" ]]; then
    deployment_target="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$package_root/packaging/Info.plist")"
fi
source_override="${SCANSTUDIO_LIBUSB_SOURCE_ARCHIVE:-}"
libusb_install_name='@rpath/coolscanpy/_native/libusb-1.0.dylib'

if [[ -e "$destination" ]]; then
    print -u2 "Refusing to replace an existing bundled-libusb build directory: $destination"
    exit 73
fi
mkdir -p "$destination"
destination="${destination:A}"

source_archive="$destination/libusb-${libusb_version}.tar.bz2"
if [[ -n "$source_override" ]]; then
    if [[ ! -f "$source_override" || -L "$source_override" ]]; then
        print -u2 "Pinned libusb source override is missing, not regular, or a symlink: $source_override"
        exit 66
    fi
    install -m 644 "$source_override" "$source_archive"
else
    download="$destination/.libusb-${libusb_version}.download"
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --output "$download" "$libusb_source_url"
    mv "$download" "$source_archive"
fi

actual_source_sha256="$(shasum -a 256 "$source_archive" | awk '{print $1}')"
if [[ "$actual_source_sha256" != "$libusb_source_sha256" ]]; then
    print -u2 "Pinned libusb source SHA-256 mismatch: expected $libusb_source_sha256, got $actual_source_sha256"
    exit 1
fi

source_parent="$destination/source"
install_root="$destination/install"
mkdir -p "$source_parent"
tar -xjf "$source_archive" -C "$source_parent"
source_root="$source_parent/libusb-${libusb_version}"
if [[ ! -x "$source_root/configure" || ! -f "$source_root/COPYING" ]]; then
    print -u2 "Pinned libusb archive did not contain the expected source and license"
    exit 1
fi

build_jobs="$(sysctl -n hw.ncpu)"
build_log="$destination/build.log"
if (
    set -euo pipefail
    cd "$source_root"
    MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
    CFLAGS="-O2 -mmacosx-version-min=$deployment_target" \
    LDFLAGS="-mmacosx-version-min=$deployment_target" \
        ./configure \
            --disable-dependency-tracking \
            --disable-static \
            --enable-shared \
            --prefix=/usr/local \
    && make -j "$build_jobs" \
    && make install DESTDIR="$install_root"
) > "$build_log" 2>&1; then
    :
else
    build_status=$?
    print -u2 "Pinned libusb source build failed; final build output follows:"
    tail -n 200 "$build_log" >&2
    exit "$build_status"
fi

built_library="$install_root/usr/local/lib/libusb-1.0.0.dylib"
if [[ ! -f "$built_library" || -L "$built_library" ]]; then
    print -u2 "Pinned libusb build did not produce a regular shared library"
    exit 1
fi
install_name_tool -id "$libusb_install_name" "$built_library"
if [[ "$(otool -D "$built_library" | tail -n +2 | head -n 1)" != "$libusb_install_name" ]]; then
    print -u2 "Pinned libusb build does not have the required relocatable install identity"
    exit 1
fi
library_architectures="$(lipo -archs "$built_library")"
host_architecture="$(uname -m)"
if [[ "$library_architectures" != "$host_architecture" ]]; then
    print -u2 "Pinned libusb architecture '$library_architectures' does not match build host '$host_architecture'"
    exit 1
fi
library_minimum="$(vtool -show-build "$built_library" | awk '$1 == "minos" { print $2; exit }')"
if [[ -z "$library_minimum" || "$library_minimum" != "$deployment_target" ]]; then
    print -u2 "Pinned libusb minimum macOS is '$library_minimum', expected '$deployment_target'"
    exit 1
fi
if otool -L "$built_library" | tail -n +3 | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q .; then
    print -u2 "Pinned libusb build has a non-system transitive dependency"
    otool -L "$built_library" >&2
    exit 1
fi

install -m 755 "$built_library" "$destination/libusb-1.0.dylib"
install -m 644 "$source_root/COPYING" "$destination/COPYING"
print -r -- "$libusb_version" > "$destination/VERSION"
print -r -- "$libusb_source_url" > "$destination/SOURCE_URL"
print -r -- "$libusb_source_sha256" > "$destination/SOURCE_SHA256"

print "Built libusb $libusb_version for macOS $deployment_target ($host_architecture)"
print "Library $destination/libusb-1.0.dylib"
print "Source  $source_archive"
