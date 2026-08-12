#!/usr/bin/env python3
"""Validate and safely unpack ScanStudio's pinned CPython package artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import zipfile


MAX_LOCK_BYTES = 64 * 1024
MAX_REQUIREMENTS_BYTES = 64 * 1024
MAX_LEDGER_BYTES = 64 * 1024
MAX_WHEEL_MEMBERS = 25_000
MAX_WHEEL_FILE_BYTES = 512 * 1024 * 1024
MAX_WHEEL_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_SDIST_MEMBERS = 10_000
MAX_SDIST_FILE_BYTES = 64 * 1024 * 1024
MAX_SDIST_TOTAL_BYTES = 256 * 1024 * 1024
READ_CHUNK = 1024 * 1024
HASH_RE = re.compile(r"[0-9a-f]{64}")
REQUIREMENT_RE = re.compile(
    r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?P<version>[^\s]+) "
    r"--hash=sha256:(?P<sha256>[0-9a-f]{64})"
)
LEDGER_RE = re.compile(r"(?P<sha256>[0-9a-f]{64})  (?P<filename>[^/\\\r\n]+)")


class LockError(RuntimeError):
    """The committed lock or downloaded artifact set is invalid."""


def bounded_bytes(path: Path, limit: int, label: str) -> bytes:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    binary = getattr(os, "O_BINARY", 0)
    try:
        descriptor = os.open(path, os.O_RDONLY | nofollow | binary)
    except OSError as error:
        raise LockError(
            f"cannot open {label} without following links {path}: {error}"
        ) from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise LockError(f"{label} must be a regular non-symlink file: {path}")
        if before.st_size > limit:
            raise LockError(f"{label} exceeds {limit} bytes: {path}")

        def held_read() -> bytes:
            os.lseek(descriptor, 0, os.SEEK_SET)
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(READ_CHUNK, limit + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > limit:
                    raise LockError(f"{label} exceeds {limit} bytes: {path}")
            return b"".join(chunks)

        # Windows can report different nanosecond timestamp representations
        # for successive fstat calls on the same untouched handle. Two full
        # bounded reads through that already-held handle give the portable
        # mutation proof we need without trusting timestamp normalization.
        first = held_read()
        second = held_read()
        after = os.fstat(descriptor)
        if (
            len(first) != before.st_size
            or first != second
            or before.st_size != after.st_size
            or not stat.S_ISREG(after.st_mode)
        ):
            raise LockError(f"{label} changed while it was read: {path}")
        return first
    finally:
        os.close(descriptor)


def normalize_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def load_lock(path: Path) -> list[dict[str, object]]:
    try:
        payload = json.loads(bounded_bytes(path, MAX_LOCK_BYTES, "lock"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LockError(f"invalid JSON lock {path}: {error}") from error
    if not isinstance(payload, dict) or set(payload) != {
        "schemaVersion",
        "target",
        "artifacts",
    }:
        raise LockError(
            "artifact lock must contain exactly schemaVersion, target, artifacts"
        )
    if payload["schemaVersion"] != 1:
        raise LockError("unsupported artifact-lock schema")
    if payload["target"] != {
        "implementation": "cp",
        "pythonVersion": "313",
        "abi": "cp313",
        "platform": "manylinux_2_28_x86_64",
    }:
        raise LockError(
            "artifact lock target is not exact CPython 3.13 manylinux x86_64"
        )
    artifacts = payload["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise LockError("artifact lock has no artifacts")

    names: set[str] = set()
    filenames: set[str] = set()
    hashes: set[str] = set()
    validated: list[dict[str, object]] = []
    required_keys = {"name", "version", "kind", "roles", "filename", "size", "sha256"}
    for index, raw in enumerate(artifacts):
        if not isinstance(raw, dict) or set(raw) != required_keys:
            raise LockError(f"artifact {index} has unexpected fields")
        name = raw["name"]
        version = raw["version"]
        kind = raw["kind"]
        roles = raw["roles"]
        filename = raw["filename"]
        size = raw["size"]
        sha256 = raw["sha256"]
        if not isinstance(name, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]*", name
        ):
            raise LockError(f"artifact {index} has invalid package name")
        if (
            not isinstance(version, str)
            or not version
            or any(c.isspace() for c in version)
        ):
            raise LockError(f"artifact {index} has invalid version")
        if kind not in {"wheel", "sdist"}:
            raise LockError(f"artifact {index} has invalid kind")
        if (
            not isinstance(roles, list)
            or not roles
            or any(role not in {"build", "runtime"} for role in roles)
            or len(set(roles)) != len(roles)
        ):
            raise LockError(f"artifact {index} has invalid roles")
        if (
            not isinstance(filename, str)
            or filename in {"", ".", "..", "SHA256SUMS"}
            or Path(filename).name != filename
            or "/" in filename
            or "\\" in filename
        ):
            raise LockError(f"artifact {index} has unsafe filename")
        if kind == "wheel" and not filename.endswith(".whl"):
            raise LockError(f"wheel artifact {index} has a non-wheel filename")
        if kind == "sdist" and not filename.endswith(".tar.gz"):
            raise LockError(f"sdist artifact {index} has an unexpected filename")
        if (
            not isinstance(size, int)
            or isinstance(size, bool)
            or not 0 < size <= 256 * 1024 * 1024
        ):
            raise LockError(f"artifact {index} has invalid size")
        if not isinstance(sha256, str) or not HASH_RE.fullmatch(sha256):
            raise LockError(f"artifact {index} has invalid SHA-256")
        normalized = normalize_name(name)
        if normalized in names:
            raise LockError(f"duplicate normalized package name: {name}")
        if filename.casefold() in filenames:
            raise LockError(f"duplicate/case-colliding artifact filename: {filename}")
        if sha256 in hashes:
            raise LockError(f"duplicate artifact digest: {sha256}")
        names.add(normalized)
        filenames.add(filename.casefold())
        hashes.add(sha256)
        validated.append(raw)

    if sum(artifact["kind"] == "sdist" for artifact in validated) != 1:
        raise LockError("artifact lock must contain exactly one source distribution")
    return validated


def parse_requirements(path: Path) -> dict[str, tuple[str, str]]:
    try:
        text = bounded_bytes(path, MAX_REQUIREMENTS_BYTES, "requirements").decode(
            "utf-8"
        )
    except UnicodeDecodeError as error:
        raise LockError(f"requirements are not UTF-8: {path}") from error
    requirements: dict[str, tuple[str, str]] = {}
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = REQUIREMENT_RE.fullmatch(line)
        if match is None:
            raise LockError(f"non-canonical requirement at {path}:{line_number}")
        name = normalize_name(match.group("name"))
        if name in requirements:
            raise LockError(f"duplicate requirement for {name}: {path}")
        requirements[name] = (match.group("version"), match.group("sha256"))
    return requirements


def validate_requirements(
    artifacts: list[dict[str, object]],
    wheel_path: Path,
    sdist_path: Path,
    combined_path: Path | None = None,
) -> None:
    wheel_requirements = parse_requirements(wheel_path)
    sdist_requirements = parse_requirements(sdist_path)
    if set(wheel_requirements) & set(sdist_requirements):
        raise LockError("wheel and sdist requirements overlap")
    expected_wheels = {
        normalize_name(str(artifact["name"])): (artifact["version"], artifact["sha256"])
        for artifact in artifacts
        if artifact["kind"] == "wheel"
    }
    expected_sdists = {
        normalize_name(str(artifact["name"])): (artifact["version"], artifact["sha256"])
        for artifact in artifacts
        if artifact["kind"] == "sdist"
    }
    if wheel_requirements != expected_wheels:
        raise LockError("wheel requirements do not exactly match the artifact lock")
    if sdist_requirements != expected_sdists:
        raise LockError("sdist requirements do not exactly match the artifact lock")
    if combined_path is not None:
        combined_requirements = parse_requirements(combined_path)
        expected_combined = expected_wheels | expected_sdists
        if combined_requirements != expected_combined:
            raise LockError(
                "combined requirements do not exactly match the artifact lock"
            )


def parse_ledger(path: Path) -> dict[str, str]:
    try:
        text = bounded_bytes(path, MAX_LEDGER_BYTES, "SHA256 ledger").decode("ascii")
    except UnicodeDecodeError as error:
        raise LockError(f"SHA256 ledger is not ASCII: {path}") from error
    entries: dict[str, str] = {}
    previous = ""
    for line_number, line in enumerate(text.splitlines(), 1):
        match = LEDGER_RE.fullmatch(line)
        if match is None:
            raise LockError(f"non-canonical SHA256 ledger line at {path}:{line_number}")
        filename = match.group("filename")
        if filename <= previous:
            raise LockError(
                "SHA256 ledger filenames must be unique and bytewise sorted"
            )
        previous = filename
        entries[filename] = match.group("sha256")
    return entries


def validate_ledger(artifacts: list[dict[str, object]], ledger_path: Path) -> None:
    expected = {
        str(artifact["filename"]): str(artifact["sha256"]) for artifact in artifacts
    }
    if parse_ledger(ledger_path) != dict(sorted(expected.items())):
        raise LockError("SHA256 ledger does not exactly match the artifact lock")


def digest_regular_file(path: Path, expected_size: int) -> str:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    binary = getattr(os, "O_BINARY", 0)
    flags = os.O_RDONLY | nofollow | binary
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise LockError(
            f"cannot open artifact without following links: {path}: {error}"
        ) from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size != expected_size:
            raise LockError(f"artifact is not the expected regular file/size: {path}")
        value = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, READ_CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > expected_size:
                raise LockError(f"artifact grew while hashing: {path}")
            value.update(chunk)
        after = os.fstat(descriptor)
        if (
            total != expected_size
            or before.st_size != after.st_size
            or not stat.S_ISREG(after.st_mode)
        ):
            raise LockError(f"artifact changed while hashing: {path}")
        return value.hexdigest()
    finally:
        os.close(descriptor)


def open_verified_artifact(path: Path, expected_size: int, expected_sha256: str) -> int:
    """Return a held descriptor after hashing the exact regular file through it."""
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    binary = getattr(os, "O_BINARY", 0)
    try:
        descriptor = os.open(path, os.O_RDONLY | nofollow | binary)
    except OSError as error:
        raise LockError(
            f"cannot open artifact without following links: {path}: {error}"
        ) from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size != expected_size:
            raise LockError(f"artifact is not the expected regular file/size: {path}")
        value = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, READ_CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > expected_size:
                raise LockError(f"artifact grew while hashing: {path}")
            value.update(chunk)
        after = os.fstat(descriptor)
        if (
            total != expected_size
            or before.st_size != after.st_size
            or not stat.S_ISREG(after.st_mode)
        ):
            raise LockError(f"artifact changed while hashing: {path}")
        actual_sha256 = value.hexdigest()
        if actual_sha256 != expected_sha256:
            raise LockError(
                f"SHA-256 mismatch for {path.name}: expected {expected_sha256}, got {actual_sha256}"
            )
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def validate_directory(
    artifacts: list[dict[str, object]], directory: Path, allow_ledger: bool
) -> None:
    try:
        root_info = directory.lstat()
    except OSError as error:
        raise LockError(
            f"cannot inspect artifact directory {directory}: {error}"
        ) from error
    if not stat.S_ISDIR(root_info.st_mode) or directory.is_symlink():
        raise LockError(
            f"artifact directory must be a non-symlink directory: {directory}"
        )
    expected = {str(artifact["filename"]): artifact for artifact in artifacts}
    permitted = set(expected)
    if allow_ledger:
        permitted.add("SHA256SUMS")
    actual = {entry.name for entry in directory.iterdir()}
    if actual != permitted:
        missing = sorted(permitted - actual)
        unexpected = sorted(actual - permitted)
        raise LockError(
            f"artifact directory mismatch; missing={missing}, unexpected={unexpected}"
        )
    for filename, artifact in expected.items():
        path = directory / filename
        digest = digest_regular_file(path, int(artifact["size"]))
        if digest != artifact["sha256"]:
            raise LockError(
                f"SHA-256 mismatch for {filename}: expected {artifact['sha256']}, got {digest}"
            )
    if allow_ledger:
        expected_ledger = {
            str(artifact["filename"]): str(artifact["sha256"]) for artifact in artifacts
        }
        if parse_ledger(directory / "SHA256SUMS") != dict(
            sorted(expected_ledger.items())
        ):
            raise LockError(
                "artifact-directory SHA256SUMS does not exactly match the lock"
            )


def safe_member_parts(name: str) -> tuple[str, ...]:
    if not name or "\x00" in name or "\\" in name:
        raise LockError(f"archive has an unsafe member name: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise LockError(f"archive member escapes extraction root: {name!r}")
    return path.parts


def ensure_parent_directories(root: Path, parts: tuple[str, ...]) -> None:
    current = root
    for part in parts:
        current = current / part
        try:
            current.mkdir(mode=0o755)
        except FileExistsError:
            info = current.lstat()
            if not stat.S_ISDIR(info.st_mode) or current.is_symlink():
                raise LockError(
                    f"archive extraction parent is not a safe directory: {current}"
                )


def extract_wheels(
    artifacts: list[dict[str, object]], directory: Path, destination: Path, role: str
) -> None:
    try:
        destination.mkdir(parents=True, mode=0o755, exist_ok=True)
        destination_info = destination.lstat()
    except OSError as error:
        raise LockError(
            f"cannot create wheel extraction root {destination}: {error}"
        ) from error
    if not stat.S_ISDIR(destination_info.st_mode) or destination.is_symlink():
        raise LockError(
            f"wheel extraction root must be a non-symlink directory: {destination}"
        )

    selected = [
        artifact
        for artifact in artifacts
        if artifact["kind"] == "wheel" and (role == "all" or role in artifact["roles"])
    ]
    if not selected:
        raise LockError(f"no wheels selected for role {role}")

    seen_casefold: set[str] = set()
    total_uncompressed = 0
    for artifact in selected:
        path = directory / str(artifact["filename"])
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        binary = getattr(os, "O_BINARY", 0)
        descriptor = open_verified_artifact(
            path, int(artifact["size"]), str(artifact["sha256"])
        )
        try:
            with os.fdopen(descriptor, "rb", closefd=False) as handle:
                with zipfile.ZipFile(handle) as archive:
                    members = archive.infolist()
                    if len(members) > MAX_WHEEL_MEMBERS:
                        raise LockError(f"wheel has too many members: {path.name}")
                    prepared: list[tuple[zipfile.ZipInfo, tuple[str, ...], bool]] = []
                    for member in members:
                        parts = safe_member_parts(member.filename)
                        unix_mode = member.external_attr >> 16
                        file_type = stat.S_IFMT(unix_mode)
                        is_directory = member.is_dir()
                        if file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
                            raise LockError(
                                f"wheel contains a link or special file: {path.name}:{member.filename}"
                            )
                        if member.flag_bits & 0x1:
                            raise LockError(
                                f"wheel contains an encrypted member: {path.name}:{member.filename}"
                            )
                        if member.file_size > MAX_WHEEL_FILE_BYTES:
                            raise LockError(
                                f"wheel member exceeds size bound: {path.name}:{member.filename}"
                            )
                        total_uncompressed += member.file_size
                        if total_uncompressed > MAX_WHEEL_TOTAL_BYTES:
                            raise LockError("wheel extraction exceeds total size bound")
                        normalized = "/".join(parts).casefold()
                        if normalized in seen_casefold:
                            raise LockError(
                                f"wheels contain a duplicate/case-colliding path: {member.filename}"
                            )
                        seen_casefold.add(normalized)
                        prepared.append((member, parts, is_directory))

                    for member, parts, is_directory in prepared:
                        if is_directory:
                            ensure_parent_directories(destination, parts)
                            continue
                        ensure_parent_directories(destination, parts[:-1])
                        target = destination.joinpath(*parts)
                        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow | binary
                        descriptor_out = os.open(target, flags, 0o644)
                        written = 0
                        try:
                            with os.fdopen(
                                descriptor_out, "wb", closefd=False
                            ) as output:
                                with archive.open(member, "r") as source:
                                    while True:
                                        chunk = source.read(READ_CHUNK)
                                        if not chunk:
                                            break
                                        written += len(chunk)
                                        if written > member.file_size:
                                            raise LockError(
                                                f"wheel member expanded beyond declared size: {member.filename}"
                                            )
                                        output.write(chunk)
                                output.flush()
                                os.fsync(output.fileno())
                        finally:
                            os.close(descriptor_out)
                        if written != member.file_size:
                            raise LockError(
                                f"wheel member was truncated: {member.filename}"
                            )
                        if unix_mode & 0o111:
                            target.chmod(0o755)
        finally:
            os.close(descriptor)


def extract_sdist(
    artifacts: list[dict[str, object]], directory: Path, destination: Path
) -> None:
    matches = [artifact for artifact in artifacts if artifact["kind"] == "sdist"]
    if len(matches) != 1:
        raise LockError("expected exactly one locked source distribution")
    artifact = matches[0]
    path = directory / str(artifact["filename"])
    descriptor = open_verified_artifact(
        path, int(artifact["size"]), str(artifact["sha256"])
    )
    try:
        try:
            destination.mkdir(parents=True, mode=0o755, exist_ok=True)
            destination_info = destination.lstat()
        except OSError as error:
            raise LockError(
                f"cannot create sdist extraction root {destination}: {error}"
            ) from error
        if not stat.S_ISDIR(destination_info.st_mode) or destination.is_symlink():
            raise LockError(
                f"sdist extraction root must be a non-symlink directory: {destination}"
            )

        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            with tarfile.open(fileobj=handle, mode="r:gz") as archive:
                members = archive.getmembers()
                if len(members) > MAX_SDIST_MEMBERS:
                    raise LockError(f"sdist has too many members: {path.name}")
                seen_casefold: set[str] = set()
                total_uncompressed = 0
                prepared: list[tuple[tarfile.TarInfo, tuple[str, ...]]] = []
                for member in members:
                    parts = safe_member_parts(member.name)
                    if not (member.isfile() or member.isdir()):
                        raise LockError(
                            f"sdist contains a link or special file: {path.name}:{member.name}"
                        )
                    if member.size < 0 or member.size > MAX_SDIST_FILE_BYTES:
                        raise LockError(
                            f"sdist member exceeds size bound: {path.name}:{member.name}"
                        )
                    total_uncompressed += member.size
                    if total_uncompressed > MAX_SDIST_TOTAL_BYTES:
                        raise LockError("sdist extraction exceeds total size bound")
                    normalized = "/".join(parts).casefold()
                    if normalized in seen_casefold:
                        raise LockError(
                            f"sdist contains a duplicate/case-colliding path: {member.name}"
                        )
                    seen_casefold.add(normalized)
                    prepared.append((member, parts))

                nofollow = getattr(os, "O_NOFOLLOW", 0)
                binary = getattr(os, "O_BINARY", 0)
                for member, parts in prepared:
                    if member.isdir():
                        ensure_parent_directories(destination, parts)
                        continue
                    ensure_parent_directories(destination, parts[:-1])
                    target = destination.joinpath(*parts)
                    descriptor_out = os.open(
                        target,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow | binary,
                        0o644,
                    )
                    written = 0
                    try:
                        source = archive.extractfile(member)
                        if source is None:
                            raise LockError(
                                f"sdist regular member has no data: {member.name}"
                            )
                        with source:
                            with os.fdopen(
                                descriptor_out, "wb", closefd=False
                            ) as output:
                                while True:
                                    chunk = source.read(READ_CHUNK)
                                    if not chunk:
                                        break
                                    written += len(chunk)
                                    if written > member.size:
                                        raise LockError(
                                            f"sdist member expanded beyond declared size: {member.name}"
                                        )
                                    output.write(chunk)
                                output.flush()
                                os.fsync(output.fileno())
                    finally:
                        os.close(descriptor_out)
                    if written != member.size:
                        raise LockError(f"sdist member was truncated: {member.name}")
                    if member.mode & 0o111:
                        target.chmod(0o755)
    finally:
        os.close(descriptor)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--wheel-requirements", required=True, type=Path)
    parser.add_argument("--sdist-requirements", required=True, type=Path)
    parser.add_argument("--combined-requirements", type=Path)
    parser.add_argument("--sha256sums", required=True, type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--allow-ledger", action="store_true")
    parser.add_argument("--extract-wheels", type=Path)
    parser.add_argument("--extract-sdist", type=Path)
    parser.add_argument(
        "--wheel-role", choices=("all", "build", "runtime"), default="all"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        artifacts = load_lock(args.lock)
        validate_requirements(
            artifacts,
            args.wheel_requirements,
            args.sdist_requirements,
            args.combined_requirements,
        )
        validate_ledger(artifacts, args.sha256sums)
        if args.directory is not None:
            validate_directory(artifacts, args.directory, args.allow_ledger)
        elif args.extract_wheels is not None or args.extract_sdist is not None:
            raise LockError("artifact extraction requires --directory")
        if args.extract_wheels is not None:
            extract_wheels(
                artifacts, args.directory, args.extract_wheels, args.wheel_role
            )
        if args.extract_sdist is not None:
            extract_sdist(artifacts, args.directory, args.extract_sdist)
    except (LockError, OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"python artifact lock verification failed: {error}", file=sys.stderr)
        return 1
    print("python artifact lock verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
