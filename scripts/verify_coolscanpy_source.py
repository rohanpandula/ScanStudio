#!/usr/bin/env python3
"""Verify a CoolscanPy source snapshot without importing its dependency graph.

The cross-platform packages intentionally ship CoolscanPy source.  This gate
loads only the stdlib-only capture-bundle modules, binds their resource reads
to the supplied source tree, and verifies the exact bytes that will ship.  It
also requires one version across pyproject.toml, uv.lock, optional generated
distribution metadata, and optional package provenance.
"""

from __future__ import annotations

import argparse
from email.parser import Parser
import importlib
import json
from pathlib import Path
import sys
import tomllib
import types


def _project_version(source_root: Path) -> str:
    pyproject_path = source_root / "pyproject.toml"
    lock_path = source_root / "uv.lock"
    project = tomllib.loads(pyproject_path.read_text(encoding="utf-8")).get(
        "project"
    )
    if not isinstance(project, dict) or project.get("name") != "coolscanpy":
        raise ValueError("pyproject.toml does not describe the coolscanpy project")
    version = project.get("version")
    if not isinstance(version, str) or not version:
        raise ValueError("coolscanpy [project].version is missing or invalid")

    lock = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    locked = [
        package
        for package in lock.get("package", [])
        if isinstance(package, dict) and package.get("name") == "coolscanpy"
    ]
    if len(locked) != 1 or locked[0].get("version") != version:
        raise ValueError(
            "uv.lock must contain exactly one coolscanpy package at "
            f"[project].version {version!r}"
        )
    return version


def _verify_provenance(path: Path, version: str) -> None:
    payload = json.loads(path.read_text(encoding="utf-8"))
    sources = payload.get("sources")
    coolscanpy = sources.get("coolscanpy") if isinstance(sources, dict) else None
    if not isinstance(coolscanpy, dict) or coolscanpy.get("version") != version:
        raise ValueError(
            f"{path} does not report CoolscanPy project version {version!r}"
        )


def _verify_metadata(root: Path, version: str) -> None:
    candidates = sorted(root.glob("coolscanpy-*.dist-info/METADATA"))
    if len(candidates) != 1:
        raise ValueError(
            f"expected exactly one coolscanpy dist-info record under {root}, "
            f"found {len(candidates)}"
        )
    expected_dir = f"coolscanpy-{version}.dist-info"
    if candidates[0].parent.name != expected_dir:
        raise ValueError(
            f"CoolscanPy dist-info directory is {candidates[0].parent.name!r}, "
            f"expected {expected_dir!r}"
        )
    metadata = Parser().parsestr(candidates[0].read_text(encoding="utf-8"))
    if metadata.get("Name") != "coolscanpy" or metadata.get("Version") != version:
        raise ValueError(
            f"{candidates[0]} does not identify coolscanpy {version}"
        )


def _namespace_package(name: str, path: Path) -> types.ModuleType:
    module = types.ModuleType(name)
    module.__package__ = name
    module.__path__ = [str(path)]  # type: ignore[attr-defined]
    return module


def _verify_capture_bundle(source_root: Path) -> str:
    package_root = source_root / "src" / "coolscanpy"
    protocol_root = package_root / "protocol"
    capture_root = protocol_root / "ls5000_single_pass"
    required = [
        package_root / "__init__.py",
        capture_root / "bundle.py",
        capture_root / "plan.py",
        capture_root / "continuation_plan.py",
        capture_root / "data" / "replay-first-rgbi4-plan.jsonl",
        capture_root / "data" / "replay-next-rgbi4-plan.json",
        capture_root / "data" / "replay-first-rgbi4-manifest.json",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise ValueError(f"CoolscanPy source snapshot is incomplete: {missing}")

    module_names = (
        "coolscanpy.protocol.ls5000_single_pass.bundle",
        "coolscanpy.protocol.ls5000_single_pass.continuation_plan",
        "coolscanpy.protocol.ls5000_single_pass.plan",
        "coolscanpy.protocol.ls5000_single_pass",
        "coolscanpy.protocol",
        "coolscanpy",
    )
    previous = {name: sys.modules.get(name) for name in module_names}
    try:
        sys.modules["coolscanpy"] = _namespace_package("coolscanpy", package_root)
        sys.modules["coolscanpy.protocol"] = _namespace_package(
            "coolscanpy.protocol", protocol_root
        )
        sys.modules["coolscanpy.protocol.ls5000_single_pass"] = _namespace_package(
            "coolscanpy.protocol.ls5000_single_pass", capture_root
        )
        plan = importlib.import_module(
            "coolscanpy.protocol.ls5000_single_pass.plan"
        )
        continuation = importlib.import_module(
            "coolscanpy.protocol.ls5000_single_pass.continuation_plan"
        )
        bundle = importlib.import_module(
            "coolscanpy.protocol.ls5000_single_pass.bundle"
        )

        for relative in bundle.CAPTURE_BUNDLE_COMPONENT_SHA256:
            component = capture_root / relative
            if not component.is_file() or component.is_symlink():
                raise ValueError(
                    f"capture component must be a regular non-symlink file: {component}"
                )

        plan_bytes = (capture_root / "data/replay-first-rgbi4-plan.jsonl").read_bytes()
        continuation_bytes = (
            capture_root / "data/replay-next-rgbi4-plan.json"
        ).read_bytes()
        plan.verify_canonical_plan(plan_bytes)
        continuation.verify_canonical_continuation_plan(continuation_bytes)

        # Bind every resource read to the supplied assembled tree.  This keeps
        # the verifier stdlib-only while exercising bundle.py's production
        # component ledger and manifest checks against the exact shipped bytes.
        bundle.canonical_plan_bytes = lambda: plan_bytes
        bundle.canonical_continuation_plan_bytes = lambda: continuation_bytes
        bundle.files = lambda _package: capture_root / "data"
        return bundle.verify_capture_bundle(require_python_sources=True)
    finally:
        for name, old_module in previous.items():
            if old_module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old_module


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--provenance", type=Path)
    parser.add_argument("--metadata-root", type=Path)
    parser.add_argument("--print-version", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    source_root = args.source_root.resolve()
    try:
        if not source_root.is_dir():
            raise ValueError(f"CoolscanPy source root is missing: {source_root}")
        version = _project_version(source_root)
        bundle_sha256 = _verify_capture_bundle(source_root)
        if args.provenance is not None:
            _verify_provenance(args.provenance.resolve(), version)
        if args.metadata_root is not None:
            _verify_metadata(args.metadata_root.resolve(), version)
    except Exception as error:
        print(f"CoolscanPy package identity verification failed: {error}", file=sys.stderr)
        return 1

    if args.print_version:
        print(version)
    else:
        print(
            "CoolscanPy package identity verified: "
            f"version={version} capture_bundle_sha256={bundle_sha256}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
