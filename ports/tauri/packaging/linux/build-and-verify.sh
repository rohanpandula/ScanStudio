#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: %s <version> <output-dir>\n' "$0" >&2
    exit 64
fi

version="$1"
output_dir="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    printf 'bad release version: %s\n' "$version" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
port_root="$(cd "$script_dir/../.." && pwd)"
app_root="$port_root/app"
staging_root="$port_root/packaging/.staging/linux"
verifier="$script_dir/verify-bundle.sh"
pinned_tools="$port_root/packaging/install_pinned_tauri_tools.py"
cargo_target="$app_root/src-tauri/target"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
build_config="$temporary_root/tauri-version.json"
printf '{"version":"%s"}\n' "$version" > "$build_config"

# Stamp the release version into the Tauri app's own version fields before
# any build step runs. tauri::generate_context!() embeds tauri.conf.json's
# "version" at `cargo build` time -- that's what @tauri-apps/api's
# getVersion() returns and what the AppImage bundle carries -- so the
# checked-in files must say the real version before the build starts, not
# just the CLI's --config merge above. Cargo.toml and package.json are
# stamped too so `cargo metadata`, the cargo-about notice generator, and npm
# tooling agree with the shipped binary instead of showing a frozen "0.3.0".
python3 -I -S -B - \
    "$app_root/src-tauri/tauri.conf.json" \
    "$app_root/package.json" \
    "$app_root/src-tauri/Cargo.toml" \
    "$app_root/src-tauri/Cargo.lock" \
    "$version" <<'PY'
import re
import sys

tauri_conf_path, package_json_path, cargo_toml_path, cargo_lock_path, release_version = sys.argv[1:6]


def stamp(path, pattern):
    with open(path, "r", encoding="utf-8") as handle:
        content = handle.read()
    found = list(re.finditer(pattern, content, flags=re.MULTILINE))
    if len(found) != 1:
        sys.exit(f"expected exactly one version field in {path}, found {len(found)}")
    start, end = found[0].span(1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content[:start] + release_version + content[end:])


json_version_pattern = r'"version":\s*"([^"]*)"'
stamp(tauri_conf_path, json_version_pattern)
stamp(package_json_path, json_version_pattern)
stamp(cargo_toml_path, r'(?m)^version = "([^"]*)"')
# Cargo.lock records this workspace member's own version in its
# [[package]] block; --locked (the supply-chain gate the pinned toolchain
# work added) refuses to silently regenerate a lockfile that has drifted
# from Cargo.toml, so the stamp must apply here too or cargo/rustc refuse
# to run at all before any build step -- exactly what happened once
# Cargo.toml alone was stamped.
stamp(cargo_lock_path, r'(?m)^name = "scanstudio-app"\nversion = "([^"]*)"')
PY

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
appimage_output="$output_dir/ScanStudio-$version-Linux-x86_64-preview.AppImage"
portable_output="$output_dir/ScanStudio-$version-Linux-x86_64-preview-portable.tar.gz"
for path in "$appimage_output" "$portable_output"; do
    if [[ -e "$path" ]]; then
        printf 'refusing to overwrite release output: %s\n' "$path" >&2
        exit 73
    fi
done

find_bundle_root() {
    local tree="$1"
    local -a roots=()
    while IFS= read -r provenance; do
        local candidate
        candidate="$(dirname "$provenance")"
        if [[ -d "$candidate/Licenses" && -d "$candidate/CorrespondingSource" ]]; then
            roots+=("$candidate")
        fi
    done < <(find "$tree" -type f -name provenance.json -print)
    if [[ ${#roots[@]} -ne 1 ]]; then
        printf 'expected exactly one bundled resource root under %s, found %d: %s\n' \
            "$tree" "${#roots[@]}" "${roots[*]-}" >&2
        return 1
    fi
    printf '%s\n' "${roots[0]}"
}

smoke_engine() {
    local tree="$1"
    local output="$2"
    local -a main_executables=()
    local -a engines=()
    while IFS= read -r executable; do
        main_executables+=("$executable")
    done < <(find "$tree" -type f -name 'scanstudio-app' -perm -111 -print)
    if [[ ${#main_executables[@]} -ne 1 ]]; then
        printf 'expected exactly one ScanStudio executable under %s, found %d: %s\n' \
            "$tree" "${#main_executables[@]}" "${main_executables[*]-}" >&2
        return 1
    fi
    while IFS= read -r engine; do
        engines+=("$engine")
    done < <(find "$tree" -type f -name 'scanstudio-engine*' -perm -111 -print)
    if [[ ${#engines[@]} -ne 1 ]]; then
        printf 'expected exactly one engine sidecar under %s, found %d: %s\n' \
            "$tree" "${#engines[@]}" "${engines[*]-}" >&2
        return 1
    fi

    printf '%s\n' \
        '{"id":1,"method":"engine.hello","params":{"clientName":"package-smoke","protocolVersion":1}}' \
        '{"id":2,"method":"scanner.list","params":{}}' \
        '{"id":3,"method":"engine.shutdown","params":{}}' \
        | env -u SCANSTUDIO_BRIDGE_CMD timeout 15s "${engines[0]}" > "$output"

    python3 - "$output" <<'PY'
import json
import sys

responses = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for request_id in (1, 2, 3):
    matches = [item for item in responses if item.get("id") == request_id]
    assert len(matches) == 1 and "error" not in matches[0], (request_id, responses)
hello = next(item for item in responses if item.get("id") == 1)["result"]
assert hello["engineName"] == "scanstudio-engine"
assert hello["protocolVersion"] == 1
devices = next(item for item in responses if item.get("id") == 2)["result"]["devices"]
assert isinstance(devices, list)
print("engine hello/list/shutdown smoke passed")
PY
}

"$script_dir/assemble-staging.sh"
"$verifier" "$staging_root"

(
    cd "$app_root"
    npm ci
    tauri_cli_version="$(./node_modules/.bin/tauri --version)"
    if [[ "$tauri_cli_version" != 'tauri-cli 2.11.4' ]]; then
        printf 'unexpected Tauri CLI version: %s\n' "$tauri_cli_version" >&2
        exit 1
    fi
    npm run sync-engine
    npm test
    npx tsc --noEmit
    npm run build
    cargo test --locked --manifest-path src-tauri/Cargo.toml
    python3 -I -S -B "$pinned_tools" prepare linux --target-directory "$cargo_target"
    python3 -I -S -B "$pinned_tools" verify linux --target-directory "$cargo_target"
    npm run tauri -- build --ci --bundles appimage --config "$build_config" --verbose -- --locked
    python3 -I -S -B "$pinned_tools" verify linux --target-directory "$cargo_target"
)

mapfile -t appimages < <(find "$app_root/src-tauri/target/release/bundle/appimage" -maxdepth 1 -type f -name '*.AppImage' -print)
if [[ ${#appimages[@]} -ne 1 ]]; then
    printf 'expected exactly one AppImage, found %d: %s\n' "${#appimages[@]}" "${appimages[*]-}" >&2
    exit 1
fi

cp "${appimages[0]}" "$appimage_output"
chmod 755 "$appimage_output"

(
    cd "$temporary_root"
    "$appimage_output" --appimage-extract >/dev/null
)
appdir="$temporary_root/squashfs-root"
[[ -d "$appdir" ]] || {
    printf 'AppImage extraction did not create %s\n' "$appdir" >&2
    exit 1
}

bundle_root="$(find_bundle_root "$appdir")"
"$verifier" "$bundle_root"
smoke_engine "$appdir" "$temporary_root/appimage-engine-smoke.jsonl"

portable_name="ScanStudio-$version-Linux-x86_64-preview"
portable_root="$temporary_root/$portable_name"
mv "$appdir" "$portable_root"
tar -C "$temporary_root" -czf "$portable_output" "$portable_name"

portable_extract="$temporary_root/portable-extract"
mkdir -p "$portable_extract"
tar -C "$portable_extract" -xzf "$portable_output"
portable_tree="$portable_extract/$portable_name"
portable_bundle_root="$(find_bundle_root "$portable_tree")"
"$verifier" "$portable_bundle_root"
smoke_engine "$portable_tree" "$temporary_root/portable-engine-smoke.jsonl"

sha256sum "$appimage_output" "$portable_output"
