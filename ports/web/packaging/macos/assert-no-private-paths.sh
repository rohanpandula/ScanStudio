#!/usr/bin/env bash
# Fail closed unless every readable payload byte is free of local build roots.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: assert-no-private-paths.sh <runtime-root>\n' >&2
    exit 64
fi

root="$1"
if [[ ! -d "$root" || -L "$root" ]]; then
    printf 'Private-path scan root is missing or linked: %s\n' "$root" >&2
    exit 66
fi

user_home_pattern="/"'Users/'
temporary_root_pattern="/var/"'folders/'
private_temporary_root_pattern="/private/var/"'folders/'
private_path_matches=""
if private_path_matches="$(
    grep -rEl \
        "${user_home_pattern}|${temporary_root_pattern}|${private_temporary_root_pattern}" \
        "$root"
)"; then
    printf 'Runtime contains a developer or temporary build path:\n%s\n' \
        "$private_path_matches" >&2
    exit 1
else
    grep_status=$?
    if [[ "$grep_status" -ne 1 ]]; then
        printf 'Could not scan every runtime file for private build paths.\n' >&2
        exit "$grep_status"
    fi
fi
