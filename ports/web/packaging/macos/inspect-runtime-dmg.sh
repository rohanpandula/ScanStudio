#!/usr/bin/env bash
# Verify the final signed, notarized runtime DMG and emit its exact payload
# identity/tree summary for the detached release manifest.
set -euo pipefail

usage() {
    printf 'Usage: inspect-runtime-dmg.sh <runtime.dmg> <version> <arm64|x86_64> <team-id> <summary.json>\n' >&2
}

if [[ $# -ne 5 ]]; then
    usage
    exit 64
fi

dmg="$1"
version="$2"
arch="$3"
expected_team="$4"
summary="$5"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Runtime DMG inspection requires macOS.\n' >&2
    exit 69
fi
if [[ ! -f "$dmg" || -L "$dmg" ]]; then
    printf 'Runtime DMG is missing or is not a regular file: %s\n' "$dmg" >&2
    exit 66
fi
if (( ${#version} > 96 )) \
    || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)?)?$ ]]; then
    printf 'Bad release version: %s\n' "$version" >&2
    exit 64
fi
if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    printf 'Bad architecture: %s\n' "$arch" >&2
    exit 64
fi
if [[ ! "$expected_team" =~ ^[0-9A-Z]{10}$ ]]; then
    printf 'Bad Developer ID team identifier.\n' >&2
    exit 64
fi
if [[ -e "$summary" || -L "$summary" ]]; then
    printf 'Refusing to overwrite an existing payload summary: %s\n' "$summary" >&2
    exit 73
fi

for command in codesign file hdiutil lipo spctl strings xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required verification tool is unavailable: %s\n' "$command" >&2
        exit 127
    fi
done

stem="ScanStudio-WebRuntime-$version-macOS-$arch"
if [[ "$(basename "$dmg")" != "$stem.dmg" ]]; then
    printf 'Runtime DMG name does not match its version/architecture contract.\n' >&2
    exit 64
fi

codesign --verify --strict "$dmg"
hdiutil verify "$dmg" >/dev/null
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

summary_parent="$(dirname "$summary")"
mkdir -p "$summary_parent"
summary_parent="$(cd "$summary_parent" && pwd)"
summary="$summary_parent/$(basename "$summary")"
workdir="$(mktemp -d "$summary_parent/.runtime-inspect.XXXXXX")"
mount_point="$workdir/mounted"
mkdir "$mount_point"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 \
            || hdiutil detach -force "$mount_point" >/dev/null 2>&1 \
            || true
    fi
    rm -rf -- "$workdir"
}
trap cleanup EXIT

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$dmg"
mounted=1
python3 - "$mount_point" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
entries = sorted(path.name for path in root.iterdir())
if entries != ["ScanStudioWebRuntime.bundle"]:
    raise SystemExit(f"runtime DMG root is not exact: {entries!r}")
PY

bundle="$mount_point/ScanStudioWebRuntime.bundle"
launcher="$bundle/Contents/MacOS/scanstudio-web-runtime"
static_dir="$bundle/Contents/Resources/WebFrontend"
resources="$bundle/Contents/Resources"
if [[ ! -d "$bundle" || -L "$bundle" || ! -x "$launcher" || -L "$launcher" ]]; then
    printf 'Runtime bundle or launcher is missing/unsafe.\n' >&2
    exit 1
fi
if [[ ! -d "$static_dir" || -L "$static_dir" \
      || "$(tr -d '\r\n' < "$static_dir/scanstudio-web-runtime.json")" \
        != '{"schemaVersion":1,"runtime":"simulator-only-web"}' ]]; then
    printf 'Runtime bundle does not contain the compatible simulator frontend.\n' >&2
    exit 1
fi
for required_path in \
    "$resources/runtime.json" \
    "$resources/SBOM/ScanStudio-WebRuntime.cdx.json" \
    "$resources/Licenses/README.txt" \
    "$resources/Licenses/dependency-notices-manifest.json" \
    "$resources/Licenses/python-build-standalone/PYTHON.json" \
    "$resources/Licenses/python-build-standalone/inventory.json" \
    "$resources/Licenses/python-build-standalone/pin.json" \
    "$resources/Source/scanstudio-web/src/scanstudio_web" \
    "$resources/Source/web-frontend/src"; do
    if [[ ! -e "$required_path" || -L "$required_path" ]]; then
        printf 'Runtime evidence/source prerequisite missing: %s\n' "$required_path" >&2
        exit 1
    fi
done

if find "$bundle" -type l -print -quit | grep -q .; then
    printf 'Runtime bundle contains a forbidden symlink.\n' >&2
    exit 1
fi
if find "$resources/Python" \
    \( -name '_tkinter*.so' -o -name 'libtcl*.dylib' \
       -o -name 'libtk*.dylib' -o -name 'tcl[0-9]*' -o -name 'tk[0-9]*' \
       -o -name 'itcl[0-9]*' -o -name 'thread[0-9]*' -o -name pkgconfig \
       -o -name 'uvloop*' -o -name 'httptools*' -o -name 'watchfiles*' \
       -o -name 'pydantic_core*' \) \
    -print -quit | grep -q .; then
    printf 'Runtime contains a forbidden unused/native dependency path.\n' >&2
    exit 1
fi
if grep -rEl '/Users/|/var/folders/|/private/var/folders/' "$bundle" >/dev/null 2>&1; then
    printf 'Runtime contains a developer or temporary build path.\n' >&2
    exit 1
fi
if find "$bundle" \
    \( -iname '*coolscanpy*' -o -iname '*scanstudio-bridge*' \
       -o -iname '*libusb*' -o -name 'sane.py' -o -name 'scanstudio-engine' \
       -o -name 'BridgeRuntime' \) \
    -print -quit | grep -q .; then
    printf 'Runtime bundle contains a forbidden engine/bridge/hardware path.\n' >&2
    exit 1
fi
if ! strings "$launcher" | grep -Fxq 'SCANSTUDIO_BRIDGE_CMD' \
    || ! strings "$launcher" | grep -Fxq 'SCANSTUDIO_HW_MOTION'; then
    printf 'Signed launcher does not contain both mandatory hardware-environment scrubs.\n' >&2
    exit 1
fi

python3 - "$resources/runtime.json" "$version" "$arch" <<'PY'
import json
from pathlib import Path
import sys

value = json.loads(Path(sys.argv[1]).read_text())
expected = {
    "schemaVersion": 1,
    "product": "ScanStudio Web Runtime",
    "channel": "simulator-preview",
    "runtimeVersion": sys.argv[2],
    "hostVersion": sys.argv[2],
    "architecture": sys.argv[3],
    "engineProtocolVersion": 1,
    "simulatorOnly": True,
    "bundlesEngine": False,
    "bundlesBridge": False,
    "hardwareEnabled": False,
}
if value != expected:
    raise SystemExit(f"internal runtime contract mismatch: {value!r}")
PY

python3 "$script_dir/python-build-standalone-evidence.py" verify-bundle \
    --pin "$script_dir/python-build-standalone-lock.json" \
    --architecture "$arch" \
    --runtime-root "$resources/Python" \
    --evidence-root "$resources/Licenses/python-build-standalone"
python3 - \
    "$resources/Licenses/python-build-standalone/inventory.json" \
    "$resources/SBOM/ScanStudio-WebRuntime.cdx.json" <<'PY'
import json
from pathlib import Path
import sys

inventory = json.loads(Path(sys.argv[1]).read_text())
sbom = json.loads(Path(sys.argv[2]).read_text())
expected = {}
for component in inventory["components"]:
    identity = (component["name"], component["scope"])
    if component["licenseExpressions"]:
        licenses = [
            {"expression": expression}
            for expression in component["licenseExpressions"]
        ]
    elif component["publicDomain"]:
        licenses = [{"license": {"name": "Public Domain"}}]
    else:
        licenses = []
    if component["scope"] == "required" and not licenses:
        raise SystemExit(
            f"required Python distribution component lacks license attribution: "
            f"{component['name']}"
        )
    expected[identity] = licenses

actual = {}
python_components = []
npm_components = []
for component in sbom.get("components", []):
    if component.get("group") == "python-build-standalone":
        identity = (component["name"], component["scope"])
        if identity in actual:
            raise SystemExit("CycloneDX contains a duplicate Python distribution component")
        actual[identity] = component.get("licenses", [])
    elif component.get("group") == "python":
        python_components.append(component)
    elif component.get("group") == "npm":
        npm_components.append(component)
if actual != expected:
    raise SystemExit("CycloneDX python-build-standalone closure is missing or stale")
if not python_components or any(not component.get("licenses") for component in python_components):
    raise SystemExit("CycloneDX Python wheel closure lacks license attribution")
if not npm_components or any(not component.get("licenses") for component in npm_components):
    raise SystemExit("CycloneDX npm production closure lacks license attribution")
if ("zlib", "required") not in actual or any(name == "zlib-ng" for name, _ in actual):
    raise SystemExit("CycloneDX does not reflect the proven system-zlib dependency")
PY

codesign --verify --deep --strict "$bundle"
codesign --verify --strict "$launcher"
spctl --assess --type execute --verbose=2 "$bundle"
identity="$({ codesign -d --verbose=4 "$launcher"; } 2>&1)"
bundle_identifier="$(printf '%s\n' "$identity" | awk -F= '$1 == "Identifier" {print $2; exit}')"
team_identifier="$(printf '%s\n' "$identity" | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
if [[ "$bundle_identifier" != 'dev.scanstudio.live.web-runtime' ]]; then
    printf 'Unexpected runtime code identifier: %s\n' "$bundle_identifier" >&2
    exit 1
fi
if [[ "$team_identifier" != "$expected_team" ]]; then
    printf 'Runtime TeamIdentifier mismatch: expected %s, found %s.\n' "$expected_team" "$team_identifier" >&2
    exit 1
fi
if ! printf '%s\n' "$identity" | grep -Fq 'Authority=Developer ID Application:'; then
    printf 'Runtime launcher is not Developer ID Application signed.\n' >&2
    exit 1
fi
if [[ "$(lipo -archs "$launcher")" != "$arch" ]]; then
    printf 'Runtime launcher architecture mismatch.\n' >&2
    exit 1
fi
while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
        codesign --verify --strict "$candidate"
        if [[ "$(lipo -archs "$candidate")" != "$arch" ]]; then
            printf 'Nested runtime architecture mismatch: %s\n' "$candidate" >&2
            exit 1
        fi
    fi
done < <(find "$bundle" -type f -print0)

tree_summary="$workdir/tree-summary.json"
"$script_dir/payload-tree-hash.sh" \
    "$bundle" > "$tree_summary"
python3 - \
    "$tree_summary" "$summary" "$bundle_identifier" "$team_identifier" <<'PY'
import json
from pathlib import Path
import sys

tree = json.loads(Path(sys.argv[1]).read_text())
output = Path(sys.argv[2])
payload = {
    "bundleName": "ScanStudioWebRuntime.bundle",
    "bundleIdentifier": sys.argv[3],
    "teamIdentifier": sys.argv[4],
    "developerIDSigned": True,
    "notarized": True,
    "executableRelativePath": "Contents/MacOS/scanstudio-web-runtime",
    "staticDirectoryRelativePath": "Contents/Resources/WebFrontend",
    "fileCount": tree["fileCount"],
    "installedSize": tree["installedSize"],
    "treeSHA256": tree["treeSHA256"],
}
output.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY

hdiutil detach -quiet "$mount_point"
mounted=0
printf 'Verified notarized runtime payload and wrote %s\n' "$summary"
