#!/bin/zsh
# Portable black-box checks for the packaged launcher. Uses a temporary app
# shell and never starts ScanStudio or a hardware bridge.
set -euo pipefail

script_dir="${0:A:h}"
launcher="${1:-$script_dir/../packaging/ScanStudioLauncher}"
workdir="$(mktemp -d)"

if [[ ! -x "$launcher" ]]; then
    print -u2 "launcher check requires an executable ScanStudioLauncher: $launcher"
    exit 66
fi

cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

mkdir -p "$workdir/app" "$workdir/bin" "$workdir/test-home/Library/Application Support/ScanStudio" "$workdir/isolated-base"
cp "$launcher" "$workdir/app/ScanStudioLauncher"
chmod +x "$workdir/app/ScanStudioLauncher"

cat > "$workdir/app/ScanStudio" <<'APP'
#!/bin/zsh
print -r -- "bridge=${SCANSTUDIO_BRIDGE_CMD:-<unset>}"
print -r -- "motion=${SCANSTUDIO_HW_MOTION:-<unset>}"
if [[ -n "${SCANSTUDIO_BRIDGE_BASE_DIR:-}" \
    && -f "$SCANSTUDIO_BRIDGE_BASE_DIR/hw-motion-armed" ]]; then
    print -r -- "latch=$(<"$SCANSTUDIO_BRIDGE_BASE_DIR/hw-motion-armed")"
else
    print -r -- "latch=<missing>"
fi
print -r -- "base=${SCANSTUDIO_BRIDGE_BASE_DIR:-<unset>}"
APP
chmod +x "$workdir/app/ScanStudio"

cat > "$workdir/app/scanstudio-bridge" <<'BRIDGE'
#!/bin/zsh
exit 0
BRIDGE
chmod +x "$workdir/app/scanstudio-bridge"

cat > "$workdir/bin/scanstudio-bridge" <<'BRIDGE'
#!/bin/zsh
exit 0
BRIDGE
chmod +x "$workdir/bin/scanstudio-bridge"

expect_output() {
    local label="$1"
    local expected="$2"
    shift 2
    local actual
    actual="$("$@")"
    if [[ "$actual" != *"$expected"* ]]; then
        print -u2 "launcher check failed ($label): expected '$expected', got '$actual'"
        exit 1
    fi
}

expect_failure() {
    local label="$1"
    local expected="$2"
    shift 2
    local actual
    if actual="$("$@" 2>&1)"; then
        print -u2 "launcher check failed ($label): command unexpectedly succeeded"
        exit 1
    fi
    if [[ "$actual" != *"$expected"* ]]; then
        print -u2 "launcher check failed ($label): expected '$expected', got '$actual'"
        exit 1
    fi
}

expect_output "explicit bridge wins" \
    "bridge=/tmp/explicit-bridge --trace" \
    env -i HOME="$workdir/test-home" PATH="/usr/bin:/bin" SCANSTUDIO_BRIDGE_CMD="/tmp/explicit-bridge --trace" "$workdir/app/ScanStudioLauncher"

print -r -- "/tmp/configured-bridge --quiet" > "$workdir/test-home/Library/Application Support/ScanStudio/bridge-command"
expect_output "user config wins over PATH" \
    "bridge=/tmp/configured-bridge --quiet" \
    env -i HOME="$workdir/test-home" PATH="$workdir/bin:/usr/bin:/bin" "$workdir/app/ScanStudioLauncher"

rm "$workdir/test-home/Library/Application Support/ScanStudio/bridge-command"
expect_output "bundled bridge wins over PATH" \
    $'bridge=scanstudio-bridge\nmotion=1\nlatch=scanstudio-app-session' \
    env -i HOME="$workdir/isolated home" PATH="$workdir/bin:/usr/bin:/bin" \
        "$workdir/app/ScanStudioLauncher"

mkdir -p "$workdir/existing home/.scanstudio"
print -r -- "operator-existing-label" > "$workdir/existing home/.scanstudio/hw-motion-armed"
chmod 640 "$workdir/existing home/.scanstudio/hw-motion-armed"
expect_output "existing authorization is replaced by the app session" \
    "latch=scanstudio-app-session" \
    env -i HOME="$workdir/existing home" PATH="$workdir/bin:/usr/bin:/bin" \
        "$workdir/app/ScanStudioLauncher"
if [[ "$(stat -f '%Lp' "$workdir/existing home/.scanstudio/hw-motion-armed")" != "600" ]]; then
    print -u2 "launcher check failed: app authorization is not private"
    exit 1
fi

mkdir -p "$workdir/symlink home/.scanstudio"
print -r -- "do-not-overwrite" > "$workdir/symlink-target"
ln -s "$workdir/symlink-target" "$workdir/symlink home/.scanstudio/hw-motion-armed"
expect_failure "symlink authorization fails closed" \
    "film-movement authorization is not a regular file" \
    env -i HOME="$workdir/symlink home" PATH="$workdir/bin:/usr/bin:/bin" \
        "$workdir/app/ScanStudioLauncher"

expect_output "packaged launcher keeps one shared hardware lane" \
    "base=$workdir/shared home/.scanstudio" \
    env -i HOME="$workdir/shared home" PATH="$workdir/bin:/usr/bin:/bin" \
        SCANSTUDIO_BRIDGE_BASE_DIR="$workdir/rogue-base" \
        "$workdir/app/ScanStudioLauncher"
if [[ -e "$workdir/rogue-base/hw-motion-armed" ]]; then
    print -u2 "launcher check failed: packaged launch honored a split-lane base override"
    exit 1
fi

rm "$workdir/app/scanstudio-bridge"
expect_output "PATH bridge is discovered only without bundle" \
    "bridge=$workdir/bin/scanstudio-bridge" \
    env -i HOME="$workdir/test-home" PATH="$workdir/bin:/usr/bin:/bin" "$workdir/app/ScanStudioLauncher"

expect_output "no bridge is simulator-only and motion stays unarmed" \
    $'bridge=<unset>\nmotion=<unset>' \
    env -i HOME="$workdir/no-bridge-home" PATH="/usr/bin:/bin" \
        "$workdir/app/ScanStudioLauncher"

expect_output "explicit motion setting is preserved" \
    "motion=1" \
    env -i HOME="$workdir/test-home" PATH="/usr/bin:/bin" SCANSTUDIO_HW_MOTION=1 "$workdir/app/ScanStudioLauncher"

if [[ "$(<"$workdir/isolated home/.scanstudio/hw-motion-armed")" != "scanstudio-app-session" ]]; then
    print -u2 "launcher check failed: launcher did not create the expected armed latch"
    exit 1
fi
if [[ -e "$workdir/no-bridge-home/.scanstudio/hw-motion-armed" ]]; then
    print -u2 "launcher check failed: simulator-only launch created an armed latch"
    exit 1
fi
if [[ "$(<"$workdir/symlink-target")" != "do-not-overwrite" ]]; then
    print -u2 "launcher check failed: rejected latch symlink target was modified"
    exit 1
fi

print "launcher checks passed"
