#!/usr/bin/env python3
"""Fetch and safely extract the exact CoolScanPy sdist accepted for release."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import time
import tomllib
import unicodedata
import urllib.request


VERSION = "0.7.2"
FILENAME = f"coolscanpy-{VERSION}.tar.gz"
URL = (
    "https://files.pythonhosted.org/packages/94/df/"
    "6f07433d58ed06caf6cfc37692b894d203567a28fca8e4466083e8f02c20/"
    f"{FILENAME}"
)
SIZE = 546_175
SHA256 = "6a354e98da623f38c2ca33764887621eba99f780d5e765ec69b690192176324f"
ROOT = f"coolscanpy-{VERSION}"
ENTRY_COUNT = 104
FILE_COUNT = 89
DIRECTORY_COUNT = 15
EXPANDED_FILE_BYTES = 2_404_264


class FetchError(RuntimeError):
    """The published source cannot be authenticated or safely extracted."""


def download(destination: Path) -> None:
    request = urllib.request.Request(
        URL,
        headers={"Accept-Encoding": "identity", "User-Agent": "ScanStudio-release"},
    )
    deadline = time.monotonic() + 180
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
        if response.geturl() != URL:
            raise FetchError(f"unexpected CoolScanPy redirect: {response.geturl()}")
        if response.headers.get("Content-Encoding") not in (None, "identity"):
            raise FetchError("compressed HTTP transfer is not allowed")
        if response.headers.get("Content-Length") != str(SIZE):
            raise FetchError("CoolScanPy sdist Content-Length changed")
        received = 0
        digest = hashlib.sha256()
        with destination.open("xb") as output:
            while chunk := response.read(min(1024 * 1024, SIZE - received + 1)):
                if time.monotonic() > deadline:
                    raise FetchError("CoolScanPy sdist download exceeded its deadline")
                received += len(chunk)
                if received > SIZE:
                    raise FetchError("CoolScanPy sdist exceeded its pinned size")
                digest.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if received != SIZE or digest.hexdigest() != SHA256:
            raise FetchError("CoolScanPy sdist size or SHA-256 mismatch")


def member_path(name: str) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name:
        raise FetchError(f"unsafe CoolScanPy archive member: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or path.parts[0] != ROOT:
        raise FetchError(f"CoolScanPy archive member escaped its root: {name!r}")
    if any(part in ("", ".") for part in path.parts):
        raise FetchError(f"ambiguous CoolScanPy archive member: {name!r}")
    return path


def extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(mode=0o700)
    with tarfile.open(archive, mode="r:gz") as bundle:
        members = bundle.getmembers()
        files = sum(member.isfile() for member in members)
        directories = sum(member.isdir() for member in members)
        total = sum(member.size for member in members if member.isfile())
        actual_shape = (len(members), files, directories, total)
        expected_shape = (
            ENTRY_COUNT,
            FILE_COUNT,
            DIRECTORY_COUNT,
            EXPANDED_FILE_BYTES,
        )
        if actual_shape != expected_shape:
            raise FetchError(
                f"CoolScanPy archive shape changed: {actual_shape} != {expected_shape}"
            )
        validated: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
        seen: set[str] = set()
        for member in members:
            path = member_path(member.name)
            key = unicodedata.normalize("NFC", path.as_posix()).casefold()
            if key in seen:
                raise FetchError(
                    f"colliding CoolScanPy archive member: {member.name!r}"
                )
            seen.add(key)
            if not member.isfile() and not member.isdir():
                raise FetchError(
                    f"CoolScanPy archive contains a link or special entry: {member.name!r}"
                )
            validated.append((member, path))

        for member, path in validated:
            output = destination.joinpath(*path.parts)
            if member.isdir():
                output.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                raise FetchError(f"could not open CoolScanPy member: {member.name!r}")
            copied = 0
            with source, output.open("xb") as target:
                while chunk := source.read(1024 * 1024):
                    copied += len(chunk)
                    if copied > member.size:
                        raise FetchError(
                            f"CoolScanPy member exceeded its size: {member.name!r}"
                        )
                    target.write(chunk)
                target.flush()
                os.fsync(target.fileno())
            if copied != member.size:
                raise FetchError(f"short CoolScanPy member: {member.name!r}")

    source_root = destination / ROOT
    pyproject = source_root / "pyproject.toml"
    metadata = pyproject.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise FetchError("published CoolScanPy pyproject is not a plain file")
    with pyproject.open("rb") as handle:
        published_version = tomllib.load(handle)["project"]["version"]
    if published_version != VERSION:
        raise FetchError(f"published CoolScanPy version changed: {published_version!r}")
    return source_root


def fetch(destination: Path, repository_root: Path) -> Path:
    with (repository_root / "coolscanpy" / "pyproject.toml").open("rb") as handle:
        vendored_version = tomllib.load(handle)["project"]["version"]
    if vendored_version != VERSION:
        raise FetchError(
            f"vendored CoolScanPy version {vendored_version!r} is not pinned {VERSION!r}"
        )
    try:
        destination.mkdir(mode=0o700)
    except FileExistsError as error:
        raise FetchError(f"source destination already exists: {destination}") from error
    archive = destination / FILENAME
    download(archive)
    source = extract(archive, destination / "extracted")
    print(source)
    return source


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument(
        "--repository-root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    args = parser.parse_args()
    try:
        fetch(args.destination, args.repository_root)
    except (FetchError, OSError, KeyError, tarfile.TarError) as error:
        print(f"Pinned CoolScanPy source fetch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
