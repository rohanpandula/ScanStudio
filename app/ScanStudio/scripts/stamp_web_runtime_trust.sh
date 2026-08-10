#!/bin/zsh
# Stamp the optional runtime trust anchors into a staged Info.plist. This does
# not copy a key file or runtime payload into ScanStudio.app.
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "Usage: stamp_web_runtime_trust.sh <Info.plist>"
    exit 64
fi

plist="$1"
if [[ ! -f "$plist" || -L "$plist" ]]; then
    print -u2 "Info.plist is missing or is not a regular file: $plist"
    exit 66
fi

public_key="${SCANSTUDIO_WEB_RUNTIME_PUBLIC_KEY_PEM:-}"
team_identifier="${SCANSTUDIO_WEB_RUNTIME_TEAM_ID:-}"
public_key_field="ScanStudioWebRuntimeEd25519PublicKey"
team_field="ScanStudioWebRuntimeTeamIdentifier"

if /usr/libexec/PlistBuddy -c "Print :$public_key_field" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Print :$team_field" "$plist" >/dev/null 2>&1; then
    print -u2 "Refusing an Info.plist with pre-existing web runtime trust fields."
    exit 1
fi

if [[ -z "$public_key" && -z "$team_identifier" ]]; then
    print "Optional web runtime trust remains disabled"
    exit 0
fi
if [[ -z "$public_key" || -z "$team_identifier" ]]; then
    print -u2 "Web runtime public key and Team ID must be configured together."
    exit 78
fi
if [[ ! -f "$public_key" || -L "$public_key" ]]; then
    print -u2 "Web runtime Ed25519 public key is missing or linked: $public_key"
    exit 66
fi
if [[ ! "$team_identifier" =~ ^[0-9A-Z]{10}$ ]]; then
    print -u2 "Web runtime Developer ID TeamIdentifier is invalid."
    exit 64
fi
openssl_bin="${OPENSSL_BIN:-}"
openssl_probe="${0:A:h}/../../../ports/web/packaging/macos/require-openssl3.sh"
if [[ ! -x "$openssl_probe" ]]; then
    print -u2 "OpenSSL 3 capability checker is missing: $openssl_probe"
    exit 66
fi
"$openssl_probe" "$openssl_bin" >/dev/null

original_identity="$(/usr/bin/stat -f '%Lp:%u:%g' "$plist")"
original_mode="${original_identity%%:*}"
original_owner="${${original_identity#*:}%%:*}"
if [[ "$original_mode" != "644" || "$original_owner" != "$(id -u)" ]]; then
    print -u2 "Info.plist must be mode 0644 and owned by the packaging user."
    exit 66
fi

temporary_plist="$(mktemp "${plist:h}/.web-runtime-trust.XXXXXX")"
public_der="$(mktemp "${plist:h}/.web-runtime-public.XXXXXX")"
cleanup() {
    rm -f -- "$temporary_plist" "$public_der"
}
trap cleanup EXIT
cp -p "$plist" "$temporary_plist"
if [[ "$(/usr/bin/stat -f '%Lp:%u:%g' "$temporary_plist")" != "$original_identity" ]]; then
    print -u2 "Could not preserve Info.plist mode and ownership in the staged replacement."
    exit 1
fi
"$openssl_bin" pkey -pubin -in "$public_key" -outform DER -out "$public_der"

raw_public_key="$(python3 - "$public_der" <<'PY'
import base64
from pathlib import Path
import sys

der = Path(sys.argv[1]).read_bytes()
prefix = bytes.fromhex("302a300506032b6570032100")
if len(der) != len(prefix) + 32 or not der.startswith(prefix):
    raise SystemExit("public key is not an Ed25519 SubjectPublicKeyInfo value")
print(base64.b64encode(der[len(prefix):]).decode("ascii"))
PY
)"
if [[ -z "$raw_public_key" ]]; then
    print -u2 "Could not derive the raw Ed25519 public key."
    exit 1
fi

/usr/libexec/PlistBuddy \
    -c "Add :$public_key_field string $raw_public_key" "$temporary_plist"
/usr/libexec/PlistBuddy \
    -c "Add :$team_field string $team_identifier" "$temporary_plist"
mv "$temporary_plist" "$plist"
if [[ "$(/usr/bin/stat -f '%Lp:%u:%g' "$plist")" != "$original_identity" ]]; then
    print -u2 "Stamped Info.plist mode or ownership changed unexpectedly."
    exit 1
fi
print "Stamped optional web runtime trust anchors for TeamIdentifier $team_identifier"
