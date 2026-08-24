#!/usr/bin/env python3
"""Emit and verify exact-run provenance for release workflow artifacts."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any, BinaryIO, Sequence


SCHEMA = 1
MAX_RECEIPT_BYTES = 128 * 1024
MAX_ARTIFACTS = 32
SHA256_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}")
TAG_RE = re.compile(r"v[A-Za-z0-9][A-Za-z0-9._-]{0,126}")


class ProvenanceError(ValueError):
    """Release provenance is malformed, incomplete, or does not match bytes."""


@dataclass(frozen=True)
class ReleaseIdentity:
    repository: str
    run_id: int
    run_attempt: int
    commit_sha: str
    tag: str

    def validate(self) -> None:
        if REPOSITORY_RE.fullmatch(self.repository) is None:
            raise ProvenanceError(f"invalid repository identity: {self.repository!r}")
        if (
            not isinstance(self.run_id, int)
            or isinstance(self.run_id, bool)
            or self.run_id <= 0
        ):
            raise ProvenanceError("run_id must be a positive integer")
        if (
            not isinstance(self.run_attempt, int)
            or isinstance(self.run_attempt, bool)
            or self.run_attempt <= 0
        ):
            raise ProvenanceError("run_attempt must be a positive integer")
        if COMMIT_RE.fullmatch(self.commit_sha) is None:
            raise ProvenanceError(
                f"commit_sha must be a lowercase full SHA: {self.commit_sha!r}"
            )
        if TAG_RE.fullmatch(self.tag) is None:
            raise ProvenanceError(f"invalid release tag: {self.tag!r}")


def _require_directory(path: Path, role: str) -> None:
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ProvenanceError(f"{role} is unavailable: {path}: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ProvenanceError(f"{role} must be a real, non-symlink directory: {path}")


def _open_regular(path: Path, role: str) -> tuple[BinaryIO, os.stat_result]:
    try:
        expected = os.lstat(path)
    except OSError as error:
        raise ProvenanceError(f"{role} is unavailable: {path}: {error}") from error
    if not stat.S_ISREG(expected.st_mode):
        raise ProvenanceError(f"{role} must be a regular file: {path}")

    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ProvenanceError(f"cannot open {role}: {path}: {error}") from error
    handle = os.fdopen(descriptor, "rb")
    actual = os.fstat(descriptor)
    if not stat.S_ISREG(actual.st_mode) or (
        expected.st_dev,
        expected.st_ino,
    ) != (actual.st_dev, actual.st_ino):
        handle.close()
        raise ProvenanceError(f"{role} identity changed while opening: {path}")
    return handle, actual


def _hash_regular(path: Path, role: str) -> tuple[str, int]:
    handle, before = _open_regular(path, role)
    digest = hashlib.sha256()
    count = 0
    try:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            count += len(chunk)
        after = os.fstat(handle.fileno())
    finally:
        handle.close()
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    )
    identity_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    )
    if identity_before != identity_after or count != before.st_size:
        raise ProvenanceError(f"{role} changed while hashing: {path}")
    return digest.hexdigest(), count


def _read_receipt(path: Path) -> dict[str, Any]:
    handle, metadata = _open_regular(path, "provenance receipt")
    try:
        if metadata.st_size > MAX_RECEIPT_BYTES:
            raise ProvenanceError(
                f"provenance receipt exceeds {MAX_RECEIPT_BYTES} bytes"
            )
        payload = handle.read(MAX_RECEIPT_BYTES + 1)
        after = os.fstat(handle.fileno())
    finally:
        handle.close()
    if len(payload) != metadata.st_size or (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
    ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ProvenanceError("provenance receipt changed while reading")
    if not payload.endswith(b"\n"):
        raise ProvenanceError("provenance receipt must end with one LF")
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ProvenanceError("provenance receipt is not strict UTF-8") from error

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ProvenanceError(f"duplicate JSON key in provenance: {key!r}")
            result[key] = value
        return result

    try:
        decoded = json.loads(text, object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as error:
        raise ProvenanceError(f"invalid provenance JSON: {error}") from error
    if not isinstance(decoded, dict):
        raise ProvenanceError("provenance receipt root must be an object")
    return decoded


def _artifact_record(path: Path) -> dict[str, object]:
    if path.name in {"", ".", ".."}:
        raise ProvenanceError(f"artifact has an invalid basename: {path}")
    digest, size = _hash_regular(path, "release artifact")
    return {"name": path.name, "sha256": digest, "size": size}


def emit_receipt(
    output: Path,
    artifacts: Sequence[Path],
    identity: ReleaseIdentity,
) -> None:
    identity.validate()
    if not artifacts or len(artifacts) > MAX_ARTIFACTS:
        raise ProvenanceError(f"artifact count must be between 1 and {MAX_ARTIFACTS}")
    output = Path(output)
    artifact_paths = [Path(path) for path in artifacts]
    names = [path.name for path in artifact_paths]
    if len(set(names)) != len(names):
        raise ProvenanceError("duplicate artifact basenames are forbidden")
    if output.name in names:
        raise ProvenanceError("provenance receipt cannot also be an artifact")
    _require_directory(output.parent, "provenance output directory")
    if output.exists() or output.is_symlink():
        raise ProvenanceError(f"refusing to overwrite provenance receipt: {output}")

    records = sorted(
        (_artifact_record(path) for path in artifact_paths),
        key=lambda item: str(item["name"]),
    )
    payload = {
        "schema": SCHEMA,
        **asdict(identity),
        "artifacts": records,
    }
    encoded = (
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", dir=output.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, output)
        except FileExistsError as error:
            raise ProvenanceError(
                f"refusing to overwrite provenance receipt: {output}"
            ) from error
        temporary.unlink()
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def _validate_payload(
    payload: dict[str, Any], identity: ReleaseIdentity
) -> list[dict[str, object]]:
    expected_keys = {
        "schema",
        "repository",
        "run_id",
        "run_attempt",
        "commit_sha",
        "tag",
        "artifacts",
    }
    if set(payload) != expected_keys:
        raise ProvenanceError(
            "provenance keys changed: "
            f"missing={sorted(expected_keys - set(payload))} "
            f"extra={sorted(set(payload) - expected_keys)}"
        )
    if payload["schema"] != SCHEMA:
        raise ProvenanceError(f"unsupported provenance schema: {payload['schema']!r}")
    for field, expected in asdict(identity).items():
        if payload[field] != expected:
            raise ProvenanceError(
                f"provenance {field} mismatch: expected={expected!r} "
                f"actual={payload[field]!r}"
            )

    records = payload["artifacts"]
    if not isinstance(records, list) or not records or len(records) > MAX_ARTIFACTS:
        raise ProvenanceError("provenance artifacts must be a bounded non-empty list")
    validated: list[dict[str, object]] = []
    names: set[str] = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {"name", "sha256", "size"}:
            raise ProvenanceError("provenance artifact entry has an invalid shape")
        name = record["name"]
        digest = record["sha256"]
        size = record["size"]
        if (
            not isinstance(name, str)
            or name in {"", ".", ".."}
            or Path(name).name != name
        ):
            raise ProvenanceError(f"invalid artifact name in provenance: {name!r}")
        if name in names:
            raise ProvenanceError(f"duplicate artifact in provenance: {name!r}")
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            raise ProvenanceError(f"invalid artifact digest for {name!r}")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise ProvenanceError(f"invalid artifact size for {name!r}")
        names.add(name)
        validated.append(record)
    if [record["name"] for record in validated] != sorted(names):
        raise ProvenanceError("provenance artifacts must use canonical name order")
    return validated


def verify_receipt(
    receipt: Path,
    artifact_root: Path,
    identity: ReleaseIdentity,
) -> None:
    identity.validate()
    receipt = Path(receipt)
    artifact_root = Path(artifact_root)
    _require_directory(artifact_root, "artifact root")
    try:
        if receipt.parent.resolve(strict=True) != artifact_root.resolve(strict=True):
            raise ProvenanceError("provenance receipt must be inside artifact root")
    except OSError as error:
        raise ProvenanceError(f"cannot resolve artifact root: {error}") from error

    payload = _read_receipt(receipt)
    records = _validate_payload(payload, identity)
    expected_names = {str(record["name"]) for record in records}
    expected_files = expected_names | {receipt.name}
    try:
        entries = list(artifact_root.iterdir())
    except OSError as error:
        raise ProvenanceError(f"cannot enumerate artifact root: {error}") from error
    actual_files = {entry.name for entry in entries}
    if actual_files != expected_files:
        raise ProvenanceError(
            "artifact file set does not match provenance: "
            f"missing={sorted(expected_files - actual_files)} "
            f"extra={sorted(actual_files - expected_files)}"
        )

    for record in records:
        name = str(record["name"])
        digest, size = _hash_regular(artifact_root / name, "release artifact")
        if size != record["size"]:
            raise ProvenanceError(
                f"artifact size mismatch for {name!r}: "
                f"expected={record['size']} actual={size}"
            )
        if digest != record["sha256"]:
            raise ProvenanceError(
                f"artifact digest mismatch for {name!r}: "
                f"expected={record['sha256']} actual={digest}"
            )


def _identity_from_args(arguments: argparse.Namespace) -> ReleaseIdentity:
    return ReleaseIdentity(
        repository=arguments.repository,
        run_id=arguments.run_id,
        run_attempt=arguments.run_attempt,
        commit_sha=arguments.commit,
        tag=arguments.tag,
    )


def _add_identity_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--run-attempt", required=True, type=int)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    emit = commands.add_parser("emit", help="write a provenance receipt")
    _add_identity_arguments(emit)
    emit.add_argument("--output", required=True, type=Path)
    emit.add_argument("--artifact", action="append", required=True, type=Path)

    verify = commands.add_parser("verify", help="verify a provenance receipt")
    _add_identity_arguments(verify)
    verify.add_argument("--receipt", required=True, type=Path)
    verify.add_argument("--artifact-root", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        identity = _identity_from_args(arguments)
        if arguments.command == "emit":
            emit_receipt(arguments.output, arguments.artifact, identity)
            print(f"Release provenance emitted: {arguments.output}")
        else:
            verify_receipt(arguments.receipt, arguments.artifact_root, identity)
            print(f"Release provenance verified: {arguments.receipt}")
    except (OSError, ProvenanceError) as error:
        print(f"Release provenance failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
