#!/usr/bin/env bash
# Final macOS verification: detached signature/hash, notarized DMG, exact
# mounted payload contents, Developer ID identity, and cache-compatible tree.
set -euo pipefail

usage() {
    printf 'Usage: verify-runtime-release.sh <runtime.dmg> <manifest.json> <manifest.json.sig> <public-key.pem> <version> <arm64|x86_64> <team-id>\n' >&2
}

if [[ $# -ne 7 ]]; then
    usage
    exit 64
fi

dmg="$1"
manifest="$2"
signature="$3"
public_key="$4"
version="$5"
arch="$6"
team_id="$7"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$script_dir/verify-integrity.sh" \
    "$dmg" "$manifest" "$signature" "$public_key" "$version" "$arch"

workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT
summary="$workdir/payload.json"
"$script_dir/inspect-runtime-dmg.sh" \
    "$dmg" "$version" "$arch" "$team_id" "$summary"

python3 -I -S - "$manifest" "$summary" <<'PY'
import json
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text())
summary = json.loads(Path(sys.argv[2]).read_text())
if manifest["payload"] != summary:
    raise SystemExit("signed runtime payload summary does not match the mounted notarized DMG")
print("signed manifest payload exactly matches mounted notarized runtime tree")
PY
