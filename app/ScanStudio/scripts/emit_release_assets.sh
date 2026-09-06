#!/bin/zsh
# Emit the release metadata assets for a ScanStudio DMG.
#
# Interface:
#   emit_release_assets.sh [-f] <dmg> <version> <outdir> [arch]
#
#   dmg      Absolute path to the built ScanStudio-<version>-macOS-<arch>.dmg
#   version  Full release version string, e.g. 0.3.0-alpha.11
#   outdir   Directory to write assets into (created if missing)
#   arch     Exactly arm64 (default); metadata generation is host-independent.
#
# Writes:
#   SHA256SUMS   one line: "<sha256>  <dmg basename>" (basename only, so the
#                file is portable across machines -- no runner path leaks)
#   latest.json  arch-keyed pointer (per-arch DMG contract, 02-CONTEXT.md):
#                {"version", "architectures": {"<arch>": {"url","sha256"}}}
#
# Exit codes follow package_dmg.sh: 64 bad arguments, 66 missing file,
# 73 refuse-to-overwrite. Never touches the DMG itself.
set -euo pipefail

usage() {
    print -u2 "Usage: emit_release_assets.sh [-f] <dmg> <version> <outdir> [arch]"
}

overwrite=0
while (( $# > 0 )) && [[ "$1" == "-f" ]]; do
    overwrite=1
    shift
done

if (( $# != 3 && $# != 4 )); then
    usage
    exit 64
fi

dmg="$1"
version="$2"
outdir="$3"
arch="${4:-arm64}"

if [[ "$arch" != "arm64" || "${SCANSTUDIO_RELEASE_ARCH:-arm64}" != "arm64" ]]; then
    print -u2 "Bad architecture: $arch (expected Apple Silicon arm64)"
    exit 64
fi

if [[ ! -f "$dmg" ]]; then
    print -u2 "ScanStudio release asset prerequisite missing: $dmg"
    exit 66
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    print -u2 "Bad release version: $version"
    exit 64
fi

if [[ "${dmg:t}" != "ScanStudio-$version-macOS-arm64.dmg" ]]; then
    print -u2 "Release asset must be named ScanStudio-$version-macOS-arm64.dmg"
    exit 64
fi

mkdir -p "$outdir"
outdir="${outdir:A}"

latest_json="$outdir/latest.json"
if [[ -e "$latest_json" && "$overwrite" == 0 ]]; then
    print -u2 "Refusing to overwrite an existing release asset: $latest_json"
    exit 73
fi

sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
if [[ -z "$sha256" ]]; then
    print -u2 "Failed to compute SHA-256 for $dmg"
    exit 1
fi

dmg_basename="${dmg:t}"
tag="v$version"
url="https://github.com/rohanpandula/ScanStudio/releases/download/$tag/$dmg_basename"

printf '%s  %s\n' "$sha256" "$dmg_basename" > "$outdir/SHA256SUMS"
python3 - "$version" "$arch" "$url" "$sha256" "$latest_json" <<'PY'
import json, sys
version, arch, url, sha256, out = sys.argv[1:6]
data = {"version": version, "architectures": {arch: {"url": url, "sha256": sha256}}}
with open(out, "w") as f:
    json.dump(data, f, indent=2)
PY

print "SHA-256 $sha256"
