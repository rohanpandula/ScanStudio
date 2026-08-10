#!/usr/bin/env bash
# Cross-platform verification of the exact signed release-manifest contract.
set -euo pipefail

usage() {
    printf 'Usage: verify-integrity.sh <runtime.dmg> <manifest.json> <manifest.json.sig> <public-key.pem> <version> <arm64|x86_64>\n' >&2
}

if [[ $# -ne 6 ]]; then
    usage
    exit 64
fi

dmg="$1"
manifest="$2"
signature="$3"
public_key="$4"
version="$5"
arch="$6"

if (( ${#version} > 96 )) \
    || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)?)?$ ]]; then
    printf 'Bad release version: %s\n' "$version" >&2
    exit 64
fi
if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    printf 'Bad architecture: %s\n' "$arch" >&2
    exit 64
fi

for path in "$dmg" "$manifest" "$signature" "$public_key"; do
    if [[ ! -f "$path" || -L "$path" ]]; then
        printf 'Integrity input is missing or is not a regular file: %s\n' "$path" >&2
        exit 66
    fi
done
if [[ "$(wc -c < "$signature" | tr -d ' ')" != 64 ]]; then
    printf 'Runtime manifest signature must be exactly 64 raw bytes.\n' >&2
    exit 1
fi
manifest_size="$(wc -c < "$manifest" | tr -d ' ')"
if [[ "$manifest_size" -le 0 || "$manifest_size" -gt 65536 ]]; then
    printf 'Runtime manifest must contain 1-65536 bytes.\n' >&2
    exit 1
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
openssl_bin="${OPENSSL_BIN:-}"
"$script_dir/require-openssl3.sh" "$openssl_bin" >/dev/null

# Authenticate exact bytes before interpreting any path, URL, size, or hash.
"$openssl_bin" pkeyutl -verify -rawin -pubin \
    -inkey "$public_key" \
    -in "$manifest" \
    -sigfile "$signature" >/dev/null

python3 - "$dmg" "$manifest" "$version" "$arch" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

dmg = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
version = sys.argv[3]
architecture = sys.argv[4]
raw = manifest_path.read_bytes()


def strict_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise SystemExit(f"duplicate manifest key: {key}")
        value[key] = item
    return value


try:
    manifest = json.loads(raw, object_pairs_hook=strict_object)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"malformed runtime manifest: {error}") from error
canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode() + b"\n"
if raw != canonical:
    raise SystemExit("runtime manifest is not canonical compact sorted JSON plus LF")
root_keys = {
    "schemaVersion", "repository", "tag", "hostVersion", "runtimeVersion",
    "platform", "architecture", "protocolVersion", "asset", "payload",
}
asset_keys = {"name", "url", "size", "sha256"}
payload_keys = {
    "bundleName", "bundleIdentifier", "teamIdentifier", "developerIDSigned",
    "notarized", "executableRelativePath", "staticDirectoryRelativePath",
    "fileCount", "installedSize", "treeSHA256",
}
if not isinstance(manifest, dict) or set(manifest) != root_keys:
    raise SystemExit("runtime manifest root keys do not match the exact schema")
if not isinstance(manifest["asset"], dict) or set(manifest["asset"]) != asset_keys:
    raise SystemExit("runtime manifest asset keys do not match the exact schema")
if not isinstance(manifest["payload"], dict) or set(manifest["payload"]) != payload_keys:
    raise SystemExit("runtime manifest payload keys do not match the exact schema")

stem = f"ScanStudio-WebRuntime-{version}-macOS-{architecture}"
name = f"{stem}.dmg"
tag = f"v{version}"
expected_url = f"https://github.com/rohanpandula/ScanStudio/releases/download/{tag}/{name}"
expected_scalars = {
    "schemaVersion": 1,
    "repository": "rohanpandula/ScanStudio",
    "tag": tag,
    "hostVersion": version,
    "runtimeVersion": version,
    "platform": "macos",
    "architecture": architecture,
    "protocolVersion": 1,
}
for key, expected in expected_scalars.items():
    if manifest[key] != expected or isinstance(manifest[key], bool) and isinstance(expected, int):
        raise SystemExit(f"runtime manifest {key} mismatch")
if dmg.name != name or manifest["asset"]["name"] != name:
    raise SystemExit("runtime DMG name mismatch")
if manifest["asset"]["url"] != expected_url:
    raise SystemExit("runtime asset URL mismatch")
if not isinstance(manifest["asset"]["size"], int) or isinstance(manifest["asset"]["size"], bool):
    raise SystemExit("runtime asset size is not an integer")
if (manifest["asset"]["size"] != dmg.stat().st_size
        or not 0 < dmg.stat().st_size <= 1024 * 1024 * 1024):
    raise SystemExit("runtime asset size mismatch")
digest = hashlib.sha256()
with dmg.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
if manifest["asset"]["sha256"] != digest.hexdigest():
    raise SystemExit("runtime asset SHA-256 mismatch")

payload = manifest["payload"]
if payload["bundleName"] != "ScanStudioWebRuntime.bundle":
    raise SystemExit("runtime bundle name mismatch")
if payload["bundleIdentifier"] != "dev.scanstudio.live.web-runtime":
    raise SystemExit("runtime bundle identifier mismatch")
team = payload["teamIdentifier"]
if not isinstance(team, str) or len(team) != 10 or not team.isalnum() or team != team.upper():
    raise SystemExit("runtime TeamIdentifier is invalid")
if payload["developerIDSigned"] is not True or payload["notarized"] is not True:
    raise SystemExit("runtime production trust flags are not both true")
if payload["executableRelativePath"] != "Contents/MacOS/scanstudio-web-runtime":
    raise SystemExit("runtime executable path mismatch")
if payload["staticDirectoryRelativePath"] != "Contents/Resources/WebFrontend":
    raise SystemExit("runtime static directory path mismatch")
if (not isinstance(payload["fileCount"], int)
        or isinstance(payload["fileCount"], bool)
        or not 0 < payload["fileCount"] <= 100_000):
    raise SystemExit("runtime fileCount is invalid")
if (not isinstance(payload["installedSize"], int)
        or isinstance(payload["installedSize"], bool)
        or not 0 < payload["installedSize"] <= 8 * 1024 * 1024 * 1024):
    raise SystemExit("runtime installedSize is invalid")
tree = payload["treeSHA256"]
if not isinstance(tree, str) or len(tree) != 64 or any(c not in "0123456789abcdef" for c in tree):
    raise SystemExit("runtime tree SHA-256 is invalid")
print("raw Ed25519 signature and exact runtime manifest verified")
PY
