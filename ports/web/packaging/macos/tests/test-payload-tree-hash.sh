#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hasher="$script_dir/../payload-tree-hash.sh"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

make_bundle() {
    local target="$1"

    mkdir -p "$target/Contents/Resources/WebFrontend"
    printf 'frontend\n' > "$target/Contents/Resources/WebFrontend/index.html"
}

bundle="$workdir/ScanStudioWebRuntime.bundle"
make_bundle "$bundle"

# Ordinary nested directories have topology-derived link counts (commonly 2
# or greater) and must remain accepted. The output must also be deterministic.
first="$("$hasher" "$bundle")"
second="$("$hasher" "$bundle")"
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

unreadable_file_bundle="$workdir/unreadable-file/ScanStudioWebRuntime.bundle"
make_bundle "$unreadable_file_bundle"
unreadable_file="$unreadable_file_bundle/Contents/Resources/unreadable.txt"
printf 'not readable\n' > "$unreadable_file"
chmod 000 "$unreadable_file"
unreadable_file_status=0
unreadable_file_output="$("$hasher" "$unreadable_file_bundle" 2>&1)" || \
    unreadable_file_status=$?
chmod 600 "$unreadable_file"
if (( unreadable_file_status == 0 )); then
    printf 'owner-unreadable regular file unexpectedly passed tree validation\n' >&2
    exit 1
fi
if [[ "$unreadable_file_output" != \
    'unsafe runtime file: Contents/Resources/unreadable.txt' ]]; then
    printf 'owner-unreadable regular file returned an unexpected error: %s\n' \
        "$unreadable_file_output" >&2
    exit 1
fi

unreadable_directory_bundle="$workdir/unreadable-directory/ScanStudioWebRuntime.bundle"
make_bundle "$unreadable_directory_bundle"
unreadable_directory="$unreadable_directory_bundle/Contents/Resources/unreadable"
mkdir "$unreadable_directory"
printf 'not reachable\n' > "$unreadable_directory/hidden.txt"
chmod 000 "$unreadable_directory"
unreadable_directory_status=0
unreadable_directory_output="$("$hasher" "$unreadable_directory_bundle" 2>&1)" || \
    unreadable_directory_status=$?
chmod 700 "$unreadable_directory"
if (( unreadable_directory_status == 0 )); then
    printf 'owner-unreadable directory unexpectedly passed tree validation\n' >&2
    exit 1
fi
if [[ "$unreadable_directory_output" != \
    'unsafe runtime directory: Contents/Resources/unreadable' ]]; then
    printf 'owner-unreadable directory returned an unexpected error: %s\n' \
        "$unreadable_directory_output" >&2
    exit 1
fi

printf 'web runtime payload tree safety regressions passed\n'
