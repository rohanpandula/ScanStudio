#!/usr/bin/env bash
set -euo pipefail

# macOS Tauri bundle build, ad-hoc codesign, DMG mount verification, and
# NDJSON sidecar smoke test. Tauri is given the ad-hoc signing identity during
# bundling, so it signs the .app before creating the DMG. We then mount the
# finished DMG and run codesign --deep --strict against the copy users receive.
#
# This does NOT replace the SwiftUI production Apple-silicon beta or its
# package_app.sh flow. It is a cross-platform Tauri-port prerelease proof.
# Runs on a real macOS host with Node + Rust installed.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
app_dir="$repo_root/app"

# --- Step 1: build, sign, then create the Tauri DMG ----------------------
cd "$app_dir"
macos_bundle_config='{"bundle":{"targets":["app","dmg"],"macOS":{"signingIdentity":"-","hardenedRuntime":false}}}'
npm run tauri -- build --bundles dmg --config "$macos_bundle_config"

bundle_dmg="$app_dir/src-tauri/target/release/bundle/dmg"
dmg_path="$(find "$bundle_dmg" -maxdepth 1 -name '*.dmg' -type f -print -quit 2>/dev/null || true)"
if [[ -z "$dmg_path" || ! -f "$dmg_path" ]]; then
    printf 'FAIL: no DMG found under %s\n' "$bundle_dmg" >&2
    exit 1
fi

# --- Step 2: mount and verify the exact app shipped in the DMG ------------
# Tauri deliberately removes its temporary build-tree .app after the DMG is
# complete, so the DMG is the authoritative artifact for verification.
attach_plist="$(mktemp)"
mount_point=""
hdiutil attach -readonly -nobrowse -plist "$dmg_path" > "$attach_plist"
mount_point="$(python3 - "$attach_plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)
for entity in payload.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        break
PY
)"
if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
    printf 'FAIL: hdiutil did not report a mounted DMG volume\n' >&2
    exit 1
fi
cleanup_mount() {
    if [[ -n "$mount_point" ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    fi
    if [[ -n "$attach_plist" ]]; then
        rm -f -- "$attach_plist"
    fi
}
trap cleanup_mount EXIT

mounted_app="$(find "$mount_point" -maxdepth 2 -name '*.app' -type d -print -quit)"
if [[ -z "$mounted_app" || ! -d "$mounted_app" ]]; then
    printf 'FAIL: mounted DMG contains no .app bundle\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$mounted_app"
printf 'PASS  mounted DMG app passes codesign --verify --deep --strict: %s\n' "$mounted_app"

host_triple="$(rustc --print host-tuple)"
macos_dir="$mounted_app/Contents/MacOS"
# Tauri strips the target triple when bundling an externalBin sidecar: the
# sidecar ships as `scanstudio-engine` (the base name), even though it is
# staged as `scanstudio-engine-$host_triple` in src-tauri/binaries. Detect by
# prefix so either form is found.
engine_bin="$(find "$macos_dir" -maxdepth 1 -type f -name 'scanstudio-engine*' -print -quit)"
if [[ -z "$engine_bin" || ! -x "$engine_bin" ]]; then
    printf 'FAIL: bundled sidecar not found under %s (looked for scanstudio-engine*/%s)\n' \
        "$macos_dir" "scanstudio-engine-$host_triple" >&2
    exit 1
fi

# The main app binary is the other executable in Contents/MacOS (the crate's
# bin target, e.g. scanstudio-app); detect it rather than guessing a name.
app_bin="$(find "$macos_dir" -maxdepth 1 -type f -perm -111 ! -name 'scanstudio-engine*' -print -quit)"
if [[ -z "$app_bin" || ! -x "$app_bin" ]]; then
    printf 'FAIL: no main app binary found under %s\n' "$macos_dir" >&2
    exit 1
fi

# --- Step 3: NDJSON smoke test against the sidecar shipped in the DMG -----
python3 - "$engine_bin" <<'PY'
import json
import subprocess
import sys
import time

engine = sys.argv[1]
proc = subprocess.Popen(
    [engine],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,
)

failures = []


def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def read_response(match_id, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "event" in msg:
            continue  # unsolicited (e.g. scanner.status) - never matched to a request
        if msg.get("id") == match_id:
            return msg
    return None


def check(name, cond, detail=""):
    if cond:
        print("PASS  " + name)
    else:
        print("FAIL  " + name + ((": " + str(detail)) if detail else ""), file=sys.stderr)
        failures.append(name)


# id 1: engine.hello
send({"id": 1, "method": "engine.hello",
      "params": {"clientName": "packaging-smoke-test", "protocolVersion": 1}})
r = read_response(1)
check("engine.hello responds id 1", r is not None, r)
check("engine.hello engineName == scanstudio-engine",
      r is not None and r.get("result", {}).get("engineName") == "scanstudio-engine", r)
check("engine.hello protocolVersion == 1",
      r is not None and r.get("result", {}).get("protocolVersion") == 1, r)

# id 2: scanner.list -> exactly one simulated device
send({"id": 2, "method": "scanner.list", "params": {}})
r = read_response(2)
devices = r.get("result", {}).get("devices", []) if r else []
check("scanner.list exactly one device", r is not None and len(devices) == 1, detail="devices=%r" % (devices,))

# id 3: scanner.connect using devices[0]'s device id; no error; tolerate interleaving event
device_id = devices[0].get("deviceId") or devices[0].get("id") if devices else None
check("scanner.list device has id", bool(device_id), detail="devices=%r" % (devices,))
send({"id": 3, "method": "scanner.connect", "params": {"deviceId": device_id}})
r = read_response(3)
check("scanner.connect no error", r is not None and "error" not in r, r)

# id 4: engine.shutdown last, then process exits 0
send({"id": 4, "method": "engine.shutdown", "params": {}})
r = read_response(4)
check("engine.shutdown responds id 4", r is not None and "error" not in r, r)

code = None
deadline = time.time() + 10
while time.time() < deadline:
    rc = proc.poll()
    if rc is not None:
        code = rc
        break
    time.sleep(0.05)
if code is None:
    proc.kill()
    proc.wait()
    print("FAIL  engine did not exit within 10s of engine.shutdown; killed", file=sys.stderr)
    failures.append("engine.shutdown exit")
elif code == 0:
    print("PASS  engine exits 0 on shutdown")
else:
    print("FAIL  engine exited %d (expected 0)" % code, file=sys.stderr)
    failures.append("engine.shutdown exit")

if failures:
    print("smoke: %d assertion(s) failed" % len(failures), file=sys.stderr)
    sys.exit(1)
print("smoke: all assertions passed")
PY

printf 'macOS bundle smoke test passed for %s\n' "$mounted_app"
printf 'DMG verified after signing: %s\n' "$dmg_path"
printf '%s\n' 'NOTE: this Tauri-port DMG is a prerelease proof, not the production Apple-silicon beta.'
