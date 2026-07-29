#!/bin/zsh
# Portable black-box checks for the packaged launcher. Uses a temporary app
# shell and never starts ScanStudio or a hardware bridge.
set -euo pipefail

script_dir="${0:A:h}"
launcher="$script_dir/../packaging/ScanStudioLauncher"
workdir="$(mktemp -d)"

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

expect_output "explicit bridge wins" \
    "bridge=/tmp/explicit-bridge --trace" \
    env -i HOME="$workdir/test-home" PATH="/usr/bin:/bin" SCANSTUDIO_BRIDGE_CMD="/tmp/explicit-bridge --trace" "$workdir/app/ScanStudioLauncher"

print -r -- "/tmp/configured-bridge --quiet" > "$workdir/test-home/Library/Application Support/ScanStudio/bridge-command"
expect_output "user config wins over PATH" \
    "bridge=/tmp/configured-bridge --quiet" \
    env -i HOME="$workdir/test-home" PATH="$workdir/bin:/usr/bin:/bin" "$workdir/app/ScanStudioLauncher"

rm "$workdir/test-home/Library/Application Support/ScanStudio/bridge-command"
expect_output "bundled bridge wins over PATH" \
    "bridge=scanstudio-bridge" \
    env -i HOME="$workdir/test-home" PATH="$workdir/bin:/usr/bin:/bin" "$workdir/app/ScanStudioLauncher"

rm "$workdir/app/scanstudio-bridge"
expect_output "PATH bridge is discovered only without bundle" \
    "bridge=$workdir/bin/scanstudio-bridge" \
    env -i HOME="$workdir/test-home" PATH="$workdir/bin:/usr/bin:/bin" "$workdir/app/ScanStudioLauncher"

expect_output "no bridge is simulator-only and motion stays unarmed" \
    $'bridge=<unset>\nmotion=<unset>' \
    env -i HOME="$workdir/test-home" PATH="/usr/bin:/bin" "$workdir/app/ScanStudioLauncher"

expect_output "explicit motion setting is preserved" \
    "motion=1" \
    env -i HOME="$workdir/test-home" PATH="/usr/bin:/bin" SCANSTUDIO_HW_MOTION=1 "$workdir/app/ScanStudioLauncher"

if [[ -e "$workdir/isolated-base/hw-motion-armed" ]]; then
    print -u2 "launcher check failed: launcher created an armed latch"
    exit 1
fi

print "launcher checks passed"
