#!/bin/bash
set -euo pipefail

app="/Applications/ScanStudio.app"
prefix=""
name="scanstudio"
uninstall=0
prefix_explicit=0

usage() {
    cat <<'EOF'
Usage: install_cli_shim.sh [--app PATH] [--prefix DIR] [--name NAME] [--uninstall]

Install a user-local executable shim for ScanStudio's bundled CLI without elevation or symlinks.
EOF
}

while (($#)); do
    case "$1" in
        --app) [[ $# -ge 2 ]] || { echo "--app needs a path" >&2; exit 64; }; app=$2; shift 2 ;;
        --prefix) [[ $# -ge 2 ]] || { echo "--prefix needs a directory" >&2; exit 64; }; prefix=$2; prefix_explicit=1; shift 2 ;;
        --name) [[ $# -ge 2 ]] || { echo "--name needs a name" >&2; exit 64; }; name=$2; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[[ "$name" != */* && -n "$name" ]] || { echo "--name must be a simple executable name" >&2; exit 64; }
if [[ -z "$prefix" ]]; then
    if [[ -d "${HOME:-}/.local/bin" ]]; then prefix="$HOME/.local/bin"
    elif [[ -d "${HOME:-}/bin" ]]; then prefix="$HOME/bin"
    else prefix="$HOME/.local/bin"; fi
else
    prefix_explicit=1
fi
[[ "$prefix" = /* ]] || { echo "--prefix must be an absolute path" >&2; exit 64; }
if (( !prefix_explicit )) && [[ "$prefix" != "$HOME"/* ]]; then
    echo "default prefix must be inside HOME; pass --prefix explicitly to choose another path" >&2
    exit 64
fi
[[ ! -L "$prefix" ]] || { echo "refusing symlink prefix: $prefix" >&2; exit 1; }
target="$prefix/$name"
marker="# scanstudio-cli shim installed by scripts/install_cli_shim.sh"

if (( uninstall )); then
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        echo "nothing to remove: $target"
        exit 0
    fi
    [[ ! -L "$target" ]] || { echo "refusing to remove symlink: $target" >&2; exit 1; }
    grep -Fqx "$marker" "$target" 2>/dev/null || { echo "refusing to remove unowned file: $target" >&2; exit 1; }
    rm "$target"
    echo "removed $target"
    exit 0
fi

mkdir -p "$prefix"
app_input="$app"
app="$(cd "$app_input" 2>/dev/null && pwd -P)" || { echo "app not found: $app_input" >&2; exit 1; }
cli="$app/Contents/MacOS/scanstudio-cli"
if [[ ! -x "$cli" ]]; then
    echo "missing executable: $cli" >&2
    exit 1
fi
quoted_cli=${cli//\'/\'\\\'\'}
expected_line="exec '$quoted_cli' \"\$@\""

if [[ -L "$target" ]]; then
    echo "refusing to overwrite symlink: $target" >&2
    exit 1
fi
if [[ -e "$target" ]]; then
    grep -Fqx "$marker" "$target" 2>/dev/null || { echo "refusing to overwrite unowned file: $target" >&2; exit 1; }
    [[ "$(tail -n 1 "$target")" == "$expected_line" ]] || { echo "refusing to replace an owned shim for another app: $target" >&2; exit 1; }
    echo "already installed: $target"; exit 0
fi

temporary="$(mktemp "$prefix/.scanstudio-cli.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
printf '%s\n' '#!/bin/sh' "$marker" "$expected_line" >"$temporary"
chmod 0755 "$temporary"
mv "$temporary" "$target"
trap - EXIT
echo "installed $target"
case ":${PATH:-}:" in *:"$prefix":*) ;; *) echo "warning: $prefix is not on PATH" >&2 ;; esac
