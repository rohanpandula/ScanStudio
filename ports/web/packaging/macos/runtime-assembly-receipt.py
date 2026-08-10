#!/usr/bin/env python3
"""Emit or verify the canonical unsigned-runtime assembly receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any


MAXIMUM_DMG_SIZE = 1024 * 1024 * 1024
MAXIMUM_FILE_COUNT = 100_000
MAXIMUM_INSTALLED_SIZE = 8 * 1024 * 1024 * 1024
ARCHITECTURES = {"arm64", "x86_64"}


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_strict(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"required regular JSON file is missing or linked: {path}")
    try:
        value = json.loads(path.read_text(), object_pairs_hook=strict_object)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(f"could not read strict JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"JSON root must be an object: {path}")
    return value


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def validate_version(value: str) -> None:
    import re

    if len(value) > 96 or re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)?)?", value
    ) is None:
        raise SystemExit(f"bad runtime version: {value}")


def validate_tree(value: dict[str, Any]) -> dict[str, Any]:
    if set(value) != {"fileCount", "installedSize", "treeSHA256"}:
        raise SystemExit("assembly payload tree keys are not exact")
    file_count = value["fileCount"]
    installed_size = value["installedSize"]
    digest = value["treeSHA256"]
    if (
        not isinstance(file_count, int)
        or isinstance(file_count, bool)
        or not 0 < file_count <= MAXIMUM_FILE_COUNT
    ):
        raise SystemExit("assembly payload file count is invalid")
    if (
        not isinstance(installed_size, int)
        or isinstance(installed_size, bool)
        or not 0 < installed_size <= MAXIMUM_INSTALLED_SIZE
    ):
        raise SystemExit("assembly payload installed size is invalid")
    if (
        not isinstance(digest, str)
        or len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
    ):
        raise SystemExit("assembly payload tree SHA-256 is invalid")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_receipt(
    dmg: Path, version: str, architecture: str, tree_path: Path
) -> dict[str, Any]:
    validate_version(version)
    if architecture not in ARCHITECTURES:
        raise SystemExit(f"bad runtime architecture: {architecture}")
    stem = f"ScanStudio-WebRuntime-{version}-macOS-{architecture}"
    if dmg.name != f"{stem}.unsigned.dmg" or not dmg.is_file() or dmg.is_symlink():
        raise SystemExit("unsigned runtime DMG name or file type is invalid")
    size = dmg.stat().st_size
    if not 0 < size <= MAXIMUM_DMG_SIZE:
        raise SystemExit("unsigned runtime DMG size is invalid")
    tree = validate_tree(load_strict(tree_path))
    if tree_path.read_bytes() != canonical_bytes(tree):
        raise SystemExit("payload tree summary is not canonical JSON")
    return {
        "architecture": architecture,
        "bundleName": "ScanStudioWebRuntime.bundle",
        "payload": tree,
        "runtimeVersion": version,
        "schemaVersion": 1,
        "unsignedDMG": {
            "name": dmg.name,
            "sha256": sha256(dmg),
            "size": size,
        },
    }


def emit(args: argparse.Namespace) -> None:
    output = args.receipt
    if output.exists() or output.is_symlink():
        raise SystemExit(f"refusing to overwrite assembly receipt: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(
        canonical_bytes(
            expected_receipt(args.dmg, args.version, args.architecture, args.tree)
        )
    )


def verify(args: argparse.Namespace) -> None:
    actual = load_strict(args.receipt)
    expected = expected_receipt(args.dmg, args.version, args.architecture, args.tree)
    if args.receipt.read_bytes() != canonical_bytes(actual):
        raise SystemExit("assembly receipt is not canonical JSON")
    if actual != expected:
        raise SystemExit("assembly receipt does not bind the exact unsigned payload")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("emit", "verify"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("dmg", type=Path)
        subparser.add_argument("version")
        subparser.add_argument("architecture")
        subparser.add_argument("tree", type=Path)
        subparser.add_argument("receipt", type=Path)
        subparser.set_defaults(handler=emit if command == "emit" else verify)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
