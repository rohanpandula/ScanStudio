#!/usr/bin/env bash
# Shared packaging helper library for the ScanStudio cross-platform port.
# Sourced-only bash library (never executed directly): consume via
#   source "$(dirname "$0")/../lib/common.sh"   (or your own path)
# Ports the allowlist/license-collection logic from the macOS reference
# implementation so the Linux and Windows package scripts (09-02/09-03)
# share one copy instead of re-deriving it.
set -euo pipefail

HOST_PYTHON="${HOST_PYTHON:-python3}"

if [[ "$(basename "$0")" == "common.sh" ]]; then
    printf 'common.sh is a bash library and must be sourced, not executed.\n' >&2
    exit 1
fi

# PORTS package_app.sh:20-27
require_directory() {
    local label="$1"
    local path="$2"
    if [[ ! -d "$path" ]]; then
        printf 'ScanStudio package prerequisite missing: %s directory "%s".\n' "$label" "$path" >&2
        exit 66
    fi
}

# PORTS package_app.sh:20-27 (file variant of the same guard)
require_file() {
    local label="$1"
    local path="$2"
    if [[ ! -f "$path" ]]; then
        printf 'ScanStudio package prerequisite missing: %s file "%s".\n' "$label" "$path" >&2
        exit 66
    fi
}

# PORTS package_app.sh:34-49
copy_corresponding_source() {
    local source="$1"
    local destination="$2"
    mkdir -p "$destination"
    local directory
    for directory in src tests scripts tools; do
        [[ -d "$source/$directory" ]] || continue
        mkdir -p "$destination/$directory"
        cp -Rp "$source/$directory/." "$destination/$directory/"
        find "$destination/$directory" -type d \
            \( -name '__pycache__' -o -name '*.egg-info' \) -prune -exec rm -rf -- {} +
    done
    local file
    for file in pyproject.toml uv.lock README.md CHANGELOG.md LICENSE COPYING; do
        [[ -f "$source/$file" ]] || continue
        install -m 644 "$source/$file" "$destination/$file"
    done
}

# Records the package-time identity of every shipped GPL source snapshot.
# Standalone checkouts carry their own HEAD. Vendored directories instead
# carry the containing repository's HEAD plus a deterministic source-tree
# digest; `git -C` must never mislabel the parent repository as the vendor's
# own checkout.
write_provenance_json() {
    local output_path="$1"; shift
    "$HOST_PYTHON" - "$output_path" "$@" <<'PYTHON'
import json
import hashlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

output_path = sys.argv[1]
triples = sys.argv[2:]
if len(triples) % 3 != 0:
    raise SystemExit("write_provenance_json expects name/path/version triples")

sources = {}
for i in range(0, len(triples), 3):
    name, path, version = triples[i], triples[i + 1], triples[i + 2]
    source_path = Path(path).resolve()
    head_sha = None
    containing_repository_head_sha = None
    try:
        root_result = subprocess.run(
            ["git", "-C", str(source_path), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
        head_result = subprocess.run(
            ["git", "-C", str(source_path), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        if root_result.returncode == 0 and head_result.returncode == 0:
            repository_root = Path(root_result.stdout.strip()).resolve()
            repository_head = head_result.stdout.strip() or None
            if repository_root == source_path:
                head_sha = repository_head
            else:
                containing_repository_head_sha = repository_head
    except Exception:
        pass

    digest = hashlib.sha256()
    ignored_parts = {
        ".git", ".venv", "target", "node_modules", "__pycache__",
        ".pytest_cache", ".mypy_cache",
    }
    files = sorted(
        candidate for candidate in source_path.rglob("*")
        if candidate.is_file()
        and not any(part in ignored_parts for part in candidate.relative_to(source_path).parts)
        and candidate.suffix != ".pyc"
    )
    for candidate in files:
        relative = candidate.relative_to(source_path).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        with candidate.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)

    sources[name] = {
        "version": version,
        "head_sha": head_sha,
        "containing_repository_head_sha": containing_repository_head_sha,
        "tree_sha256": digest.hexdigest(),
    }

payload = {
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "sources": sources,
}
with open(output_path, "w") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PYTHON
}

# PORTS package_app.sh:259-277 — copies wheel METADATA plus any
# LICENSE*/COPYING*/NOTICE* files and a licenses/ subdir from every
# *.dist-info directory into destination/<dist-info-name>/, with the
# imagecodecs in-package licenses/ corpus surfaced as runtime-licenses/.
collect_python_wheel_licenses() {
    local site_packages="$1"
    local destination="$2"
    local dist_info dist_name notice_file
    mkdir -p "$destination"
    for dist_info in "$site_packages"/*.dist-info; do
        [[ -d "$dist_info" ]] || continue
        dist_name="$(basename "$dist_info")"
        mkdir -p "$destination/$dist_name"
        [[ -f "$dist_info/METADATA" ]] && install -m 644 "$dist_info/METADATA" "$destination/$dist_name/METADATA"
        while IFS= read -r -d '' notice_file; do
            install -m 644 "$notice_file" "$destination/$dist_name/$(basename "$notice_file")"
        done < <(find "$dist_info" -maxdepth 1 -type f \
            \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0)
        if [[ -d "$dist_info/licenses" ]]; then
            mkdir -p "$destination/$dist_name/licenses"
            cp -Rp "$dist_info/licenses/." "$destination/$dist_name/licenses/"
        fi
    done
    local imagecodecs_dist
    imagecodecs_dist="$(find "$site_packages" -maxdepth 1 -type d -name 'imagecodecs-*.dist-info' -print -quit)"
    if [[ -n "$imagecodecs_dist" && -d "$site_packages/imagecodecs/licenses" ]]; then
        mkdir -p "$destination/$(basename "$imagecodecs_dist")/runtime-licenses"
        cp -Rp "$site_packages/imagecodecs/licenses/." \
            "$destination/$(basename "$imagecodecs_dist")/runtime-licenses/"
    fi
}

# Copies package metadata and full license/notice files for the exact
# production dependency closure recorded in package-lock.json. Callers must
# run `npm ci --omit=dev --ignore-scripts` first so the source tree contains
# only the runtime packages compiled into the frontend bundle.
collect_npm_runtime_licenses() {
    local lockfile="$1"
    local app_root="$2"
    local destination="$3"
    mkdir -p "$destination"
    "$HOST_PYTHON" - "$lockfile" "$app_root" "$destination" <<'PYTHON'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import sys

lock_path, app_root, destination = map(Path, sys.argv[1:])
app_root = app_root.resolve()
destination.mkdir(parents=True, exist_ok=True)
lock = json.loads(lock_path.read_text())
collected = []


def is_notice_name(name: str) -> bool:
    return name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "AUTHORS"))


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


# @tauri-apps/plugin-dialog 2.7.2 and @tauri-apps/plugin-os 2.3.2 each publish
# an SPDX copyright declaration but not the full MIT/Apache terms (same
# byte-identical LICENSE.spdx boilerplate for both -- both are published from
# the tauri-apps/plugins-workspace monorepo, whose root carries LICENSE_MIT
# and LICENSE_APACHE-2.0; GitHub's own repo-level license detection confirms
# "Apache-2.0, MIT licenses found" there). Their exact sibling @tauri-apps/api
# 2.11.1 package -- published from the same monorepo -- carries those reviewed
# full texts already. Hashes make this fallback fail closed if either upstream
# file changes.
reviewed_fallbacks = {
    ("@tauri-apps/plugin-dialog", "2.7.2"): {
        "declaration": ("LICENSE.spdx", "eb8a6c84630461b352badcab1dbe5d0168c56d377358b2b8c86b51003272d5ef"),
        "fullTexts": [
            (
                "node_modules/@tauri-apps/api/LICENSE_MIT",
                "9dd42ea92cff2ede5cd477cbfcce051b2d0115c0ac7f368ee88cb545055dff1d",
                "FALLBACK-LICENSE_MIT",
            ),
            (
                "node_modules/@tauri-apps/api/LICENSE_APACHE-2.0",
                "0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594",
                "FALLBACK-LICENSE_APACHE-2.0",
            ),
        ],
    },
    ("@tauri-apps/plugin-os", "2.3.2"): {
        "declaration": ("LICENSE.spdx", "eb8a6c84630461b352badcab1dbe5d0168c56d377358b2b8c86b51003272d5ef"),
        "fullTexts": [
            (
                "node_modules/@tauri-apps/api/LICENSE_MIT",
                "9dd42ea92cff2ede5cd477cbfcce051b2d0115c0ac7f368ee88cb545055dff1d",
                "FALLBACK-LICENSE_MIT",
            ),
            (
                "node_modules/@tauri-apps/api/LICENSE_APACHE-2.0",
                "0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594",
                "FALLBACK-LICENSE_APACHE-2.0",
            ),
        ],
    },
}


for package_path, locked in sorted(lock.get("packages", {}).items()):
    if not package_path.startswith("node_modules/") or locked.get("dev", False):
        continue

    source = (app_root / package_path).resolve()
    try:
        source.relative_to(app_root)
    except ValueError as error:
        raise SystemExit(f"npm package path escapes app root: {package_path}") from error

    if not source.is_dir():
        if locked.get("optional", False):
            continue
        raise SystemExit(f"locked production npm package is not installed: {package_path}")

    package_json_path = source / "package.json"
    if not package_json_path.is_file():
        raise SystemExit(f"missing package.json for production npm package: {package_path}")
    package_json = json.loads(package_json_path.read_text())
    name = package_json.get("name")
    version = package_json.get("version")
    if not name or version != locked.get("version"):
        raise SystemExit(
            f"npm identity mismatch for {package_path}: "
            f"installed={name}@{version}, locked={locked.get('version')}"
        )

    directory_name = f"{name.replace('/', '__')}-{version}"
    target = destination / directory_name
    if target.exists():
        raise SystemExit(f"duplicate npm notice target: {directory_name}")
    target.mkdir(parents=True)
    shutil.copy2(package_json_path, target / "package.json")

    notices = sorted(
        candidate for candidate in source.iterdir()
        if candidate.is_file() and is_notice_name(candidate.name)
    )
    notice_records = []
    for notice in notices:
        shutil.copy2(notice, target / notice.name)
        notice_records.append({
            "file": f"{directory_name}/{notice.name}",
            "sha256": digest(target / notice.name),
            "bytes": (target / notice.name).stat().st_size,
            "kind": "upstream",
        })

    full_texts = [notice for notice in notices if not notice.name.lower().endswith(".spdx")]
    if not full_texts:
        fallback = reviewed_fallbacks.get((name, version))
        if fallback is None:
            raise SystemExit(f"missing full license text for npm package {name} {version}")
        declaration_name, declaration_sha = fallback["declaration"]
        declaration = source / declaration_name
        if not declaration.is_file() or digest(declaration) != declaration_sha:
            raise SystemExit(f"reviewed SPDX declaration changed for npm package {name} {version}")
        for relative_source, expected_sha, output_name in fallback["fullTexts"]:
            full_text_source = app_root / relative_source
            if not full_text_source.is_file() or digest(full_text_source) != expected_sha:
                raise SystemExit(f"reviewed full-text fallback changed: {relative_source}")
            output_path = target / output_name
            shutil.copy2(full_text_source, output_path)
            notice_records.append({
                "file": f"{directory_name}/{output_name}",
                "sha256": digest(output_path),
                "bytes": output_path.stat().st_size,
                "kind": "reviewed-full-text-fallback",
            })

    collected.append({
        "packagePath": package_path,
        "name": name,
        "version": version,
        "integrity": locked.get("integrity"),
        "licenseExpression": package_json.get("license", locked.get("license")),
        "directory": directory_name,
        "noticeFiles": notice_records,
    })

if not collected:
    raise SystemExit("production npm notice collection was empty")

shutil.copy2(lock_path, destination / "package-lock.json")
inventory = {
    "sourceLockfile": lock_path.name,
    "sourceLockfileSha256": digest(lock_path),
    "packageCount": len(collected),
    "packages": collected,
}
(destination / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
PYTHON
}

# Generates one complete, full-text cargo-about report for an exact Rust lock.
# The pinned tool version and --fail make missing/ambiguous license data a hard
# packaging failure instead of silently dropping a crate.
generate_rust_dependency_report() {
    local manifest_path="$1"
    local lockfile_path="$2"
    local report_path="$3"
    local copied_lock_path="$4"
    local about_config="$5"
    local about_template="$6"

    local about_version
    about_version="$(cargo about --version 2>/dev/null || true)"
    if [[ "$about_version" != "cargo-about 0.9.1" ]]; then
        printf 'ScanStudio packaging requires cargo-about 0.9.1; found %s.\n' "${about_version:-nothing}" >&2
        exit 66
    fi

    install -m 644 "$lockfile_path" "$copied_lock_path"
    cargo about generate --locked --fail \
        --config "$about_config" \
        --manifest-path "$manifest_path" \
        --output-file "$report_path" \
        "$about_template"
    require_file "generated Rust dependency report" "$report_path"
    if [[ ! -s "$report_path" ]] || ! grep -Fq 'License:' "$report_path"; then
        printf 'Generated Rust dependency report is empty or malformed: %s\n' "$report_path" >&2
        exit 66
    fi
}

# Hashes every file in Licenses/ except the manifest itself. The extracted
# AppImage, tarball, installer, and portable zip verifiers recompute this exact
# set so omitted, added, or modified dependency notices fail closed.
write_dependency_notices_manifest() {
    local licenses_root="$1"
    "$HOST_PYTHON" - "$licenses_root" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
manifest_path = root / "dependency-notices-manifest.json"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


files = {}
for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
    if path == manifest_path:
        continue
    relative = path.relative_to(root).as_posix()
    files[relative] = {"sha256": digest(path), "bytes": path.stat().st_size}

if not files:
    raise SystemExit("dependency notice manifest would be empty")
manifest_path.write_text(json.dumps({"version": 1, "files": files}, indent=2) + "\n")
PYTHON
}

# NEW — portable SHA-256 verification via python3 stdlib hashlib (chunked,
# case-insensitive), so behavior is identical on macOS and Linux CI; the
# python-build-standalone runtime pin in STACK.md is verified this way.
verify_sha256() {
    local expected_hex="$1"
    local path="$2"
    local actual_hex want
    actual_hex="$("$HOST_PYTHON" -c '
import hashlib, sys
hash = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(65536), b""):
        hash.update(chunk)
print(hash.hexdigest())
' "$path")"
    want="$(printf '%s' "$expected_hex" | tr '[:upper:]' '[:lower:]')"
    if [[ "$actual_hex" != "$want" ]]; then
        printf 'SHA-256 mismatch for %s: expected %s, got %s.\n' "$path" "$expected_hex" "$actual_hex" >&2
        return 1
    fi
}

# NEW — CONTEXT.md's no-absolute-developer-path bundle rule (analogous to
# package_app.sh:100-103's machine-absolute-linkage refusal): every
# "/Users/" match must be absent. Any match is printed to stderr and this
# returns 1.
assert_no_developer_paths() {
    local root="$1"
    local matches
    matches="$(grep -rl '/Users/' "$root" 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
        printf 'Developer path "/Users/" found in bundle:\n%s\n' "$matches" >&2
        return 1
    fi
    return 0
}
