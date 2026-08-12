#!/usr/bin/env python3
"""Install the exact Node.js build used by ScanStudio packaging workflows."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import platform
import stat
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile

VERSION = "22.23.2"
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_EXTRACTED_BYTES = 768 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 100_000

PLATFORMS = {
    ("Darwin", "arm64"): {
        "asset": f"node-v{VERSION}-darwin-arm64.tar.gz",
        "archive_sha256": "61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6",
        "executable": f"node-v{VERSION}-darwin-arm64/bin/node",
        "executable_sha256": "18e387c90ab8a8400183e8bdd396376e1e875b91b4c874b894dcade7b35bf572",
        "path": f"node-v{VERSION}-darwin-arm64/bin",
        "npm_cli": f"node-v{VERSION}-darwin-arm64/lib/node_modules/npm/bin/npm-cli.js",
        "node_arch": "arm64",
        "kind": "tar",
    },
    ("Darwin", "x86_64"): {
        "asset": f"node-v{VERSION}-darwin-x64.tar.gz",
        "archive_sha256": "58e99022c2ff89395576cc7fd4d98cea24bb68081475d5f88b801ee8729fb026",
        "executable": f"node-v{VERSION}-darwin-x64/bin/node",
        "executable_sha256": "0b4f059915f3bf3c6cbb02422f4a529bfb21cbbec2d29851c9a5d833f78a04f6",
        "path": f"node-v{VERSION}-darwin-x64/bin",
        "npm_cli": f"node-v{VERSION}-darwin-x64/lib/node_modules/npm/bin/npm-cli.js",
        "node_arch": "x64",
        "kind": "tar",
    },
    ("Linux", "x86_64"): {
        "asset": f"node-v{VERSION}-linux-x64.tar.xz",
        "archive_sha256": "d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307",
        "executable": f"node-v{VERSION}-linux-x64/bin/node",
        "executable_sha256": "3517c2df0b2f8cd7f422b4b8450ef81c6889f08eb03e281d6de9079b15e6a327",
        "path": f"node-v{VERSION}-linux-x64/bin",
        "npm_cli": f"node-v{VERSION}-linux-x64/lib/node_modules/npm/bin/npm-cli.js",
        "node_arch": "x64",
        "kind": "tar",
    },
    ("Windows", "AMD64"): {
        "asset": f"node-v{VERSION}-win-x64.zip",
        "archive_sha256": "1177b4137ba5adaa56354ae40f1080c7450e8ae09cecb47da459d1c52ac99f97",
        "executable": f"node-v{VERSION}-win-x64/node.exe",
        "executable_sha256": "0d0f5e39f9f3d9587bc19f73eab3c2c9c4903fd02d6dbf9c853dd81b3d95fad4",
        "path": f"node-v{VERSION}-win-x64",
        "npm_cli": f"node-v{VERSION}-win-x64/node_modules/npm/bin/npm-cli.js",
        "node_arch": "x64",
        "kind": "zip",
    },
}


class InstallError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validated_member_path(name: str, expected_root: str) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name:
        raise InstallError(f"unsafe archive member name: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or path.parts[0] != expected_root:
        raise InstallError(f"archive member escapes the expected root: {name!r}")
    return path


def validated_link_target(
    member: PurePosixPath, target: str, expected_root: str
) -> None:
    if not target or "\\" in target or "\x00" in target:
        raise InstallError(f"unsafe archive link target: {target!r}")
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        raise InstallError(f"absolute archive link target: {target!r}")
    combined: list[str] = []
    for component in (*member.parent.parts, *target_path.parts):
        if component in ("", "."):
            continue
        if component == "..":
            if not combined:
                raise InstallError(f"archive link escapes root: {target!r}")
            combined.pop()
        else:
            combined.append(component)
    if not combined or combined[0] != expected_root:
        raise InstallError(f"archive link escapes root: {target!r}")


def ensure_directory_chain(root: Path, parts: tuple[str, ...]) -> Path:
    current = root
    for part in parts:
        current /= part
        try:
            current.mkdir(mode=0o755)
        except FileExistsError:
            metadata = current.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or current.is_symlink():
                raise InstallError(
                    f"Node extraction parent is not a safe directory: {current}"
                )
    return current


def download(url: str, destination: Path) -> None:
    deadline = time.monotonic() + 180
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
        if response.geturl() != url:
            raise InstallError(
                f"unexpected Node download redirect: {response.geturl()}"
            )
        if response.headers.get("Content-Encoding") not in (None, "identity"):
            raise InstallError("compressed HTTP transfer is not allowed")
        length_header = response.headers.get("Content-Length")
        if length_header is None or not length_header.isdecimal():
            raise InstallError("Node download omitted a valid Content-Length")
        expected_length = int(length_header)
        if expected_length <= 0 or expected_length > MAX_ARCHIVE_BYTES:
            raise InstallError("Node download length is outside the allowed bound")
        received = 0
        with destination.open("xb") as output:
            while chunk := response.read(
                min(1024 * 1024, expected_length - received + 1)
            ):
                if time.monotonic() > deadline:
                    raise InstallError("Node download exceeded its total deadline")
                received += len(chunk)
                if received > expected_length or received > MAX_ARCHIVE_BYTES:
                    raise InstallError("Node download exceeded its declared length")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if received != expected_length:
            raise InstallError(
                f"Node download length mismatch: expected {expected_length}, got {received}"
            )


def extract_tar(archive: Path, destination: Path, expected_root: str) -> None:
    mode = "r:gz" if archive.name.endswith(".tar.gz") else "r:xz"
    with tarfile.open(archive, mode=mode) as bundle:
        members = bundle.getmembers()
        if not members or len(members) > MAX_ARCHIVE_ENTRIES:
            raise InstallError("Node tar entry count is outside the allowed bound")
        total = 0
        seen: set[str] = set()
        prepared: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
        for member in members:
            path = validated_member_path(member.name, expected_root)
            key = path.as_posix().rstrip("/").casefold()
            if key in seen:
                raise InstallError(
                    f"duplicate/colliding Node tar member: {member.name!r}"
                )
            seen.add(key)
            if member.isfile():
                total += member.size
                if member.size < 0 or total > MAX_EXTRACTED_BYTES:
                    raise InstallError("Node tar payload exceeds the allowed bound")
            elif member.issym():
                validated_link_target(path, member.linkname, expected_root)
            elif member.islnk():
                raise InstallError(f"Node tar contains a hard link: {member.name!r}")
            elif not member.isdir():
                raise InstallError(f"unsupported Node tar entry type: {member.name!r}")
            prepared.append((member, path))

        # Python 3.10's backported ``data`` filter rejects Node's legitimate
        # ``bin/npm -> ../lib/...`` link on Ubuntu 22.04 by resolving it from
        # the extraction root instead of the link's parent. Extract the fully
        # prevalidated archive ourselves so the same create-only containment
        # policy works on every declared build host.
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        for member, path in prepared:
            parent = ensure_directory_chain(destination, path.parts[:-1])
            target = parent / path.name
            if member.isdir():
                ensure_directory_chain(destination, path.parts)
                continue
            if member.issym():
                os.symlink(member.linkname, target)
                continue

            source = bundle.extractfile(member)
            if source is None:
                raise InstallError(f"could not open Node tar member: {member.name!r}")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow
            descriptor = os.open(target, flags, member.mode & 0o777)
            written = 0
            try:
                with source, os.fdopen(descriptor, "wb", closefd=False) as output:
                    while chunk := source.read(1024 * 1024):
                        written += len(chunk)
                        if written > member.size:
                            raise InstallError(
                                f"Node tar member exceeded its size: {member.name!r}"
                            )
                        output.write(chunk)
                    output.flush()
                    os.fsync(output.fileno())
            finally:
                os.close(descriptor)
            if written != member.size:
                raise InstallError(f"short Node tar member: {member.name!r}")


def extract_zip(archive: Path, destination: Path, expected_root: str) -> None:
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if not members or len(members) > MAX_ARCHIVE_ENTRIES:
            raise InstallError("Node zip entry count is outside the allowed bound")
        total = 0
        seen: set[str] = set()
        for member in members:
            path = validated_member_path(member.filename, expected_root)
            key = path.as_posix().rstrip("/").casefold()
            if key in seen:
                raise InstallError(
                    f"duplicate/colliding Node zip member: {member.filename!r}"
                )
            seen.add(key)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise InstallError(
                    f"Node zip contains a symbolic link: {member.filename!r}"
                )
            file_type = stat.S_IFMT(mode)
            if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise InstallError(
                    f"Node zip contains a special entry: {member.filename!r}"
                )
            total += member.file_size
            if total > MAX_EXTRACTED_BYTES:
                raise InstallError("Node zip payload exceeds the allowed bound")
        bundle.extractall(destination)


def install(
    install_root: Path, github_path: Path | None, github_env: Path | None
) -> Path:
    platform_key = (platform.system(), platform.machine())
    details = PLATFORMS.get(platform_key)
    if details is None:
        raise InstallError(f"unsupported Node build host: {platform_key!r}")
    try:
        install_root.mkdir(mode=0o700)
    except FileExistsError as error:
        raise InstallError(
            f"Node install root already exists: {install_root}"
        ) from error

    asset = str(details["asset"])
    archive = install_root / asset
    url = f"https://nodejs.org/dist/v{VERSION}/{asset}"
    download(url, archive)
    actual_archive_sha = sha256_file(archive)
    if actual_archive_sha != details["archive_sha256"]:
        raise InstallError(
            f"Node archive digest mismatch: expected {details['archive_sha256']}, "
            f"got {actual_archive_sha}"
        )

    expected_root = (
        asset.removesuffix(".tar.gz").removesuffix(".tar.xz").removesuffix(".zip")
    )
    if details["kind"] == "tar":
        extract_tar(archive, install_root, expected_root)
    else:
        extract_zip(archive, install_root, expected_root)

    executable = install_root / str(details["executable"])
    if executable.is_symlink() or not executable.is_file():
        raise InstallError("Node executable is not a regular non-link file")
    actual_executable_sha = sha256_file(executable)
    if actual_executable_sha != details["executable_sha256"]:
        raise InstallError(
            f"Node executable digest mismatch: expected {details['executable_sha256']}, "
            f"got {actual_executable_sha}"
        )
    version = subprocess.run(
        [executable, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    ).stdout.strip()
    if version != f"v{VERSION}":
        raise InstallError(f"unexpected Node runtime version: {version!r}")

    node_arch = subprocess.run(
        [executable, "-p", "process.arch"],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    ).stdout.strip()
    if node_arch != details["node_arch"]:
        raise InstallError(f"unexpected Node architecture: {node_arch!r}")
    npm_cli = install_root / str(details["npm_cli"])
    if npm_cli.is_symlink() or not npm_cli.is_file():
        raise InstallError("npm CLI is not a regular non-link file")
    npm_version = subprocess.run(
        [executable, npm_cli, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    ).stdout.strip()
    if npm_version != "10.9.8":
        raise InstallError(f"unexpected npm version: {npm_version!r}")

    bin_path = install_root / str(details["path"])
    if github_path is not None:
        with github_path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(f"{bin_path}\n")
    if github_env is not None:
        with github_env.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(f"SCANSTUDIO_NODE_BIN={bin_path}\n")
    print(
        f"Pinned Node verified: version={version} archive={actual_archive_sha} "
        f"executable={actual_executable_sha} npm={npm_version} arch={node_arch} "
        f"path={bin_path}"
    )
    return bin_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--install-root", type=Path, required=True)
    parser.add_argument(
        "--github-path",
        type=Path,
        default=Path(os.environ["GITHUB_PATH"])
        if "GITHUB_PATH" in os.environ
        else None,
    )
    parser.add_argument(
        "--github-env",
        type=Path,
        default=Path(os.environ["GITHUB_ENV"]) if "GITHUB_ENV" in os.environ else None,
    )
    args = parser.parse_args()
    try:
        install(args.install_root, args.github_path, args.github_env)
    except (
        InstallError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
        zipfile.BadZipFile,
    ) as error:
        print(f"Pinned Node installation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
