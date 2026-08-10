#!/usr/bin/env bash
# Emit the exact canonical manifest consumed by ScanStudio and a raw 64-byte
# Ed25519 signature over those exact UTF-8 bytes.
set -euo pipefail

usage() {
    printf 'Usage: emit-integrity.sh <runtime.dmg> <version> <arm64|x86_64> <payload-summary.json> <private-key.pem> <public-key.pem> <output-dir>\n' >&2
}

if [[ $# -ne 7 ]]; then
    usage
    exit 64
fi

dmg="$1"
version="$2"
arch="$3"
payload_summary="$4"
private_key="$5"
public_key="$6"
output_dir="$7"

if [[ ! -f "$dmg" || -L "$dmg" || ! -f "$payload_summary" || -L "$payload_summary" ]]; then
    printf 'Runtime DMG and inspected payload summary must be regular files.\n' >&2
    exit 66
fi
if [[ ! -f "$private_key" || -L "$private_key" || ! -f "$public_key" || -L "$public_key" ]]; then
    printf 'Ed25519 signing key inputs must be regular, non-symlink files.\n' >&2
    exit 66
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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
openssl_bin="${OPENSSL_BIN:-}"
"$script_dir/require-openssl3.sh" "$openssl_bin" >/dev/null

stem="ScanStudio-WebRuntime-$version-macOS-$arch"
if [[ "$(basename "$dmg")" != "$stem.dmg" ]]; then
    printf 'Runtime DMG name does not match its version/architecture contract.\n' >&2
    exit 64
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
manifest="$output_dir/$stem.json"
signature="$manifest.sig"
if [[ -e "$manifest" || -L "$manifest" || -e "$signature" || -L "$signature" ]]; then
    printf 'Refusing to overwrite existing runtime integrity assets.\n' >&2
    exit 73
fi

workdir="$(mktemp -d "$output_dir/.runtime-integrity.XXXXXX")"
trap 'rm -rf -- "$workdir"' EXIT
temporary_manifest="$workdir/$stem.json"
temporary_signature="$temporary_manifest.sig"

python3 - \
    "$dmg" "$version" "$arch" "$payload_summary" "$temporary_manifest" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

dmg = Path(sys.argv[1])
version = sys.argv[2]
architecture = sys.argv[3]
summary_path = Path(sys.argv[4])
output = Path(sys.argv[5])


def strict_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise SystemExit(f"duplicate payload summary key: {key}")
        value[key] = item
    return value


summary = json.loads(summary_path.read_text(), object_pairs_hook=strict_object)
expected_keys = {
    "bundleName", "bundleIdentifier", "teamIdentifier", "developerIDSigned",
    "notarized", "executableRelativePath", "staticDirectoryRelativePath",
    "fileCount", "installedSize", "treeSHA256",
}
if not isinstance(summary, dict) or set(summary) != expected_keys:
    raise SystemExit("payload summary keys do not match the signed manifest contract")
if summary["bundleName"] != "ScanStudioWebRuntime.bundle":
    raise SystemExit("unexpected runtime bundle name")
if summary["bundleIdentifier"] != "dev.scanstudio.live.web-runtime":
    raise SystemExit("unexpected runtime bundle identifier")
team_identifier = summary["teamIdentifier"]
if (not isinstance(team_identifier, str) or len(team_identifier) != 10
        or not team_identifier.isascii() or not team_identifier.isalnum()
        or team_identifier != team_identifier.upper()):
    raise SystemExit("invalid Developer ID team identifier")
if summary["developerIDSigned"] is not True or summary["notarized"] is not True:
    raise SystemExit("runtime manifest cannot advertise non-production code trust")
if summary["executableRelativePath"] != "Contents/MacOS/scanstudio-web-runtime":
    raise SystemExit("unexpected runtime executable path")
if summary["staticDirectoryRelativePath"] != "Contents/Resources/WebFrontend":
    raise SystemExit("unexpected runtime static directory path")
if (not isinstance(summary["fileCount"], int)
        or isinstance(summary["fileCount"], bool)
        or not 0 < summary["fileCount"] <= 100_000):
    raise SystemExit("invalid runtime file count")
if (not isinstance(summary["installedSize"], int)
        or isinstance(summary["installedSize"], bool)
        or not 0 < summary["installedSize"] <= 8 * 1024 * 1024 * 1024):
    raise SystemExit("invalid runtime installed size")
tree_digest = summary["treeSHA256"]
if not isinstance(tree_digest, str) or len(tree_digest) != 64 or any(c not in "0123456789abcdef" for c in tree_digest):
    raise SystemExit("invalid runtime tree SHA-256")

artifact_digest = hashlib.sha256()
with dmg.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        artifact_digest.update(chunk)
size = dmg.stat().st_size
if not 0 < size <= 1024 * 1024 * 1024:
    raise SystemExit("runtime DMG is empty or exceeds the host download limit")
name = dmg.name
repository = "rohanpandula/ScanStudio"
tag = f"v{version}"
manifest = {
    "schemaVersion": 1,
    "repository": repository,
    "tag": tag,
    "hostVersion": version,
    "runtimeVersion": version,
    "platform": "macos",
    "architecture": architecture,
    "protocolVersion": 1,
    "asset": {
        "name": name,
        "url": f"https://github.com/{repository}/releases/download/{tag}/{name}",
        "size": size,
        "sha256": artifact_digest.hexdigest(),
    },
    "payload": summary,
}
output.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
if output.stat().st_size > 65_536:
    raise SystemExit("runtime manifest exceeds the host download limit")
PY

"$openssl_bin" pkeyutl -sign -rawin \
    -inkey "$private_key" \
    -in "$temporary_manifest" \
    -out "$temporary_signature"
if [[ "$(wc -c < "$temporary_signature" | tr -d ' ')" != 64 ]]; then
    printf 'Ed25519 signature is not the required raw 64-byte representation.\n' >&2
    exit 1
fi
"$openssl_bin" pkeyutl -verify -rawin -pubin \
    -inkey "$public_key" \
    -in "$temporary_manifest" \
    -sigfile "$temporary_signature" >/dev/null

chmod 644 "$temporary_manifest" "$temporary_signature"
mv "$temporary_manifest" "$manifest"
mv "$temporary_signature" "$signature"
printf 'Emitted %s and raw Ed25519 signature %s\n' "$manifest" "$signature"
