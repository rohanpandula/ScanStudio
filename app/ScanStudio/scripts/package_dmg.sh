#!/bin/zsh
# Create and verify the public ScanStudio DMG without touching scanner state.
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
source_app="${1:-$package_root/.build/ScanStudio.app}"

if [[ ! -d "$source_app" || "${source_app:t}" != "ScanStudio.app" ]]; then
    print -u2 "ScanStudio DMG prerequisite missing or misnamed: $source_app"
    exit 66
fi

info_plist="$source_app/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    print -u2 "ScanStudio DMG prerequisite missing: $info_plist"
    exit 66
fi

"$script_dir/assert_no_web_runtime.sh" "$source_app"

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
release_version="${SCANSTUDIO_RELEASE_VERSION:-$bundle_version-beta.1}"
release_arch="${SCANSTUDIO_RELEASE_ARCH:-$(uname -m)}"
output="${2:-$package_root/.build/ScanStudio-$release_version-macOS-$release_arch.dmg}"

if [[ "${output:e}" != "dmg" || "${output:t}" != ScanStudio-*.dmg ]]; then
    print -u2 "Refusing a DMG output outside the ScanStudio-*.dmg naming contract: $output"
    exit 64
fi
if [[ -e "$output" ]]; then
    print -u2 "Refusing to overwrite an existing release artifact: $output"
    exit 73
fi

codesign --verify --deep --strict "$source_app"
mkdir -p "${output:h}"
output="${output:A}"

# Stage on the destination volume so publishing the verified image is one
# atomic rename. Cleanup is restricted to the exact mktemp directory.
staging_root="$(mktemp -d "${output:h}/.scanstudio-dmg.XXXXXX")"
payload="$staging_root/payload"
temporary_dmg="$staging_root/ScanStudio.dmg"
mount_point="$staging_root/mounted"
mounted=0

cleanup() {
    if (( mounted == 1 )); then
        hdiutil detach "$mount_point" >/dev/null 2>&1 \
            || hdiutil detach -force "$mount_point" >/dev/null 2>&1 \
            || true
    fi
    rm -rf "$staging_root"
}
trap cleanup EXIT

mkdir -p "$payload" "$mount_point"
ditto "$source_app" "$payload/ScanStudio.app"
ln -s /Applications "$payload/Applications"

hdiutil create -quiet \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "ScanStudio $release_version" \
    -srcfolder "$payload" \
    "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null

hdiutil attach -quiet -readonly -nobrowse \
    -mountpoint "$mount_point" "$temporary_dmg"
mounted=1
codesign --verify --deep --strict "$mount_point/ScanStudio.app"
"$script_dir/assert_no_web_runtime.sh" "$mount_point/ScanStudio.app"
if find "$mount_point/ScanStudio.app" -type f \
    \( -name 'fixed_output_lut.bin' -o -name 'resource_tables.json' \) \
    -print -quit | grep -q .; then
    print -u2 "Refusing a release image containing uncleared Nikon builder tables."
    exit 1
fi
"$script_dir/test_packaged_bridge.sh" "$mount_point/ScanStudio.app"
hdiutil detach -quiet "$mount_point"
mounted=0

mv "$temporary_dmg" "$output"
digest="$(shasum -a 256 "$output" | awk '{print $1}')"
print "Packaged $output"
print "SHA-256 $digest"
