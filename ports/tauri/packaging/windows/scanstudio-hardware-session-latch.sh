#!/bin/sh
set -eu

# WSL-side half of Start-ScanStudio-Hardware-Session.ps1. A complete latch is
# published with an atomic, no-clobber hard link so concurrent launchers cannot
# overwrite each other. Release removes only a regular, non-symlink latch whose
# complete token-and-media content still matches this launcher session.

PATH='/usr/bin:/bin'
export PATH
umask 077

usage() {
    printf 'usage: %s {check-orphans|acquire|verify|release} <32-hex-session-token> <media-name-base64>\n' "$0" >&2
    exit 64
}

[ "$#" -eq 3 ] || usage
operation="$1"
session_token="$2"
media_name_base64="$3"

case "$operation" in
    check-orphans|acquire|verify|release) ;;
    *) usage ;;
esac

if ! printf '%s\n' "$session_token" | grep -Eq '^[0-9a-f]{32}$'; then
    printf 'FAIL: session token must be exactly 32 lowercase hexadecimal characters\n' >&2
    exit 64
fi

for required_command in base64 cat chmod cmp grep iconv ln mkdir mktemp rm rmdir tr wc; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'FAIL: required command is unavailable inside WSL: %s\n' "$required_command" >&2
        exit 69
    fi
done

state_dir="${HOME:?HOME is required}/.scanstudio"
case "$state_dir" in
    /*) ;;
    *)
        printf 'FAIL: ScanStudio state directory must be an absolute path: %s\n' "$state_dir" >&2
        exit 73
        ;;
esac
if [ -L "$state_dir" ]; then
    printf 'FAIL: ScanStudio state directory must not be a symbolic link: %s\n' "$state_dir" >&2
    exit 73
fi
if [ -e "$state_dir" ] && [ ! -d "$state_dir" ]; then
    printf 'FAIL: ScanStudio state path is not a directory: %s\n' "$state_dir" >&2
    exit 73
fi
mkdir -p "$state_dir"
chmod 700 "$state_dir"

latch_path="$state_dir/hw-motion-armed"
media_file="$(mktemp "$state_dir/.hw-motion-media.XXXXXX")"
owner_file="$(mktemp "$state_dir/.hw-motion-owner.XXXXXX")"
process_args_file="$(mktemp "$state_dir/.hw-motion-proc-args.XXXXXX")"
operation_lock="$state_dir/.hw-motion-launcher-operation-lock"
published=0
lock_held=0

cleanup() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$published" -eq 1 ] \
        && [ -f "$latch_path" ] && [ ! -L "$latch_path" ] \
        && cmp -s "$latch_path" "$owner_file"; then
        rm -f "$latch_path"
    fi
    rm -f "$media_file" "$owner_file" "$process_args_file"
    if [ "$lock_held" -eq 1 ]; then
        rmdir "$operation_lock" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
chmod 600 "$media_file" "$owner_file" "$process_args_file"

decode_media_name() {
    if printf '%s' "$media_name_base64" | base64 --decode > "$media_file" 2>/dev/null; then
        return 0
    fi
    if printf '%s' "$media_name_base64" | base64 -D > "$media_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

if ! decode_media_name; then
    printf 'FAIL: media name is not valid base64\n' >&2
    exit 64
fi

media_size="$(wc -c < "$media_file" | tr -d '[:space:]')"
if [ "$media_size" -eq 0 ] || [ "$media_size" -gt 2048 ]; then
    printf 'FAIL: media name must be 1..2048 UTF-8 bytes\n' >&2
    exit 64
fi
if ! grep -q '[^[:space:]]' "$media_file"; then
    printf 'FAIL: media name must not be blank\n' >&2
    exit 64
fi
media_line_count="$(wc -l < "$media_file" | tr -d '[:space:]')"
if [ "$media_line_count" -ne 0 ] || LC_ALL=C grep -q '[[:cntrl:]]' "$media_file"; then
    printf 'FAIL: media name must not contain control characters\n' >&2
    exit 64
fi
if ! iconv -f UTF-8 -t UTF-8 "$media_file" >/dev/null 2>&1; then
    printf 'FAIL: media name must be valid UTF-8\n' >&2
    exit 64
fi

{
    printf 'ScanStudio hardware session %s media: ' "$session_token"
    cat "$media_file"
    printf '\n'
} > "$owner_file"
chmod 600 "$owner_file"

owner_size="$(wc -c < "$owner_file" | tr -d '[:space:]')"
if [ "$owner_size" -eq 0 ] || [ "$owner_size" -gt 4096 ]; then
    printf 'FAIL: complete latch must be non-empty and no larger than 4096 bytes\n' >&2
    exit 64
fi

is_owned_latch() {
    [ -f "$latch_path" ] && [ ! -L "$latch_path" ] \
        && cmp -s "$latch_path" "$owner_file"
}

if ! mkdir "$operation_lock" 2>/dev/null; then
    printf 'FAIL: another launcher helper is active, or its operation lock needs inspection: %s\n' "$operation_lock" >&2
    exit 73
fi
lock_held=1
chmod 700 "$operation_lock"

bridge_process_is_running() {
    for process_cmdline in /proc/[0-9]*/cmdline; do
        [ -r "$process_cmdline" ] || continue
        tr '\000' '\n' < "$process_cmdline" > "$process_args_file"
        while IFS= read -r process_argument; do
            case "${process_argument##*/}" in
                scanstudio-bridge)
                    return 0
                    ;;
            esac
            if [ "$process_argument" = 'scanstudio_bridge.cli' ]; then
                return 0
            fi
        done < "$process_args_file"
    done
    return 1
}

case "$operation" in
    check-orphans)
        if bridge_process_is_running; then
            printf 'FAIL: a surviving scanstudio-bridge process exists inside Ubuntu-24.04\n' >&2
            exit 76
        fi
        printf 'No surviving scanstudio-bridge process found\n'
        ;;
    acquire)
        if [ -e "$latch_path" ] || [ -L "$latch_path" ]; then
            printf 'FAIL: a WSL motion latch already exists; no file was changed: %s\n' "$latch_path" >&2
            exit 73
        fi

        # owner_file is complete, UTF-8-valid, mode 0600, and on the same
        # filesystem. link(2) publishes it atomically and refuses every
        # pre-existing target type without a check-then-overwrite race.
        if ! ln "$owner_file" "$latch_path" 2>/dev/null; then
            printf 'FAIL: another session won the motion-latch race; no file was changed\n' >&2
            exit 73
        fi
        published=1
        if ! is_owned_latch; then
            printf 'FAIL: published motion latch did not verify; it was not trusted\n' >&2
            exit 75
        fi
        rm -f "$owner_file"
        published=0
        printf 'WSL motion latch acquired for token %s\n' "$session_token"
        ;;
    verify)
        if ! is_owned_latch; then
            printf 'FAIL: WSL motion latch is absent, unsafe, or owned by another session\n' >&2
            exit 74
        fi
        printf 'WSL motion latch ownership verified for token %s\n' "$session_token"
        ;;
    release)
        if [ ! -e "$latch_path" ] && [ ! -L "$latch_path" ]; then
            printf 'WSL motion latch is already absent\n'
            exit 0
        fi
        if ! is_owned_latch; then
            printf 'FAIL: WSL motion latch is not owned by this session; it was left untouched\n' >&2
            exit 74
        fi
        rm "$latch_path"
        if [ -e "$latch_path" ] || [ -L "$latch_path" ]; then
            printf 'FAIL: owned WSL motion latch could not be removed\n' >&2
            exit 75
        fi
        printf 'WSL motion latch released for token %s\n' "$session_token"
        ;;
esac
