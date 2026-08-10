#!/usr/bin/env bash
# Sign a statically validated unsigned runtime payload without executing it.
set -euo pipefail

usage() {
    printf 'Usage: sign-runtime.sh <prepared-bundle> <unsigned.dmg> <assembly.json> <version> <arm64|x86_64> <output-dir> <Developer ID Application identity> <keychain>\n' >&2
}

if [[ $# -ne 8 ]]; then
    usage
    exit 64
fi

bundle="$1"
unsigned_dmg="$2"
assembly_receipt="$3"
version="$4"
arch="$5"
output_dir="$6"
codesign_identity="$7"
keychain="$8"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'The macOS web runtime must be signed on macOS.\n' >&2
    exit 69
fi
if (( ${#version} > 96 )) \
    || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)?)?$ ]]; then
    printf 'Bad release version: %s\n' "$version" >&2
    exit 64
fi
if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    printf 'Bad architecture: %s\n' "$arch" >&2
    exit 64
fi
if [[ "$(uname -m)" != "$arch" ]]; then
    printf 'Refusing a non-native runtime signature: requested %s on %s.\n' \
        "$arch" "$(uname -m)" >&2
    exit 64
fi
if [[ "$codesign_identity" != 'Developer ID Application: '* ]]; then
    printf 'A Developer ID Application identity is mandatory.\n' >&2
    exit 78
fi
if [[ ! -d "$bundle" || -L "$bundle" \
      || "$(basename "$bundle")" != 'ScanStudioWebRuntime.bundle' ]]; then
    printf 'Prepared runtime bundle is missing, linked, or misnamed.\n' >&2
    exit 66
fi
if [[ ! -f "$keychain" || -L "$keychain" ]]; then
    printf 'Release keychain is missing or linked.\n' >&2
    exit 66
fi

for command in codesign file hdiutil lipo shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required signing tool is unavailable: %s\n' "$command" >&2
        exit 127
    fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stem="ScanStudio-WebRuntime-$version-macOS-$arch"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
output="$output_dir/$stem.dmg"
if [[ -e "$output" || -L "$output" ]]; then
    printf 'Refusing to overwrite an existing signed runtime: %s\n' "$output" >&2
    exit 73
fi

workdir="$(mktemp -d "$output_dir/.runtime-sign.XXXXXX")"
payload_root="$workdir/payload"
temporary_dmg="$workdir/$stem.dmg"
mount_point="$workdir/mounted"
mkdir -p "$payload_root" "$mount_point"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 \
            || hdiutil detach -force "$mount_point" >/dev/null 2>&1 \
            || true
    fi
    rm -rf -- "$workdir"
}
trap cleanup EXIT

# Re-bind the prepared tree to the pre-secret assembly receipt immediately
# before the first signature. These readers hash bytes and metadata only.
prepared_tree="$workdir/prepared-tree.json"
"$script_dir/payload-tree-hash.sh" "$bundle" > "$prepared_tree"
python3 -I -S "$script_dir/runtime-assembly-receipt.py" verify \
    "$unsigned_dmg" "$version" "$arch" "$prepared_tree" "$assembly_receipt"

mv "$bundle" "$payload_root/ScanStudioWebRuntime.bundle"
bundle="$payload_root/ScanStudioWebRuntime.bundle"
contents="$bundle/Contents"

while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$contents/MacOS/scanstudio-web-runtime" ]] && continue
    if file -b "$candidate" | grep -q 'Mach-O'; then
        codesign --force --options runtime --timestamp \
            --keychain "$keychain" --sign "$codesign_identity" "$candidate"
        codesign --verify --strict "$candidate"
        if [[ "$(lipo -archs "$candidate")" != "$arch" ]]; then
            printf 'Nested runtime architecture mismatch: %s\n' "$candidate" >&2
            exit 1
        fi
    fi
done < <(find "$bundle" -type f -print0)
codesign --force --options runtime --timestamp \
    --keychain "$keychain" \
    --identifier 'dev.scanstudio.live.web-runtime' \
    --sign "$codesign_identity" \
    "$contents/MacOS/scanstudio-web-runtime"
codesign --force --options runtime --timestamp \
    --keychain "$keychain" --sign "$codesign_identity" "$bundle"
codesign --verify --deep --strict "$bundle"

hdiutil create -quiet \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "ScanStudio Web Runtime $version" \
    -srcfolder "$payload_root" \
    "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null
hdiutil attach -quiet -readonly -noautoopen -nobrowse \
    -mountpoint "$mount_point" "$temporary_dmg"
mounted=1
if [[ ! -d "$mount_point/ScanStudioWebRuntime.bundle" ]]; then
    printf 'Mounted signed runtime image does not contain the expected bundle.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$mount_point/ScanStudioWebRuntime.bundle"
hdiutil detach -quiet "$mount_point"
mounted=0

codesign --force --timestamp --keychain "$keychain" \
    --sign "$codesign_identity" "$temporary_dmg"
codesign --verify --strict "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null
mv "$temporary_dmg" "$output"

printf 'Signed %s\n' "$output"
printf 'SHA-256 %s\n' "$(shasum -a 256 "$output" | awk '{print $1}')"
printf 'Notarization and stapling are still required before manifest emission.\n'
