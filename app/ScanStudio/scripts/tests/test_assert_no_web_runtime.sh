#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assertion="$script_dir/../assert_no_web_runtime.sh"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

app="$workdir/ScanStudio.app"
mkdir -p "$app/Contents/Resources"
"$assertion" "$app" >/dev/null

mkdir -p "$app/Contents/Resources/Nested/WebRuntime"
if "$assertion" "$app" >/dev/null 2>&1; then
    printf 'expected nested WebRuntime directory to be rejected\n' >&2
    exit 1
fi
rm -r "$app/Contents/Resources/Nested"

ln -s "$workdir/missing" "$app/Contents/WebFrontend"
if "$assertion" "$app" >/dev/null 2>&1; then
    printf 'expected dangling WebFrontend symlink to be rejected\n' >&2
    exit 1
fi
rm "$app/Contents/WebFrontend"

printf 'marker\n' > "$app/Contents/Resources/scanstudio-web-runtime.json"
if "$assertion" "$app" >/dev/null 2>&1; then
    printf 'expected runtime marker file to be rejected\n' >&2
    exit 1
fi

printf 'optional web payload non-bundling checks passed\n'
