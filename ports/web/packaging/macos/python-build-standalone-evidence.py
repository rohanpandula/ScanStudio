#!/usr/bin/env python3
"""Collect and verify fail-closed python-build-standalone license evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from typing import Any


ROOT_KEYS = {
    "allowedMissingMetadataLicensePaths",
    "assets",
    "buildOptions",
    "licenseFiles",
    "metadataVersion",
    "provider",
    "pythonExecutableRelativePath",
    "pythonVersion",
    "release",
    "requiredRuntimeComponents",
    "schemaVersion",
    "supplementalLicenseFiles",
}
ASSET_KEYS = {"bytes", "metadataSha256", "name", "sha256", "targetTriple"}
LICENSE_KEYS = {"bytes", "component", "path", "sha256"}
SUPPLEMENTAL_LICENSE_KEYS = {
    "bytes",
    "componentLicenseExpressions",
    "components",
    "path",
    "sha256",
    "url",
}
SUPPORTED_SUPPLEMENTAL_LICENSE_EXPRESSIONS = {"BSD-2-Clause", "MIT"}
ARCHITECTURES = {"arm64", "x86_64"}


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(), object_pairs_hook=strict_object)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(f"could not read strict JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"JSON root must be an object: {path}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_hex_digest(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def require_plain_name(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or "/" in value
        or "\\" in value
        or not value.isascii()
    ):
        raise SystemExit(f"{label} must be one non-empty ASCII path component")
    return value


def require_component_name(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not value
        or not value.isascii()
        or any(ord(character) < 32 for character in value)
    ):
        raise SystemExit("license component must be a non-empty printable ASCII name")
    return value


def validate_pin(pin_path: Path) -> dict[str, Any]:
    pin = load_json(pin_path)
    if set(pin) != ROOT_KEYS or pin["schemaVersion"] != 1:
        raise SystemExit("python-build-standalone pin does not match schema version 1")
    if pin["provider"] != "astral-sh/python-build-standalone":
        raise SystemExit("unexpected python-build-standalone provider")
    if (
        not isinstance(pin["release"], str)
        or not pin["release"].isdigit()
        or len(pin["release"]) != 8
    ):
        raise SystemExit("python-build-standalone release must be YYYYMMDD digits")
    if pin["pythonVersion"] != "3.13.14" or pin["buildOptions"] != "pgo+lto":
        raise SystemExit(
            "optional runtime Python/build option pin changed unexpectedly"
        )
    if pin["metadataVersion"] != "8":
        raise SystemExit("unsupported python-build-standalone metadata version")
    if pin["pythonExecutableRelativePath"] != "install/bin/python3.13":
        raise SystemExit("unexpected pinned Python executable path")

    assets = pin["assets"]
    if not isinstance(assets, dict) or set(assets) != ARCHITECTURES:
        raise SystemExit("pin must contain exactly arm64 and x86_64 assets")
    for architecture, asset in assets.items():
        if not isinstance(asset, dict) or set(asset) != ASSET_KEYS:
            raise SystemExit(f"malformed pinned asset for {architecture}")
        target = (
            "aarch64-apple-darwin" if architecture == "arm64" else "x86_64-apple-darwin"
        )
        expected_name = (
            f"cpython-{pin['pythonVersion']}+{pin['release']}-{target}-"
            f"{pin['buildOptions']}-full.tar.zst"
        )
        if asset["name"] != expected_name or asset["targetTriple"] != target:
            raise SystemExit(f"pinned asset identity mismatch for {architecture}")
        if not is_hex_digest(asset["sha256"]) or not is_hex_digest(
            asset["metadataSha256"]
        ):
            raise SystemExit(f"pinned digest is malformed for {architecture}")
        if (
            not isinstance(asset["bytes"], int)
            or isinstance(asset["bytes"], bool)
            or asset["bytes"] <= 0
        ):
            raise SystemExit(f"pinned byte size is malformed for {architecture}")

    license_files = pin["licenseFiles"]
    if not isinstance(license_files, list) or not license_files:
        raise SystemExit("pinned distribution license corpus is empty")
    license_names: set[str] = set()
    components: set[str] = set()
    for entry in license_files:
        if not isinstance(entry, dict) or set(entry) != LICENSE_KEYS:
            raise SystemExit("malformed pinned distribution license entry")
        name = require_plain_name(entry["path"], "license path")
        component = require_component_name(entry["component"])
        if name in license_names:
            raise SystemExit(f"duplicate pinned distribution license: {name}")
        license_names.add(name)
        components.add(component)
        if not is_hex_digest(entry["sha256"]):
            raise SystemExit(f"malformed license digest: {name}")
        if (
            not isinstance(entry["bytes"], int)
            or isinstance(entry["bytes"], bool)
            or entry["bytes"] <= 0
        ):
            raise SystemExit(f"malformed license byte size: {name}")

    required = pin["requiredRuntimeComponents"]
    if (
        not isinstance(required, list)
        or required != sorted(required)
        or len(required) != len(set(required))
    ):
        raise SystemExit("required runtime component pin is malformed")
    missing_paths = pin["allowedMissingMetadataLicensePaths"]
    if (
        not isinstance(missing_paths, list)
        or missing_paths != sorted(missing_paths)
        or len(missing_paths) != len(set(missing_paths))
        or any(
            not isinstance(path, str) or not path.startswith("licenses/LICENSE.")
            for path in missing_paths
        )
    ):
        raise SystemExit("allowed missing metadata-license pin is malformed")
    supplemental = pin["supplementalLicenseFiles"]
    if not isinstance(supplemental, list) or not supplemental:
        raise SystemExit("supplemental CPython incorporated-code notices are missing")
    supplemental_names: set[str] = set()
    for entry in supplemental:
        if not isinstance(entry, dict) or set(entry) != SUPPLEMENTAL_LICENSE_KEYS:
            raise SystemExit("malformed supplemental license entry")
        name = require_plain_name(entry["path"], "supplemental license path")
        if name in supplemental_names or name in license_names:
            raise SystemExit(f"duplicate supplemental license path: {name}")
        supplemental_names.add(name)
        if not is_hex_digest(entry["sha256"]):
            raise SystemExit(f"malformed supplemental license digest: {name}")
        if (
            not isinstance(entry["bytes"], int)
            or isinstance(entry["bytes"], bool)
            or entry["bytes"] <= 0
        ):
            raise SystemExit(f"malformed supplemental license byte size: {name}")
        entry_components = entry["components"]
        if (
            not isinstance(entry_components, list)
            or entry_components != sorted(entry_components)
            or len(entry_components) != len(set(entry_components))
            or any(
                require_component_name(component) != component
                for component in entry_components
            )
        ):
            raise SystemExit(f"malformed supplemental component list: {name}")
        component_expressions = entry["componentLicenseExpressions"]
        if (
            not isinstance(component_expressions, dict)
            or set(component_expressions) != set(entry_components)
            or any(
                expression not in SUPPORTED_SUPPLEMENTAL_LICENSE_EXPRESSIONS
                for expression in component_expressions.values()
            )
        ):
            raise SystemExit(
                f"supplemental component license expressions are not exact: {name}"
            )
        components.update(entry_components)
        expected_url = f"https://raw.githubusercontent.com/python/cpython/v{pin['pythonVersion']}/Doc/license.rst"
        if entry["url"] != expected_url:
            raise SystemExit(
                "supplemental CPython license URL is not exact-version pinned"
            )
    if not set(required).issubset(components):
        raise SystemExit(
            "required runtime component is absent from all license evidence"
        )
    return pin


def validate_distribution(
    pin: dict[str, Any], architecture: str, distribution_root: Path
) -> tuple[dict[str, Any], Path]:
    if architecture not in ARCHITECTURES:
        raise SystemExit(f"unsupported architecture: {architecture}")
    if not distribution_root.is_dir() or distribution_root.is_symlink():
        raise SystemExit(
            "python-build-standalone distribution root is missing or linked"
        )
    metadata_path = distribution_root / "PYTHON.json"
    licenses_root = distribution_root / "licenses"
    if not metadata_path.is_file() or metadata_path.is_symlink():
        raise SystemExit("pinned distribution PYTHON.json is missing or linked")
    if not licenses_root.is_dir() or licenses_root.is_symlink():
        raise SystemExit("pinned distribution licenses directory is missing or linked")
    supplemental_root = distribution_root / "supplemental-licenses"
    if not supplemental_root.is_dir() or supplemental_root.is_symlink():
        raise SystemExit("supplemental CPython license directory is missing or linked")

    asset = pin["assets"][architecture]
    if sha256(metadata_path) != asset["metadataSha256"]:
        raise SystemExit(
            "python-build-standalone metadata digest does not match the pin"
        )
    metadata = load_json(metadata_path)
    expected_scalars = {
        "version": pin["metadataVersion"],
        "python_version": pin["pythonVersion"],
        "python_major_minor_version": "3.13",
        "python_exe": pin["pythonExecutableRelativePath"],
        "build_options": pin["buildOptions"],
        "target_triple": asset["targetTriple"],
        "license_path": "licenses/LICENSE.cpython.txt",
    }
    for key, expected in expected_scalars.items():
        if metadata.get(key) != expected:
            raise SystemExit(
                f"python-build-standalone metadata {key} does not match the pin"
            )
    if not isinstance(metadata.get("licenses"), list) or not metadata["licenses"]:
        raise SystemExit("CPython metadata license expressions are missing")
    build_info = metadata.get("build_info")
    if not isinstance(build_info, dict) or not isinstance(
        build_info.get("extensions"), dict
    ):
        raise SystemExit("python-build-standalone extension metadata is missing")

    expected_entries = {entry["path"]: entry for entry in pin["licenseFiles"]}
    actual_paths = list(licenses_root.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in actual_paths):
        raise SystemExit("distribution licenses must contain regular files only")
    actual_names = {path.name for path in actual_paths}
    if actual_names != set(expected_entries):
        missing = sorted(set(expected_entries) - actual_names)
        extra = sorted(actual_names - set(expected_entries))
        raise SystemExit(
            f"distribution license corpus mismatch; missing={missing}, extra={extra}"
        )
    for name, entry in expected_entries.items():
        path = licenses_root / name
        if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise SystemExit(f"distribution license changed: {name}")
    expected_supplemental = {
        entry["path"]: entry for entry in pin["supplementalLicenseFiles"]
    }
    actual_supplemental_paths = list(supplemental_root.iterdir())
    if any(
        path.is_symlink() or not path.is_file() for path in actual_supplemental_paths
    ) or {path.name for path in actual_supplemental_paths} != set(
        expected_supplemental
    ):
        raise SystemExit("supplemental CPython license corpus is not exact")
    for name, entry in expected_supplemental.items():
        path = supplemental_root / name
        if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise SystemExit(f"supplemental CPython license changed: {name}")

    declared_paths = {metadata["license_path"]}
    for records in build_info["extensions"].values():
        if not isinstance(records, list):
            raise SystemExit("extension metadata records must be arrays")
        for record in records:
            if not isinstance(record, dict):
                raise SystemExit("extension metadata record must be an object")
            license_paths = record.get("license_paths", [])
            links = record.get("links", [])
            if not isinstance(license_paths, list) or not isinstance(links, list):
                raise SystemExit("extension license/link metadata must be arrays")
            if (
                any(
                    isinstance(link, dict) and link.get("path_static") for link in links
                )
                and not license_paths
            ):
                raise SystemExit(
                    "statically linked extension dependency has no declared license path"
                )
            declared_paths.update(license_paths)
    actual_metadata_paths = {f"licenses/{name}" for name in actual_names}
    missing_declared = declared_paths - actual_metadata_paths
    if missing_declared != set(pin["allowedMissingMetadataLicensePaths"]):
        raise SystemExit(
            "metadata-declared license omissions changed; "
            f"found={sorted(missing_declared)}"
        )
    # This exact upstream metadata advertises zlib-ng as an alternative notice
    # for the zlib extension, but the macOS artifact links the OS `libz`
    # (`system: true`) and supplies the applicable zlib notice. Keep the one
    # absent alternative explicit and prove it is not a statically embedded
    # dependency; any other shape is a hard failure.
    if pin["allowedMissingMetadataLicensePaths"]:
        if pin["allowedMissingMetadataLicensePaths"] != [
            "licenses/LICENSE.zlib-ng.txt"
        ]:
            raise SystemExit("unsupported absent distribution-license exception")
        zlib_records = build_info["extensions"].get("zlib")
        if not isinstance(zlib_records, list) or len(zlib_records) != 1:
            raise SystemExit("zlib metadata shape changed")
        zlib_record = zlib_records[0]
        if (
            zlib_record.get("license_paths")
            != ["licenses/LICENSE.zlib-ng.txt", "licenses/LICENSE.zlib.txt"]
            or zlib_record.get("licenses") != ["Zlib"]
            or zlib_record.get("links") != [{"name": "z", "system": True}]
        ):
            raise SystemExit(
                "absent zlib-ng notice is no longer proven to be an unlinked alternative"
            )
    return metadata, metadata_path


def sanitize_metadata(metadata: dict[str, Any], source_sha256: str) -> dict[str, Any]:
    def sanitize(value: Any) -> Any:
        if isinstance(value, dict):
            return {key: sanitize(item) for key, item in value.items()}
        if isinstance(value, list):
            return [sanitize(item) for item in value]
        if isinstance(value, str):
            return (
                value.replace("/private/var/folders/", "/__SCANSTUDIO_PBS_BUILD__/")
                .replace("/var/folders/", "/__SCANSTUDIO_PBS_BUILD__/")
                .replace("/Users/runner/", "/__SCANSTUDIO_PBS_USER__/")
            )
        return value

    sanitized = sanitize(metadata)
    sanitized["scanstudio_evidence"] = {
        "sanitization": "macos-temporary-build-root-v1",
        "sourceMetadataSha256": source_sha256,
    }
    raw = canonical_bytes(sanitized)
    if any(marker in raw for marker in (b"/Users/", b"/var/folders/")):
        raise SystemExit("Python distribution metadata sanitization was incomplete")
    return sanitized


def record_is_shipped(record: dict[str, Any], runtime_root: Path) -> bool:
    shared = record.get("shared_lib")
    if shared is None:
        return True
    if (
        not isinstance(shared, str)
        or not shared.startswith("install/")
        or ".." in Path(shared).parts
    ):
        raise SystemExit(
            f"unsafe shared library path in distribution metadata: {shared!r}"
        )
    path = runtime_root / Path(shared).relative_to("install")
    return path.is_file() and not path.is_symlink()


def build_inventory(
    pin: dict[str, Any],
    architecture: str,
    metadata: dict[str, Any],
    runtime_root: Path,
) -> dict[str, Any]:
    if not runtime_root.is_dir() or runtime_root.is_symlink():
        raise SystemExit("packaged Python runtime root is missing or linked")
    component_by_path = {
        entry["path"]: entry["component"] for entry in pin["licenseFiles"]
    }
    details: dict[str, dict[str, Any]] = {}
    for entry in pin["licenseFiles"]:
        component = entry["component"]
        details.setdefault(
            component,
            {
                "declaredByModules": set(),
                "files": [],
                "licenseExpressions": set(),
                "publicDomain": False,
                "requiredByModules": set(),
            },
        )["files"].append(
            {"bytes": entry["bytes"], "path": entry["path"], "sha256": entry["sha256"]}
        )
    for entry in pin["supplementalLicenseFiles"]:
        file_record = {
            "bytes": entry["bytes"],
            "path": f"supplemental-licenses/{entry['path']}",
            "sha256": entry["sha256"],
        }
        for component in entry["components"]:
            if component in details:
                raise SystemExit(
                    f"supplemental component duplicates distribution component: {component}"
                )
            details[component] = {
                "declaredByModules": {"CPython core"},
                "files": [file_record],
                "licenseExpressions": {entry["componentLicenseExpressions"][component]},
                "publicDomain": False,
                "requiredByModules": {"CPython core"},
            }

    cpython_component = component_by_path[Path(metadata["license_path"]).name]
    details[cpython_component]["declaredByModules"].add("CPython")
    details[cpython_component]["requiredByModules"].add("CPython")
    details[cpython_component]["licenseExpressions"].update(metadata["licenses"])

    allowed_missing = set(pin["allowedMissingMetadataLicensePaths"])
    for module_name, records in metadata["build_info"]["extensions"].items():
        for record in records:
            shipped = record_is_shipped(record, runtime_root)
            present_declared = 0
            for raw_path in record.get("license_paths", []):
                if raw_path in allowed_missing:
                    continue
                if not isinstance(raw_path, str) or not raw_path.startswith(
                    "licenses/"
                ):
                    raise SystemExit(f"unsafe metadata license path: {raw_path!r}")
                name = Path(raw_path).name
                component = component_by_path.get(name)
                if component is None:
                    raise SystemExit(
                        f"metadata license is absent from the pin: {raw_path}"
                    )
                present_declared += 1
                details[component]["declaredByModules"].add(module_name)
                details[component]["licenseExpressions"].update(
                    record.get("licenses", [])
                )
                details[component]["publicDomain"] = (
                    details[component]["publicDomain"]
                    or record.get("license_public_domain") is True
                )
                if shipped:
                    details[component]["requiredByModules"].add(module_name)
            if shipped and record.get("license_paths") and present_declared == 0:
                raise SystemExit(
                    f"shipped extension {module_name} has no available license text"
                )

    components = []
    for name, detail in sorted(details.items()):
        required = bool(detail["requiredByModules"])
        components.append(
            {
                "declaredByModules": sorted(detail["declaredByModules"]),
                "files": sorted(detail["files"], key=lambda item: item["path"]),
                "licenseExpressions": sorted(detail["licenseExpressions"]),
                "name": name,
                "publicDomain": detail["publicDomain"],
                "requiredByModules": sorted(detail["requiredByModules"]),
                "scope": "required" if required else "excluded",
            }
        )
    required_components = sorted(
        component["name"]
        for component in components
        if component["scope"] == "required"
    )
    if required_components != pin["requiredRuntimeComponents"]:
        raise SystemExit(
            f"packaged Python component closure changed; found={required_components}"
        )
    asset = pin["assets"][architecture]
    return {
        "architecture": architecture,
        "asset": {
            "bytes": asset["bytes"],
            "metadataSha256": asset["metadataSha256"],
            "name": asset["name"],
            "sha256": asset["sha256"],
        },
        "buildOptions": pin["buildOptions"],
        "components": components,
        "provider": pin["provider"],
        "pythonVersion": pin["pythonVersion"],
        "release": pin["release"],
        "schemaVersion": 1,
    }


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def collect(args: argparse.Namespace) -> None:
    pin_path = args.pin.resolve(strict=True)
    pin = validate_pin(pin_path)
    distribution_root = args.distribution_root.resolve(strict=True)
    runtime_root = args.runtime_root.resolve(strict=True)
    metadata, metadata_path = validate_distribution(
        pin, args.architecture, distribution_root
    )
    output = args.output
    if output.exists() or output.is_symlink():
        raise SystemExit(
            f"refusing to overwrite Python distribution evidence: {output}"
        )
    output.mkdir(parents=True)
    shutil.copy2(pin_path, output / "pin.json")
    sanitized_metadata = sanitize_metadata(
        metadata, pin["assets"][args.architecture]["metadataSha256"]
    )
    (output / "PYTHON.json").write_bytes(canonical_bytes(sanitized_metadata))
    licenses_output = output / "licenses"
    licenses_output.mkdir()
    for entry in pin["licenseFiles"]:
        shutil.copy2(
            distribution_root / "licenses" / entry["path"],
            licenses_output / entry["path"],
        )
    supplemental_output = output / "supplemental-licenses"
    supplemental_output.mkdir()
    for entry in pin["supplementalLicenseFiles"]:
        shutil.copy2(
            distribution_root / "supplemental-licenses" / entry["path"],
            supplemental_output / entry["path"],
        )
    inventory = build_inventory(
        pin, args.architecture, sanitized_metadata, runtime_root
    )
    (output / "inventory.json").write_bytes(canonical_bytes(inventory))
    verify_bundle(pin_path, args.architecture, output, runtime_root)


def verify_bundle(
    pin_path: Path, architecture: str, evidence_root: Path, runtime_root: Path
) -> None:
    pin = validate_pin(pin_path)
    if not evidence_root.is_dir() or evidence_root.is_symlink():
        raise SystemExit("Python distribution evidence directory is missing or linked")
    expected_root_entries = {
        "PYTHON.json",
        "inventory.json",
        "licenses",
        "pin.json",
        "supplemental-licenses",
    }
    actual_root_entries = {path.name for path in evidence_root.iterdir()}
    if actual_root_entries != expected_root_entries:
        raise SystemExit("Python distribution evidence root is not exact")
    embedded_pin = evidence_root / "pin.json"
    if embedded_pin.is_symlink() or embedded_pin.read_bytes() != pin_path.read_bytes():
        raise SystemExit(
            "embedded Python distribution pin differs from reviewed source"
        )
    metadata_path = evidence_root / "PYTHON.json"
    metadata = load_json(metadata_path)
    asset = pin["assets"][architecture]
    evidence_marker = metadata.get("scanstudio_evidence")
    if evidence_marker != {
        "sanitization": "macos-temporary-build-root-v1",
        "sourceMetadataSha256": asset["metadataSha256"],
    }:
        raise SystemExit("embedded Python distribution metadata provenance changed")
    if metadata_path.read_bytes() != canonical_bytes(metadata):
        raise SystemExit("embedded Python distribution metadata is not canonical")
    if any(
        marker in metadata_path.read_bytes()
        for marker in (b"/Users/", b"/var/folders/")
    ):
        raise SystemExit("embedded Python distribution metadata leaks a build root")
    licenses_root = evidence_root / "licenses"
    if not licenses_root.is_dir() or licenses_root.is_symlink():
        raise SystemExit("embedded Python distribution licenses are missing or linked")
    actual_license_paths = list(licenses_root.iterdir())
    expected_names = {entry["path"] for entry in pin["licenseFiles"]}
    if (
        any(path.is_symlink() or not path.is_file() for path in actual_license_paths)
        or {path.name for path in actual_license_paths} != expected_names
    ):
        raise SystemExit("embedded Python distribution license corpus is not exact")
    for entry in pin["licenseFiles"]:
        path = licenses_root / entry["path"]
        if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise SystemExit(
                f"embedded Python distribution license changed: {entry['path']}"
            )
    supplemental_root = evidence_root / "supplemental-licenses"
    expected_supplemental = {
        entry["path"]: entry for entry in pin["supplementalLicenseFiles"]
    }
    if not supplemental_root.is_dir() or supplemental_root.is_symlink():
        raise SystemExit("embedded supplemental CPython licenses are missing or linked")
    actual_supplemental_paths = list(supplemental_root.iterdir())
    if any(
        path.is_symlink() or not path.is_file() for path in actual_supplemental_paths
    ) or {path.name for path in actual_supplemental_paths} != set(
        expected_supplemental
    ):
        raise SystemExit("embedded supplemental CPython license corpus is not exact")
    for name, entry in expected_supplemental.items():
        path = supplemental_root / name
        if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise SystemExit(f"embedded supplemental CPython license changed: {name}")
    expected_inventory = canonical_bytes(
        build_inventory(pin, architecture, metadata, runtime_root)
    )
    inventory_path = evidence_root / "inventory.json"
    if inventory_path.is_symlink() or inventory_path.read_bytes() != expected_inventory:
        raise SystemExit("Python distribution component inventory is missing or stale")


def validate_interpreter(pin: dict[str, Any], distribution_root: Path) -> None:
    executable = distribution_root / pin["pythonExecutableRelativePath"]
    if not executable.is_file() or executable.is_symlink():
        raise SystemExit("pinned distribution interpreter is missing or linked")
    command = [
        str(executable),
        "-I",
        "-c",
        "import json,sys; print(json.dumps(list(sys.version_info[:3])))",
    ]
    result = subprocess.run(
        command, capture_output=True, text=True, timeout=30, check=False
    )
    if result.returncode != 0:
        raise SystemExit(
            f"pinned distribution interpreter did not run: {result.stderr.strip()}"
        )
    try:
        parts = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SystemExit(
            "pinned distribution interpreter returned malformed version data"
        ) from error
    actual = ".".join(str(part) for part in parts)
    if actual != pin["pythonVersion"]:
        raise SystemExit(
            f"pinned interpreter version mismatch: expected {pin['pythonVersion']}, found {actual}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_pin_parser = subparsers.add_parser("validate-pin")
    validate_pin_parser.add_argument("--pin", type=Path, required=True)

    validate_distribution_parser = subparsers.add_parser("validate-distribution")
    validate_distribution_parser.add_argument("--pin", type=Path, required=True)
    validate_distribution_parser.add_argument(
        "--architecture", choices=sorted(ARCHITECTURES), required=True
    )
    validate_distribution_parser.add_argument(
        "--distribution-root", type=Path, required=True
    )
    validate_distribution_parser.add_argument("--run-interpreter", action="store_true")

    collect_parser = subparsers.add_parser("collect")
    collect_parser.add_argument("--pin", type=Path, required=True)
    collect_parser.add_argument(
        "--architecture", choices=sorted(ARCHITECTURES), required=True
    )
    collect_parser.add_argument("--distribution-root", type=Path, required=True)
    collect_parser.add_argument("--runtime-root", type=Path, required=True)
    collect_parser.add_argument("--output", type=Path, required=True)

    verify_parser = subparsers.add_parser("verify-bundle")
    verify_parser.add_argument("--pin", type=Path, required=True)
    verify_parser.add_argument(
        "--architecture", choices=sorted(ARCHITECTURES), required=True
    )
    verify_parser.add_argument("--runtime-root", type=Path, required=True)
    verify_parser.add_argument("--evidence-root", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "validate-pin":
        validate_pin(args.pin.resolve(strict=True))
    elif args.command == "validate-distribution":
        pin = validate_pin(args.pin.resolve(strict=True))
        root = args.distribution_root.resolve(strict=True)
        validate_distribution(pin, args.architecture, root)
        if args.run_interpreter:
            validate_interpreter(pin, root)
    elif args.command == "collect":
        collect(args)
    elif args.command == "verify-bundle":
        verify_bundle(
            args.pin.resolve(strict=True),
            args.architecture,
            args.evidence_root.resolve(strict=True),
            args.runtime_root.resolve(strict=True),
        )
    else:
        raise AssertionError(args.command)


if __name__ == "__main__":
    main()
