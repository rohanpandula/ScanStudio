#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
packaging_dir="$(cd "$script_dir/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

version='1.2.3-beta.4'
arch='arm64'
stem="ScanStudio-WebRuntime-$version-macOS-$arch"
dmg="$workdir/$stem.dmg"
private_key="$workdir/private.pem"
public_key="$workdir/public.pem"
summary="$workdir/summary.json"
output_dir="$workdir/output"
openssl_bin="${OPENSSL_BIN:-}"
"$packaging_dir/require-openssl3.sh" "$openssl_bin" >/dev/null

printf 'synthetic runtime image bytes\n' > "$dmg"
"$openssl_bin" genpkey -algorithm Ed25519 -out "$private_key" >/dev/null 2>&1
"$openssl_bin" pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
cat > "$summary" <<'JSON'
{"bundleIdentifier":"dev.scanstudio.live.web-runtime","bundleName":"ScanStudioWebRuntime.bundle","developerIDSigned":true,"executableRelativePath":"Contents/MacOS/scanstudio-web-runtime","fileCount":12,"installedSize":3456,"notarized":true,"staticDirectoryRelativePath":"Contents/Resources/WebFrontend","teamIdentifier":"ABCDE12345","treeSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON

"$packaging_dir/emit-integrity.sh" \
    "$dmg" "$version" "$arch" "$summary" \
    "$private_key" "$public_key" "$output_dir" >/dev/null
manifest="$output_dir/$stem.json"
signature="$manifest.sig"
"$packaging_dir/verify-integrity.sh" \
    "$dmg" "$manifest" "$signature" "$public_key" "$version" "$arch" >/dev/null
if [[ "$(wc -c < "$signature" | tr -d ' ')" != 64 ]]; then
    printf 'signature was not raw Ed25519 bytes\n' >&2
    exit 1
fi

cp "$dmg" "$workdir/original.dmg"
printf 'tamper\n' >> "$dmg"
if "$packaging_dir/verify-integrity.sh" \
    "$dmg" "$manifest" "$signature" "$public_key" "$version" "$arch" \
    >/dev/null 2>&1; then
    printf 'tampered DMG unexpectedly verified\n' >&2
    exit 1
fi
cp "$workdir/original.dmg" "$dmg"

cp "$manifest" "$workdir/original.json"
printf ' ' >> "$manifest"
if "$packaging_dir/verify-integrity.sh" \
    "$dmg" "$manifest" "$signature" "$public_key" "$version" "$arch" \
    >/dev/null 2>&1; then
    printf 'tampered manifest unexpectedly verified\n' >&2
    exit 1
fi
cp "$workdir/original.json" "$manifest"

"$openssl_bin" genpkey -algorithm Ed25519 -out "$workdir/wrong-private.pem" >/dev/null 2>&1
"$openssl_bin" pkey -in "$workdir/wrong-private.pem" -pubout \
    -out "$workdir/wrong-public.pem" >/dev/null 2>&1
if "$packaging_dir/verify-integrity.sh" \
    "$dmg" "$manifest" "$signature" "$workdir/wrong-public.pem" "$version" "$arch" \
    >/dev/null 2>&1; then
    printf 'wrong Ed25519 key unexpectedly verified\n' >&2
    exit 1
fi

if "$packaging_dir/emit-integrity.sh" \
    "$dmg" "$version" "$arch" "$summary" \
    "$private_key" "$public_key" "$output_dir" >/dev/null 2>&1; then
    printf 'integrity emitter unexpectedly overwrote existing assets\n' >&2
    exit 1
fi

python3 - "$summary" "$workdir/too-many-files.json" <<'PY'
import json
from pathlib import Path
import sys

value = json.loads(Path(sys.argv[1]).read_text())
value["fileCount"] = 100_001
Path(sys.argv[2]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
if "$packaging_dir/emit-integrity.sh" \
    "$dmg" "$version" "$arch" "$workdir/too-many-files.json" \
    "$private_key" "$public_key" "$workdir/oversized-output" \
    >/dev/null 2>&1; then
    printf 'host-incompatible payload bounds unexpectedly produced a manifest\n' >&2
    exit 1
fi

printf 'web runtime raw-signature integrity checks passed\n'
