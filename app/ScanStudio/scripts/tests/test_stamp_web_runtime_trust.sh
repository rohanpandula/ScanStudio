#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'stamp trust test requires macOS\n' >&2
    exit 69
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stamper="$script_dir/../stamp_web_runtime_trust.sh"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT
openssl_bin="${OPENSSL_BIN:-}"
"$script_dir/../../../../ports/web/packaging/macos/require-openssl3.sh" \
    "$openssl_bin" >/dev/null

make_plist() {
    cat > "$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.scanstudio.live</string></dict></plist>
PLIST
}

plain="$workdir/plain.plist"
make_plist "$plain"
env -u SCANSTUDIO_WEB_RUNTIME_PUBLIC_KEY_PEM \
    -u SCANSTUDIO_WEB_RUNTIME_TEAM_ID \
    "$stamper" "$plain" >/dev/null
if /usr/libexec/PlistBuddy -c 'Print :ScanStudioWebRuntimeEd25519PublicKey' \
    "$plain" >/dev/null 2>&1; then
    printf 'default stamping unexpectedly added a trust key\n' >&2
    exit 1
fi

"$openssl_bin" genpkey -algorithm Ed25519 -out "$workdir/private.pem" >/dev/null 2>&1
"$openssl_bin" pkey -in "$workdir/private.pem" -pubout \
    -out "$workdir/public.pem" >/dev/null 2>&1
stamped="$workdir/stamped.plist"
make_plist "$stamped"
chmod 0644 "$stamped"
original_identity="$(/usr/bin/stat -f '%Lp:%u:%g' "$stamped")"
SCANSTUDIO_WEB_RUNTIME_PUBLIC_KEY_PEM="$workdir/public.pem" \
SCANSTUDIO_WEB_RUNTIME_TEAM_ID='ABCDE12345' \
    "$stamper" "$stamped" >/dev/null
raw="$(/usr/libexec/PlistBuddy \
    -c 'Print :ScanStudioWebRuntimeEd25519PublicKey' "$stamped")"
team="$(/usr/libexec/PlistBuddy \
    -c 'Print :ScanStudioWebRuntimeTeamIdentifier' "$stamped")"
[[ "$team" == 'ABCDE12345' ]]
if [[ "$(/usr/bin/stat -f '%Lp:%u:%g' "$stamped")" != "$original_identity" ]]; then
    printf 'stamper changed Info.plist mode or ownership\n' >&2
    exit 1
fi
python3 - "$raw" <<'PY'
import base64, sys
assert len(base64.b64decode(sys.argv[1], validate=True)) == 32
PY

if SCANSTUDIO_WEB_RUNTIME_PUBLIC_KEY_PEM="$workdir/public.pem" \
   SCANSTUDIO_WEB_RUNTIME_TEAM_ID='ABCDE12345' \
   "$stamper" "$stamped" >/dev/null 2>&1; then
    printf 'stamper unexpectedly overwrote existing trust fields\n' >&2
    exit 1
fi

partial="$workdir/partial.plist"
make_plist "$partial"
if SCANSTUDIO_WEB_RUNTIME_TEAM_ID='ABCDE12345' \
   "$stamper" "$partial" >/dev/null 2>&1; then
    printf 'partial trust configuration unexpectedly succeeded\n' >&2
    exit 1
fi

unsafe_mode="$workdir/unsafe-mode.plist"
make_plist "$unsafe_mode"
chmod 0600 "$unsafe_mode"
if SCANSTUDIO_WEB_RUNTIME_PUBLIC_KEY_PEM="$workdir/public.pem" \
   SCANSTUDIO_WEB_RUNTIME_TEAM_ID='ABCDE12345' \
   "$stamper" "$unsafe_mode" >/dev/null 2>&1; then
    printf 'stamper unexpectedly replaced an Info.plist with unsafe mode\n' >&2
    exit 1
fi

printf 'optional web runtime trust-stamp checks passed\n'
