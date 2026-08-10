#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hasher="$script_dir/../payload-tree-hash.sh"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

bundle="$workdir/ScanStudioWebRuntime.bundle"
mkdir -p "$bundle/Contents/Resources/WebFrontend"
printf 'frontend\n' > "$bundle/Contents/Resources/WebFrontend/index.html"

# Ordinary nested directories have topology-derived link counts (commonly 2
# or greater) and must remain accepted. The output must also be deterministic.
first="$($hasher "$bundle")"
second="$($hasher "$bundle")"
[[ "$first" == "$second" ]]
python3 - "$first" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["fileCount"] == 1
assert value["installedSize"] == len(b"frontend\n")
assert len(value["treeSHA256"]) == 64
PY

ln "$bundle/Contents/Resources/WebFrontend/index.html" \
    "$bundle/Contents/Resources/WebFrontend/hardlink.html"
if "$hasher" "$bundle" >/dev/null 2>&1; then
    printf 'multiply linked regular file unexpectedly passed tree validation\n' >&2
    exit 1
fi

printf 'web runtime directory-link-count regression passed\n'
