#!/usr/bin/env python3
"""Fail-closed verification for packaged dependency notices."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"dependency notices: {message}")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def safe_relative(value: str) -> Path:
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        fail(f"unsafe relative path: {value!r}")
    return path


if len(sys.argv) != 2:
    fail("usage: verify_dependency_notices.py <bundle-root>")

bundle_root = Path(sys.argv[1]).resolve()
licenses_root = bundle_root / "Licenses"
manifest_path = licenses_root / "dependency-notices-manifest.json"
if not manifest_path.is_file():
    fail("missing Licenses/dependency-notices-manifest.json")

manifest = json.loads(manifest_path.read_text())
if manifest.get("version") != 1 or not isinstance(manifest.get("files"), dict):
    fail("invalid dependency notice manifest structure")

expected_files = manifest["files"]
actual_files = {
    path.relative_to(licenses_root).as_posix(): path
    for path in licenses_root.rglob("*")
    if path.is_file() and path != manifest_path
}
if set(expected_files) != set(actual_files):
    missing = sorted(set(expected_files) - set(actual_files))
    extra = sorted(set(actual_files) - set(expected_files))
    fail(f"manifest file set mismatch; missing={missing}, extra={extra}")

for relative, metadata in expected_files.items():
    safe_relative(relative)
    path = actual_files[relative]
    if not isinstance(metadata, dict):
        fail(f"invalid checksum entry for {relative}")
    if metadata.get("bytes") != path.stat().st_size:
        fail(f"size mismatch for {relative}")
    expected_sha = metadata.get("sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha) or digest(path) != expected_sha:
        fail(f"SHA-256 mismatch for {relative}")

required_reports = {
    "Rust-App-Cargo.lock",
    "Rust-App-THIRD-PARTY.txt",
    "Rust-Engine-Cargo.lock",
    "Rust-Engine-THIRD-PARTY.txt",
    "THIRD_PARTY_NOTICES.md",
    "npm-production/package-lock.json",
    "npm-production/inventory.json",
}
missing_reports = sorted(required_reports - set(actual_files))
if missing_reports:
    fail(f"required notice files missing: {missing_reports}")

for report_name in ("Rust-App-THIRD-PARTY.txt", "Rust-Engine-THIRD-PARTY.txt"):
    report = actual_files[report_name]
    # The notice reports and JSON manifests are written as UTF-8 by the
    # tooling. Read them as UTF-8 explicitly so a Windows host (default
    # encoding cp1252) does not fail decoding a non-ASCII license/report byte
    # (UnicodeDecodeError); this is a runner-compat fix, not a looser check.
    text = report.read_text(encoding="utf-8", errors="strict")
    if report.stat().st_size < 10_000 or "License:" not in text or "Used by:" not in text:
        fail(f"Rust report is empty or malformed: {report_name}")
    if "/Users/" in text:
        fail(f"developer path leaked into Rust report: {report_name}")

npm_root = licenses_root / "npm-production"
lock_path = npm_root / "package-lock.json"
inventory_path = npm_root / "inventory.json"
lock = json.loads(lock_path.read_text(encoding="utf-8"))
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
if inventory.get("sourceLockfileSha256") != digest(lock_path):
    fail("npm inventory is not bound to the bundled package-lock.json")

locked_packages = {
    package_path: metadata
    for package_path, metadata in lock.get("packages", {}).items()
    if package_path.startswith("node_modules/") and not metadata.get("dev", False)
}
required_package_paths = {
    package_path
    for package_path, metadata in locked_packages.items()
    if not metadata.get("optional", False)
}
inventory_packages = inventory.get("packages")
if not isinstance(inventory_packages, list) or inventory.get("packageCount") != len(inventory_packages):
    fail("invalid npm inventory package count")

seen_paths: set[str] = set()
seen_directories: set[str] = set()
for package in inventory_packages:
    package_path = package.get("packagePath")
    directory = package.get("directory")
    if package_path in seen_paths or package_path not in locked_packages:
        fail(f"unexpected or duplicate npm package path: {package_path!r}")
    if not isinstance(directory, str) or Path(directory).name != directory or directory in seen_directories:
        fail(f"unsafe or duplicate npm notice directory: {directory!r}")
    seen_paths.add(package_path)
    seen_directories.add(directory)

    locked = locked_packages[package_path]
    if package.get("version") != locked.get("version") or package.get("integrity") != locked.get("integrity"):
        fail(f"npm inventory identity mismatch: {package_path}")

    package_root = npm_root / directory
    package_json_path = package_root / "package.json"
    if not package_json_path.is_file():
        fail(f"missing npm package metadata: {directory}/package.json")
    package_json = json.loads(package_json_path.read_text())
    if package_json.get("name") != package.get("name") or package_json.get("version") != package.get("version"):
        fail(f"npm package.json identity mismatch: {package_path}")

    records = package.get("noticeFiles")
    if not isinstance(records, list) or not records:
        fail(f"npm package has no notice records: {package_path}")
    recorded_names: set[str] = set()
    has_full_text = False
    for record in records:
        relative = safe_relative(record.get("file", ""))
        if len(relative.parts) != 2 or relative.parts[0] != directory:
            fail(f"npm notice record escapes package directory: {relative}")
        notice = npm_root / relative
        if not notice.is_file() or notice.name in recorded_names:
            fail(f"missing or duplicate npm notice file: {relative}")
        recorded_names.add(notice.name)
        if record.get("bytes") != notice.stat().st_size or record.get("sha256") != digest(notice):
            fail(f"npm notice checksum mismatch: {relative}")
        if not notice.name.lower().endswith(".spdx"):
            has_full_text = True
    if not has_full_text:
        fail(f"npm package lacks full license text: {package_path}")

    actual_notice_names = {
        path.name for path in package_root.iterdir()
        if path.is_file() and path.name != "package.json"
    }
    if actual_notice_names != recorded_names:
        fail(f"npm notice file set mismatch: {package_path}")

if not required_package_paths.issubset(seen_paths):
    fail(f"npm inventory omits required packages: {sorted(required_package_paths - seen_paths)}")

actual_notice_directories = {
    path.name for path in npm_root.iterdir() if path.is_dir()
}
if actual_notice_directories != seen_directories:
    fail("npm notice directory set does not match inventory")

print(
    "PASS  dependency notice manifest, two Rust reports, and "
    f"{len(inventory_packages)} npm production packages"
)
