#!/usr/bin/env bash
# Build a separately delivered, Developer-ID-signed macOS web runtime DMG.
# This payload deliberately contains no ScanStudio engine, bridge, CoolScanPy,
# libusb, SANE binding, hardware authorization, or native ScanStudio.app.
set -euo pipefail

usage() {
    printf 'Usage: package-runtime.sh <version> <arm64|x86_64> <output-dir> <Developer ID Application identity>\n' >&2
}

if [[ $# -ne 4 ]]; then
    usage
    exit 64
fi

version="$1"
arch="$2"
output_dir="$3"
codesign_identity="$4"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'The macOS web runtime must be built on macOS.\n' >&2
    exit 69
fi
if (( ${#version} > 96 )) \
    || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)?)?$ ]]; then
    printf 'Bad release version: %s\n' "$version" >&2
    exit 64
fi
if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    printf 'Bad architecture: %s (expected arm64 or x86_64)\n' "$arch" >&2
    exit 64
fi
if [[ "$(uname -m)" != "$arch" ]]; then
    printf 'Refusing a non-native runtime build: requested %s on %s.\n' "$arch" "$(uname -m)" >&2
    exit 64
fi
if [[ "$codesign_identity" != 'Developer ID Application: '* ]]; then
    printf 'A Developer ID Application identity is mandatory; ad-hoc signing is not a web-runtime release.\n' >&2
    exit 78
fi

for command in codesign file hdiutil install_name_tool lipo otool rsync shasum stat strip xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required packaging tool is unavailable: %s\n' "$command" >&2
        exit 127
    fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
web_root="$repo_root/ports/web"
frontend_root="$repo_root/ports/tauri/app"
web_python="$web_root/.venv/bin/python"
frontend="$frontend_root/dist"
frontend_marker="$frontend/scanstudio-web-runtime.json"
launcher_source="$script_dir/launcher.c"
pbs_pin="$script_dir/python-build-standalone-lock.json"
pbs_evidence_tool="$script_dir/python-build-standalone-evidence.py"
pbs_distribution_root="${SCANSTUDIO_PBS_DISTRIBUTION_ROOT:-}"

for required_file in \
    "$web_python" \
    "$web_root/pyproject.toml" \
    "$web_root/uv.lock" \
    "$frontend_root/package.json" \
    "$frontend_root/package-lock.json" \
    "$frontend_marker" \
    "$launcher_source" \
    "$pbs_pin" \
    "$pbs_evidence_tool" \
    "$repo_root/LICENSE" \
    "$repo_root/THIRD_PARTY_NOTICES.md"; do
    if [[ ! -f "$required_file" ]]; then
        printf 'Web runtime prerequisite missing: %s\n' "$required_file" >&2
        exit 66
    fi
done
if [[ ! -x "$web_python" || ! -d "$web_root/src/scanstudio_web" || ! -d "$frontend" ]]; then
    printf 'Build the locked production gateway environment and web frontend before packaging.\n' >&2
    exit 66
fi
if [[ "$(tr -d '\r\n' < "$frontend_marker")" != '{"schemaVersion":1,"runtime":"simulator-only-web"}' ]]; then
    printf 'Refusing a frontend without the exact simulator-only runtime marker.\n' >&2
    exit 66
fi
if find "$frontend" "$web_root/src" "$frontend_root/src" \
    -type l -print -quit | grep -q .; then
    printf 'Refusing web runtime source/frontend input containing symlinks.\n' >&2
    exit 66
fi

python_version="$($web_python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
if [[ "$python_version" != "3.13.14" ]]; then
    printf 'The web runtime requires pinned Python 3.13.14; found %s.\n' "$python_version" >&2
    exit 66
fi
python_prefix="$($web_python -c 'import sys; print(sys.base_prefix)')"
site_packages="$($web_python -c 'import site; print(next(path for path in site.getsitepackages() if path.endswith("site-packages")))')"
if [[ ! -x "$python_prefix/bin/python3.13" || ! -d "$site_packages" ]]; then
    printf 'The locked gateway environment does not expose a relocatable Python runtime.\n' >&2
    exit 66
fi
if [[ -z "$pbs_distribution_root" || ! -d "$pbs_distribution_root" \
      || -L "$pbs_distribution_root" ]]; then
    printf 'SCANSTUDIO_PBS_DISTRIBUTION_ROOT must name the exact pinned full distribution.\n' >&2
    exit 66
fi
"$web_python" - "$pbs_distribution_root" "$python_prefix" <<'PY'
from pathlib import Path
import sys

distribution_root = Path(sys.argv[1]).resolve(strict=True)
python_prefix = Path(sys.argv[2]).resolve(strict=True)
if distribution_root / "install" != python_prefix:
    raise SystemExit("gateway environment is not based on the supplied pinned distribution")
PY
"$web_python" "$pbs_evidence_tool" validate-distribution \
    --pin "$pbs_pin" \
    --architecture "$arch" \
    --distribution-root "$pbs_distribution_root" \
    --run-interpreter
python_arches="$(lipo -archs "$python_prefix/bin/python3.13")"
if [[ "$python_arches" != "$arch" ]]; then
    printf 'Bundled Python architecture mismatch: expected %s, found %s.\n' "$arch" "$python_arches" >&2
    exit 66
fi
if otool -L "$python_prefix/bin/python3.13" | tail -n +2 \
    | grep -qE '/(opt/homebrew|usr/local|Users)/'; then
    printf 'Refusing a Python executable with machine-absolute linkage.\n' >&2
    exit 66
fi
"$web_python" - "$python_prefix" "$site_packages" <<'PY'
from pathlib import Path
import sys

for raw_root in sys.argv[1:]:
    root = Path(raw_root).resolve(strict=True)
    for candidate in root.rglob("*"):
        if not candidate.is_symlink():
            continue
        try:
            candidate.resolve(strict=True).relative_to(root)
        except (FileNotFoundError, ValueError) as error:
            raise SystemExit(f"runtime input symlink escapes or dangles: {candidate}") from error
PY
for development_package in \
    httpx pytest pytest_asyncio ruff \
    httptools pydantic_core uvloop watchfiles websockets; do
    if find "$site_packages" -maxdepth 1 \
        \( -name "$development_package" -o -name "${development_package}-*.dist-info" \) \
        -print -quit | grep -q .; then
        printf 'Forbidden optional/development Python dependency remains installed: %s. Run the exact locked production sync.\n' "$development_package" >&2
        exit 66
    fi
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
stem="ScanStudio-WebRuntime-$version-macOS-$arch"
output="$output_dir/$stem.dmg"
if [[ -e "$output" || -L "$output" ]]; then
    printf 'Refusing to overwrite an existing release artifact: %s\n' "$output" >&2
    exit 73
fi

staging_root="$(mktemp -d "$output_dir/.scanstudio-web-runtime.XXXXXX")"
payload_root="$staging_root/payload"
bundle="$payload_root/ScanStudioWebRuntime.bundle"
contents="$bundle/Contents"
resources="$contents/Resources"
bundled_python="$resources/Python"
temporary_dmg="$staging_root/$stem.dmg"
mount_point="$staging_root/mounted"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 \
            || hdiutil detach -force "$mount_point" >/dev/null 2>&1 \
            || true
    fi
    rm -rf -- "$staging_root"
}
trap cleanup EXIT

mkdir -p \
    "$contents/MacOS" \
    "$resources/WebFrontend" \
    "$resources/Licenses/python-wheels" \
    "$resources/Licenses/npm-production" \
    "$resources/Source/scanstudio-web" \
    "$resources/Source/web-frontend" \
    "$resources/SBOM" \
    "$mount_point"

# Dereference the standalone runtime's internal convenience symlinks. The app
# cache rejects every symlink and hard link before launch, so the release tree
# is intentionally composed only of ordinary directories and regular files.
rsync -aL --delete \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$python_prefix/" "$bundled_python/"

runtime_site_packages="$bundled_python/lib/python3.13/site-packages"
source_pip_dist="$(find "$runtime_site_packages" -maxdepth 1 -type d \
    -name 'pip-26.1.2.dist-info' -print)"
if [[ ! -d "$runtime_site_packages/pip" || -z "$source_pip_dist" \
      || "$source_pip_dist" == *$'\n'* ]]; then
    printf 'Pinned Python pip-removal layout changed.\n' >&2
    exit 66
fi
mkdir -p "$runtime_site_packages"
rsync -aL --delete \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '_virtualenv.*' \
    --exclude '*.pth' \
    "$site_packages/" "$runtime_site_packages/"
if find "$runtime_site_packages" -maxdepth 1 \
    \( -name pip -o -name 'pip-*.dist-info' -o -name setuptools \
       -o -name 'setuptools-*.dist-info' \) -print -quit | grep -q .; then
    printf 'Runtime-unused Python installer/build packages remain after production sync.\n' >&2
    exit 66
fi
find "$runtime_site_packages" -maxdepth 1 -type d \
    -name 'scanstudio_web-*.dist-info' -exec rm -rf -- {} +
rsync -aL --delete \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$web_root/src/scanstudio_web/" "$runtime_site_packages/scanstudio_web/"
mkdir -p "$runtime_site_packages/scanstudio_web-0.1.0.dist-info"
cat > "$runtime_site_packages/scanstudio_web-0.1.0.dist-info/METADATA" <<'EOF'
Metadata-Version: 2.1
Name: scanstudio-web
Version: 0.1.0
License-Expression: MIT
EOF

# Remove unused interactive/development portions of the exact pinned CPython
# distribution. The Tcl/Tk 9 paths are asserted before deletion so an upstream
# layout change cannot silently leave an unused interpreter stack behind.
for pinned_unused_path in \
    "$bundled_python/lib/libtcl9.0.dylib" \
    "$bundled_python/lib/libtcl9tk9.0.dylib" \
    "$bundled_python/lib/itcl4.3.5" \
    "$bundled_python/lib/tcl9" \
    "$bundled_python/lib/tcl9.0" \
    "$bundled_python/lib/thread3.0.4" \
    "$bundled_python/lib/tk9.0" \
    "$bundled_python/lib/pkgconfig" \
    "$bundled_python/lib/libpython3.13.a"; do
    if [[ ! -e "$pinned_unused_path" || -L "$pinned_unused_path" ]]; then
        printf 'Pinned Python unused-path contract changed: %s\n' "$pinned_unused_path" >&2
        exit 66
    fi
done
tkinter_extension="$(find "$bundled_python/lib/python3.13" -type f \
    -name '_tkinter*.so' -print)"
if [[ -z "$tkinter_extension" || "$tkinter_extension" == *$'\n'* ]]; then
    printf 'Pinned Python must contain exactly one removable _tkinter extension.\n' >&2
    exit 66
fi
rm -rf -- \
    "$bundled_python/include" \
    "$bundled_python/share" \
    "$bundled_python/lib/python3.13/idlelib" \
    "$bundled_python/lib/python3.13/test" \
    "$bundled_python/lib/python3.13/tkinter" \
    "$bundled_python/lib/python3.13/turtledemo" \
    "$bundled_python/lib/python3.13/ensurepip" \
    "$bundled_python/lib/libtcl9.0.dylib" \
    "$bundled_python/lib/libtcl9tk9.0.dylib" \
    "$bundled_python/lib/itcl4.3.5" \
    "$bundled_python/lib/tcl9" \
    "$bundled_python/lib/tcl9.0" \
    "$bundled_python/lib/thread3.0.4" \
    "$bundled_python/lib/tk9.0" \
    "$bundled_python/lib/pkgconfig" \
    "$bundled_python/lib/libpython3.13.a"
find "$bundled_python/bin" -mindepth 1 -maxdepth 1 \
    ! -name 'python3.13' -delete
rm -- "$tkinter_extension"
rm -rf -- "$bundled_python/lib/python3.13/config-3.13-darwin"
find "$bundled_python/lib/python3.13/lib-dynload" -type f \
    \( -name '_test*.so' -o -name '_xxtestfuzz*.so' \
       -o -name 'xxlimited*.so' -o -name 'xxsubtype*.so' \) -delete
if find "$bundled_python" \
    \( -name '_tkinter*.so' -o -name 'libtcl*.dylib' \
       -o -name 'libtk*.dylib' -o -name 'tcl[0-9]*' -o -name 'tk[0-9]*' \
       -o -name 'itcl[0-9]*' -o -name 'thread[0-9]*' -o -name pkgconfig \) \
    -print -quit | grep -q .; then
    printf 'Unused Tcl/Tk or build metadata remains in the packaged Python runtime.\n' >&2
    exit 66
fi

# Wheels may legitimately carry universal2 Mach-O binaries even in the locked
# arm64 closure. Thin every such file deterministically before signing, while
# preserving the exact-architecture rejection for missing/wrong slices.
while IFS= read -r -d '' candidate; do
    file -b "$candidate" | grep -q 'Mach-O' || continue
    strip -S "$candidate"
    candidate_arches="$(lipo -archs "$candidate")"
    if [[ " $candidate_arches " != *" $arch "* ]]; then
        printf 'Runtime Mach-O does not contain required %s slice: %s\n' "$arch" "$candidate" >&2
        exit 66
    fi
    if [[ "$candidate_arches" != "$arch" ]]; then
        temporary_thin="$candidate.scanstudio-thin"
        lipo -thin "$arch" "$candidate" -output "$temporary_thin"
        chmod "$(stat -f '%Lp' "$candidate")" "$temporary_thin"
        mv "$temporary_thin" "$candidate"
    fi
    if [[ "$(lipo -archs "$candidate")" != "$arch" ]]; then
        printf 'Runtime Mach-O thinning failed: %s\n' "$candidate" >&2
        exit 66
    fi
done < <(find "$bundled_python" -type f -print0)

install_name_tool -id '@rpath/libpython3.13.dylib' \
    "$bundled_python/lib/libpython3.13.dylib"
runtime_sysconfig="$(find "$bundled_python/lib/python3.13" -maxdepth 1 \
    -type f -name '_sysconfigdata__darwin_darwin.py' -print -quit)"
if [[ -z "$runtime_sysconfig" ]]; then
    printf 'Packaged Python sysconfig table is missing.\n' >&2
    exit 66
fi
"$web_python" - "$runtime_sysconfig" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
contents = path.read_text()
if contents.count("/install") != 35 or contents.count("/var/folders/") != 33:
    raise SystemExit("pinned CPython sysconfig path contract changed")
contents = contents.replace("/install", "/__SCANSTUDIO_WEB_BUNDLED_PYTHON__")
contents = contents.replace(
    "/private/var/folders/", "/__SCANSTUDIO_PBS_BUILD_PATH__/"
).replace("/var/folders/", "/__SCANSTUDIO_PBS_BUILD_PATH__/")
if "/install" in contents or "/var/folders/" in contents:
    raise SystemExit("packaged CPython sysconfig path sanitization was incomplete")
path.write_text(contents)
PY

rsync -aL --delete "$frontend/" "$resources/WebFrontend/"

# Ship auditable source and complete notice inventories for everything unique
# to this optional payload. The simulator runtime contains no GPL component;
# that negative boundary is checked again below and after mounting the DMG.
rsync -aL --delete --exclude '__pycache__/' --exclude '*.pyc' \
    "$web_root/src/" "$resources/Source/scanstudio-web/src/"
for source_file in pyproject.toml uv.lock README.md; do
    install -m 644 "$web_root/$source_file" "$resources/Source/scanstudio-web/$source_file"
done
rsync -aL --delete --exclude '__tests__/' \
    "$frontend_root/src/" "$resources/Source/web-frontend/src/"
for source_file in package.json package-lock.json vite.config.ts index.html; do
    install -m 644 "$frontend_root/$source_file" "$resources/Source/web-frontend/$source_file"
done
for source_file in "$frontend_root"/tsconfig*.json; do
    [[ -f "$source_file" ]] || continue
    install -m 644 "$source_file" "$resources/Source/web-frontend/$(basename "$source_file")"
done

install -m 644 "$repo_root/LICENSE" "$resources/Licenses/ScanStudio-MIT.txt"
install -m 644 "$repo_root/THIRD_PARTY_NOTICES.md" "$resources/Licenses/THIRD_PARTY_NOTICES.md"
install -m 644 "$web_root/uv.lock" "$resources/Licenses/Python-uv.lock"
install -m 644 "$frontend_root/package-lock.json" "$resources/Licenses/npm-production/package-lock.source.json"

HOST_PYTHON="$web_python"
export HOST_PYTHON
# repo_root is resolved from this script at runtime.
# shellcheck disable=SC1091
source "$repo_root/ports/tauri/packaging/lib/common.sh"
collect_python_wheel_licenses \
    "$runtime_site_packages" "$resources/Licenses/python-wheels"
collect_npm_runtime_licenses \
    "$frontend_root/package-lock.json" \
    "$frontend_root" \
    "$resources/Licenses/npm-production/packages"
"$web_python" "$pbs_evidence_tool" collect \
    --pin "$pbs_pin" \
    --architecture "$arch" \
    --distribution-root "$pbs_distribution_root" \
    --runtime-root "$bundled_python" \
    --output "$resources/Licenses/python-build-standalone"
cat > "$resources/Licenses/README.txt" <<'EOF'
ScanStudio Web Runtime is a separately downloaded simulator-only component.

ScanStudio's gateway and browser source are MIT licensed. The payload includes
a pinned python-build-standalone CPython 3.13.14 runtime plus the exact locked
production Python dependencies and the production JavaScript dependency
closure compiled into the static frontend. The full hash-pinned license corpus
and component metadata supplied by that exact CPython distribution are under
python-build-standalone. Wheel/npm metadata and all license text present in
those exact packages are also preserved here; source for ScanStudio's
gateway/frontend is under ../Source and a CycloneDX inventory is under ../SBOM.

This payload contains no scanstudio-engine binary, hardware bridge, CoolScanPy,
libusb, python-sane, scanner device access, or motion authorization. The host
ScanStudio app supplies its exact-version engine path at launch, and the
gateway accepts only the simulator methods documented in ports/web/README.md.
EOF
write_dependency_notices_manifest "$resources/Licenses"

"$web_python" - \
    "$runtime_site_packages" \
    "$resources/Licenses/npm-production/packages/inventory.json" \
    "$resources/Licenses/python-build-standalone/inventory.json" \
    "$version" \
    "$resources/SBOM/ScanStudio-WebRuntime.cdx.json" <<'PY'
from email.parser import Parser
import json
from pathlib import Path
import sys
from urllib.parse import quote

site_packages = Path(sys.argv[1])
npm_inventory = json.loads(Path(sys.argv[2]).read_text())
pbs_inventory = json.loads(Path(sys.argv[3]).read_text())
release_version = sys.argv[4]
output = Path(sys.argv[5])

root_component = {
    "type": "application",
    "name": "ScanStudio Web Runtime",
    "version": release_version,
    "licenses": [{"license": {"id": "MIT"}}],
}
components = []
for pbs_component in pbs_inventory["components"]:
    component = {
        "type": "framework" if pbs_component["name"] == "CPython" else "library",
        "group": "python-build-standalone",
        "name": pbs_component["name"],
        "scope": pbs_component["scope"],
        "properties": [
            {"name": "scanstudio:pbs-release", "value": pbs_inventory["release"]},
            {
                "name": "scanstudio:license-files",
                "value": ",".join(item["path"] for item in pbs_component["files"]),
            },
        ],
    }
    if pbs_component["name"] == "CPython":
        component["version"] = pbs_inventory["pythonVersion"]
        component["purl"] = f"pkg:generic/cpython@{pbs_inventory['pythonVersion']}"
    expressions = pbs_component["licenseExpressions"]
    if expressions:
        component["licenses"] = [{"expression": expression} for expression in expressions]
    elif pbs_component["publicDomain"]:
        component["licenses"] = [{"license": {"name": "Public Domain"}}]
    elif pbs_component["scope"] == "required":
        raise SystemExit(
            f"required embedded Python component lacks license attribution: "
            f"{pbs_component['name']}"
        )
    components.append(component)
legacy_python_license_pins = {
    ("h11", "0.16.0"): "MIT",
    ("pydantic", "1.10.26"): "MIT",
}
seen_legacy_python_license_pins = set()
python_count = 0
for dist_info in sorted(site_packages.glob("*.dist-info")):
    metadata_path = dist_info / "METADATA"
    if not metadata_path.is_file():
        raise SystemExit(f"missing Python METADATA: {dist_info.name}")
    metadata = Parser().parsestr(metadata_path.read_text(errors="strict"))
    name = metadata.get("Name")
    version = metadata.get("Version")
    if not name or not version:
        raise SystemExit(f"incomplete Python METADATA: {dist_info.name}")
    component = {
        "type": "library",
        "group": "python",
        "name": name,
        "version": version,
        "purl": f"pkg:pypi/{name.lower().replace('_', '-')}@{version}",
    }
    normalized_name = name.casefold().replace("_", "-")
    identity = (normalized_name, version)
    expression_values = metadata.get_all("License-Expression", [])
    legacy_values = metadata.get_all("License", [])
    if len(expression_values) > 1 or len(legacy_values) > 1:
        raise SystemExit(f"ambiguous Python license metadata: {name} {version}")
    if expression_values:
        if identity in legacy_python_license_pins:
            raise SystemExit(
                f"legacy Python license pin unexpectedly gained an expression: "
                f"{name} {version}"
            )
        license_expression = expression_values[0].strip()
        if not license_expression:
            raise SystemExit(f"empty Python license expression: {name} {version}")
    else:
        expected_legacy = legacy_python_license_pins.get(identity)
        actual_legacy = legacy_values[0].strip() if legacy_values else None
        if expected_legacy is None or actual_legacy != expected_legacy:
            raise SystemExit(
                f"Python component lacks reviewed license attribution: {name} {version}"
            )
        license_expression = expected_legacy
        seen_legacy_python_license_pins.add(identity)
    component["licenses"] = [{"expression": license_expression}]
    components.append(component)
    python_count += 1

if seen_legacy_python_license_pins != set(legacy_python_license_pins):
    raise SystemExit("reviewed legacy Python license closure is missing or stale")

npm_count = 0
for package in npm_inventory.get("packages", []):
    package_name = package["name"]
    package_version = package["version"]
    if package_name.startswith("@") and "/" in package_name:
        scope, unscoped_name = package_name[1:].split("/", 1)
        npm_purl_name = f"%40{quote(scope, safe='')}/{quote(unscoped_name, safe='')}"
    else:
        npm_purl_name = quote(package_name, safe="")
    component = {
        "type": "library",
        "group": "npm",
        "name": package_name,
        "version": package_version,
        "purl": f"pkg:npm/{npm_purl_name}@{quote(package_version, safe='')}",
    }
    license_expression = package.get("licenseExpression")
    if not isinstance(license_expression, str) or not license_expression.strip():
        raise SystemExit(
            f"npm component lacks license attribution: {package_name} {package_version}"
        )
    component["licenses"] = [{"expression": license_expression.strip()}]
    components.append(component)
    npm_count += 1

if python_count == 0 or npm_count == 0:
    raise SystemExit("dependency-complete SBOM requires non-empty Python and npm closures")
components.sort(key=lambda item: (item.get("group", ""), item["name"], item.get("version", "")))
payload = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "metadata": {"component": root_component},
    "components": components,
}
output.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY

bundle_short_version="${version%%-*}"
cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>scanstudio-web-runtime</string>
    <key>CFBundleIdentifier</key><string>dev.scanstudio.live.web-runtime</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>ScanStudioWebRuntime</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$bundle_short_version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF

"$web_python" - "$version" "$arch" "$resources/runtime.json" <<'PY'
import json
from pathlib import Path
import sys

version, architecture, output = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "product": "ScanStudio Web Runtime",
    "channel": "simulator-preview",
    "runtimeVersion": version,
    "hostVersion": version,
    "architecture": architecture,
    "engineProtocolVersion": 1,
    "simulatorOnly": True,
    "bundlesEngine": False,
    "bundlesBridge": False,
    "hardwareEnabled": False,
}
Path(output).write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY

xcrun clang \
    -arch "$arch" \
    -mmacosx-version-min=14.0 \
    -Os -Wall -Wextra -Werror \
    "$launcher_source" \
    -o "$contents/MacOS/scanstudio-web-runtime"
strip -S "$contents/MacOS/scanstudio-web-runtime"

if find "$bundle" -type l -print -quit | grep -q .; then
    printf 'Refusing a runtime bundle containing symlinks.\n' >&2
    exit 1
fi
for forbidden_path in \
    "$contents/MacOS/scanstudio-engine" \
    "$resources/BridgeRuntime" \
    "$resources/WebRuntime" \
    "$resources/CorrespondingSource/scanstudio-bridge" \
    "$resources/CorrespondingSource/coolscanpy"; do
    if [[ -e "$forbidden_path" || -L "$forbidden_path" ]]; then
        printf 'Refusing forbidden native/hardware payload path: %s\n' "$forbidden_path" >&2
        exit 1
    fi
done
if find "$bundle" \
    \( -iname '*coolscanpy*' -o -iname '*scanstudio-bridge*' \
       -o -iname '*libusb*' -o -name 'sane.py' -o -name 'scanstudio-engine' \) \
    -print -quit | grep -q .; then
    printf 'Refusing a runtime bundle containing a bridge, hardware library, or engine path.\n' >&2
    exit 1
fi
chmod -R go-w "$bundle"
if find "$bundle" -perm -0022 -print -quit | grep -q .; then
    printf 'Refusing a group- or world-writable runtime path.\n' >&2
    exit 1
fi
private_path_matches="$(
    grep -rEl '/Users/|/var/folders/|/private/var/folders/' "$bundle" 2>/dev/null || true
)"
if [[ -n "$private_path_matches" ]]; then
    printf 'Refusing a runtime bundle containing a developer or temporary build path:\n%s\n' \
        "$private_path_matches" >&2
    exit 1
fi

PYTHONDONTWRITEBYTECODE=1 "$bundled_python/bin/python3.13" -I -c \
    'import fastapi, scanstudio_web.cli, uvicorn, wsproto; assert fastapi and uvicorn and wsproto'
find "$bundle" -type f -name '*.pyc' -delete
find "$bundle" -type d -name '__pycache__' -empty -delete

# Sign every nested Mach-O before the launcher and outer bundle. Timestamped
# Developer ID signatures are mandatory here; there is no ad-hoc code path.
while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$contents/MacOS/scanstudio-web-runtime" ]] && continue
    if file -b "$candidate" | grep -q 'Mach-O'; then
        codesign --force --options runtime --timestamp \
            --sign "$codesign_identity" "$candidate"
        codesign --verify --strict "$candidate"
        if [[ "$(lipo -archs "$candidate")" != "$arch" ]]; then
            printf 'Nested runtime architecture mismatch: %s\n' "$candidate" >&2
            exit 1
        fi
    fi
done < <(find "$bundle" -type f -print0)
codesign --force --options runtime --timestamp \
    --identifier 'dev.scanstudio.live.web-runtime' \
    --sign "$codesign_identity" \
    "$contents/MacOS/scanstudio-web-runtime"
codesign --force --options runtime --timestamp \
    --sign "$codesign_identity" "$bundle"
codesign --verify --deep --strict "$bundle"

hdiutil create -quiet \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "ScanStudio Web Runtime $version" \
    -srcfolder "$payload_root" \
    "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null
hdiutil attach -quiet -readonly -nobrowse \
    -mountpoint "$mount_point" "$temporary_dmg"
mounted=1
if [[ ! -d "$mount_point/ScanStudioWebRuntime.bundle" ]]; then
    printf 'Mounted runtime image does not contain the expected bundle.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$mount_point/ScanStudioWebRuntime.bundle"
hdiutil detach -quiet "$mount_point"
mounted=0

codesign --force --timestamp --sign "$codesign_identity" "$temporary_dmg"
codesign --verify --strict "$temporary_dmg"
hdiutil verify "$temporary_dmg" >/dev/null
mv "$temporary_dmg" "$output"

printf 'Packaged %s\n' "$output"
printf 'SHA-256 %s\n' "$(shasum -a 256 "$output" | awk '{print $1}')"
printf 'Notarization and stapling are still required before manifest emission.\n'
