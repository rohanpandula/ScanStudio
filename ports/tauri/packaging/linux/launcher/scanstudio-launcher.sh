#!/usr/bin/env bash
set -euo pipefail

# Linux bridge launcher — port of the macOS ScanStudioLauncher. Resolves the
# hardware bridge command in the same four-step order, adapted to Linux paths:
#   (1) SCANSTUDIO_BRIDGE_CMD env var
#   (2) one-line config file at ~/.config/scanstudio/bridge-command
#   (3) the bundled helper `scanstudio-bridge` next to this script
#   (4) PATH via `command -v`
# This launcher only selects a command. It never enables motion and never
# reads, creates, or changes the bridge's armed latch.

launcher_dir="$(cd "$(dirname "$0")" && pwd)"
config_file=""
config_hint='~/.config/scanstudio/bridge-command'
if [[ -n "${HOME:-}" ]]; then
    config_file="$HOME/.config/scanstudio/bridge-command"
fi
bridge_cmd="${SCANSTUDIO_BRIDGE_CMD:-}"
bridge_source=""

# `bridge-command` is a literal bridge command (path plus optional arguments),
# not shell code, and is passed to the engine unchanged.
if [[ -n "${bridge_cmd//[[:space:]]/}" ]]; then
    bridge_source="SCANSTUDIO_BRIDGE_CMD"
elif [[ -n "$config_file" && -r "$config_file" ]]; then
    IFS= read -r bridge_cmd < "$config_file" || true
    if [[ -n "${bridge_cmd//[[:space:]]/}" ]]; then
        bridge_source="$config_file"
    fi
fi

if [[ -z "${bridge_cmd//[[:space:]]/}" ]]; then
    bundled_bridge="$launcher_dir/scanstudio-bridge"
    if [[ -x "$bundled_bridge" ]]; then
        # Keep the command token free of the install directory's path so
        # moving the app tree never breaks the engine's command resolution.
        export PATH="$launcher_dir${PATH:+:$PATH}"
        bridge_cmd="scanstudio-bridge"
        bridge_source="bundled helper"
    fi
fi

if [[ -z "${bridge_cmd//[[:space:]]/}" ]]; then
    bridge_cmd="$(command -v scanstudio-bridge 2>/dev/null || true)"
    if [[ -n "$bridge_cmd" ]]; then
        bridge_source="PATH"
    fi
fi

if [[ -n "${bridge_cmd//[[:space:]]/}" ]]; then
    export SCANSTUDIO_BRIDGE_CMD="$bridge_cmd"
    printf 'ScanStudio: hardware bridge configured from %s.\n' "$bridge_source" >&2
else
    unset SCANSTUDIO_BRIDGE_CMD || true
    printf 'ScanStudio: no hardware bridge found; launching simulator-only. Set SCANSTUDIO_BRIDGE_CMD, add a command to %s, install scanstudio-bridge on PATH, or use a bundle with its helper included.\n' "$config_hint" >&2
fi

# Resolve the application binary for both the portable tree and the location
# Tauri gives this resource inside an extracted AppImage. SCANSTUDIO_APP_BIN
# is an integration override, not shell code.
app_bin="${SCANSTUDIO_APP_BIN:-}"
if [[ -z "$app_bin" ]]; then
    for candidate in \
        "$launcher_dir/ScanStudio" \
        "$launcher_dir/scanstudio-app" \
        "$launcher_dir/../../bin/scanstudio-app" \
        "${APPDIR:-}/usr/bin/scanstudio-app"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            app_bin="$candidate"
            break
        fi
    done
fi
if [[ -z "$app_bin" || ! -x "$app_bin" ]]; then
    printf 'ScanStudio: application binary not found next to the launcher or under the AppImage tree.\n' >&2
    exit 78
fi

# Do not arm motion here. A real bridge still requires the operator's explicit
# SCANSTUDIO_HW_MOTION=1 plus its own pre-existing non-empty armed latch before
# it moves. In particular, this launcher neither creates nor modifies that latch.
exec "$app_bin"
