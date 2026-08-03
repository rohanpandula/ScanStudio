#!/bin/zsh
# Emit the release metadata assets for a ScanStudio DMG.
#
# Interface:
#   emit_release_assets.sh [-f] <dmg> <version> <outdir> [arch]
#
#   dmg      Absolute path to the built ScanStudio-<version>-macOS-<arch>.dmg
#   version  Full release version string, e.g. 0.3.0-alpha.11
#   outdir   Directory to write assets into (created if missing)
#   arch     Machine architecture, exactly arm64 or x86_64. Defaults to
#            `uname -m` for backward compatibility with the single-arch calls.
#
# Writes:
#   SHA256SUMS   one line: "<sha256>  <dmg basename>" (basename only, so the
#                file is portable across machines -- no runner path leaks)
#   latest.json  arch-keyed pointer (per-arch DMG contract, 02-CONTEXT.md):
#                {"version", "architectures": {"<arch>": {"url","sha256"}}}
#                Re-invoking with the SAME version and the OTHER architecture
#                MERGES the entry in rather than clobbering the existing one
#                (each release-matrix cell emits one arch; the publish step
#                finalizes the combined pointer this way).
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
arch="${4:-$(uname -m)}"

if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    print -u2 "Bad architecture: $arch (expected arm64 or x86_64)"
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

mkdir -p "$outdir"
outdir="${outdir:A}"

latest_json="$outdir/latest.json"
if [[ -e "$latest_json" && "$overwrite" == 0 ]]; then
    # Refuse to clobber an existing release asset. The one legal exception is
    # merging a DISTINCT arch entry into the same-version arch-keyed pointer
    # (matrix cells each emit one arch; the publish step's second emit merges).
    if ! python3 - "$latest_json" "$version" "$arch" <<'PY'
import json, sys
path, version, arch = sys.argv[1:4]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(1)
if data.get("version") != version:
    sys.exit(2)
arches = data.get("architectures")
if not isinstance(arches, dict) or arch in arches:
    sys.exit(3)
PY
    then
        print -u2 "Refusing to overwrite an existing release asset: $latest_json"
        exit 73
    fi
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
import json, os, sys
version, arch, url, sha256, out = sys.argv[1:6]
data = {}
if os.path.exists(out):
    with open(out) as f:
        data = json.load(f)
data["version"] = version
data.setdefault("architectures", {})[arch] = {"url": url, "sha256": sha256}
with open(out, "w") as f:
    json.dump(data, f, indent=2)
PY

print "SHA-256 $sha256"
