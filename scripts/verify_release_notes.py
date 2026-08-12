#!/usr/bin/env python3
"""Verify the full, tag-bound GitHub release notes before publication."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MIN_RELEASE_NOTES_BYTES = 1024
MAX_RELEASE_NOTES_BYTES = 128 * 1024
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?")
PLACEHOLDER_RE = re.compile(r"\b(?:TODO|TBD|CHANGEME)\b|\{\{|\}\}", re.IGNORECASE)
REQUIRED_SECTIONS = (
    "## Everything that changed",
    "## Validation",
    "## Platform support and installation",
    "## Known limitations",
)


class ReleaseNotesError(ValueError):
    """The release notes are not safe or complete enough to publish."""


def _require_real_directory(path: Path, role: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReleaseNotesError(
            f"{role} is missing or unreadable: {path}: {error}"
        ) from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ReleaseNotesError(f"{role} must be a real, non-symlink directory: {path}")


def _read_held_regular_file(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ReleaseNotesError(
            f"release notes must be an openable, non-symlink file: {path}: {error}"
        ) from error

    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise ReleaseNotesError(f"release notes are not a regular file: {path}")
        if not MIN_RELEASE_NOTES_BYTES <= opened.st_size <= MAX_RELEASE_NOTES_BYTES:
            raise ReleaseNotesError(
                "release notes size must be between "
                f"{MIN_RELEASE_NOTES_BYTES} and {MAX_RELEASE_NOTES_BYTES} bytes; "
                f"found {opened.st_size}"
            )

        chunks: list[bytes] = []
        remaining = MAX_RELEASE_NOTES_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) != opened.st_size:
            raise ReleaseNotesError(
                "release notes changed or could not be read completely while held open"
            )

        opened_after = os.fstat(descriptor)
        opened_snapshot = (
            opened.st_dev,
            opened.st_ino,
            opened.st_size,
            opened.st_mtime_ns,
            opened.st_ctime_ns,
        )
        opened_after_snapshot = (
            opened_after.st_dev,
            opened_after.st_ino,
            opened_after.st_size,
            opened_after.st_mtime_ns,
            opened_after.st_ctime_ns,
        )
        if opened_after_snapshot != opened_snapshot:
            raise ReleaseNotesError("release notes changed while the file was read")

        named = path.stat(follow_symlinks=False)
        opened_identity = (opened.st_dev, opened.st_ino)
        named_identity = (named.st_dev, named.st_ino)
        if (
            not stat.S_ISREG(named.st_mode)
            or opened_identity != named_identity
            or named.st_size != opened.st_size
            or named.st_mtime_ns != opened.st_mtime_ns
            or named.st_ctime_ns != opened.st_ctime_ns
        ):
            raise ReleaseNotesError(
                "release notes pathname changed while the file was read"
            )
        return payload
    except OSError as error:
        raise ReleaseNotesError(
            f"could not read held release notes: {path}: {error}"
        ) from error
    finally:
        os.close(descriptor)


def verify_release_notes(
    notes_path: Path,
    tag: str,
    version: str,
    *,
    repository_root: Path = REPOSITORY_ROOT,
) -> tuple[int, str]:
    """Validate and return ``(byte_count, sha256)`` for one release-note file."""

    if VERSION_RE.fullmatch(version) is None:
        raise ReleaseNotesError(f"invalid release version: {version!r}")
    expected_tag = f"v{version}"
    if tag != expected_tag:
        raise ReleaseNotesError(
            f"tag/version mismatch: tag must be {expected_tag!r}, found {tag!r}"
        )

    root = repository_root.resolve(strict=True)
    docs_root = root / "docs"
    releases_root = docs_root / "releases"
    _require_real_directory(docs_root, "documentation root")
    _require_real_directory(releases_root, "release-notes directory")

    expected_path = releases_root / f"{tag}.md"
    supplied_path = notes_path if notes_path.is_absolute() else root / notes_path
    try:
        supplied_resolved = supplied_path.resolve(strict=True)
        expected_resolved = expected_path.resolve(strict=True)
    except OSError as error:
        raise ReleaseNotesError(
            f"tag-bound release notes are missing or unreadable: {expected_path}: {error}"
        ) from error
    if supplied_resolved != expected_resolved or supplied_path.name != f"{tag}.md":
        raise ReleaseNotesError(
            "release notes path must be exactly "
            f"docs/releases/{tag}.md inside the tagged checkout"
        )
    if expected_path.is_symlink():
        raise ReleaseNotesError(f"release notes must not be a symlink: {expected_path}")

    payload = _read_held_regular_file(expected_path)
    if b"\x00" in payload:
        raise ReleaseNotesError("release notes contain a NUL byte")
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ReleaseNotesError("release notes are not valid UTF-8") from error
    if "\r" in text:
        raise ReleaseNotesError("release notes must use LF line endings")
    if not text.endswith("\n"):
        raise ReleaseNotesError("release notes must end with one LF newline")
    if PLACEHOLDER_RE.search(text):
        raise ReleaseNotesError("release notes still contain a placeholder token")

    lines = text.splitlines()
    expected_title = f"# ScanStudio {tag}"
    if not lines or lines[0] != expected_title:
        raise ReleaseNotesError(
            f"release notes must start with the exact title {expected_title!r}"
        )

    positions: list[int] = []
    for section in REQUIRED_SECTIONS:
        matches = [index for index, line in enumerate(lines) if line == section]
        if len(matches) != 1:
            raise ReleaseNotesError(
                f"release notes must contain exactly one {section!r} section"
            )
        positions.append(matches[0])
    if positions != sorted(positions):
        raise ReleaseNotesError("required release-note sections are out of order")

    section_ends = positions[1:] + [len(lines)]
    for section, start, end in zip(REQUIRED_SECTIONS, positions, section_ends):
        body = [line for line in lines[start + 1 : end] if line.strip()]
        if not body:
            raise ReleaseNotesError(f"release-note section {section!r} is empty")

    return len(payload), hashlib.sha256(payload).hexdigest()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("notes_path", type=Path)
    parser.add_argument("tag")
    parser.add_argument("version")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        byte_count, digest = verify_release_notes(
            args.notes_path,
            args.tag,
            args.version,
        )
    except (OSError, ReleaseNotesError) as error:
        print(f"Release-note verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "Tag-bound full release notes verified: "
        f"tag={args.tag} bytes={byte_count} sha256={digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
