#!/usr/bin/env python3
"""Build cargo-about 0.9.1 from its authenticated crate archive and lock."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tarfile
import time
import urllib.request


VERSION = "0.9.1"
ASSET_URL = "https://static.crates.io/crates/cargo-about/cargo-about-0.9.1.crate"
ASSET_SIZE = 96_994
ASSET_SHA256 = "4d62bfc04a579b87777727b0f5f389f72bdeb1c6cc8fbcf1c0e0c736c9b5b7a4"
ARCHIVE_ROOT = f"cargo-about-{VERSION}"
ARCHIVE_ENTRIES = 77
MAX_EXPANDED_BYTES = 2 * 1024 * 1024


class InstallError(RuntimeError):
    """The authenticated cargo-about installation cannot proceed safely."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download(destination: Path) -> None:
    request = urllib.request.Request(
        ASSET_URL,
        headers={"Accept-Encoding": "identity", "User-Agent": "ScanStudio-release"},
    )
    deadline = time.monotonic() + 180
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
        if response.geturl() != ASSET_URL:
            raise InstallError(f"unexpected cargo-about redirect: {response.geturl()}")
        if response.headers.get("Content-Encoding") not in (None, "identity"):
            raise InstallError("compressed HTTP transfer is not allowed")
        length = response.headers.get("Content-Length")
        if length != str(ASSET_SIZE):
            raise InstallError(
                f"cargo-about Content-Length mismatch: expected {ASSET_SIZE}, got {length!r}"
            )
        received = 0
        digest = hashlib.sha256()
        with destination.open("xb") as output:
            while chunk := response.read(min(1024 * 1024, ASSET_SIZE - received + 1)):
                if time.monotonic() > deadline:
                    raise InstallError("cargo-about download exceeded its deadline")
                received += len(chunk)
                if received > ASSET_SIZE:
                    raise InstallError("cargo-about download exceeded its pinned size")
                digest.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if received != ASSET_SIZE:
            raise InstallError(
                f"cargo-about download was short: expected {ASSET_SIZE}, got {received}"
            )
        if digest.hexdigest() != ASSET_SHA256:
            raise InstallError("cargo-about crate SHA-256 mismatch")


def member_path(name: str) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name:
        raise InstallError(f"unsafe cargo-about archive member: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or path.parts[0] != ARCHIVE_ROOT:
        raise InstallError(f"cargo-about archive member escaped its root: {name!r}")
    return path


def extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(mode=0o700)
    with tarfile.open(archive, mode="r:gz") as bundle:
        members = bundle.getmembers()
        if len(members) != ARCHIVE_ENTRIES:
            raise InstallError(
                f"cargo-about archive entry count changed: {len(members)}"
            )
        total = 0
        seen: set[str] = set()
        for member in members:
            path = member_path(member.name)
            key = path.as_posix().casefold()
            if key in seen:
                raise InstallError(f"colliding cargo-about member: {member.name!r}")
            seen.add(key)
            if member.isfile():
                total += member.size
                if member.size < 0 or total > MAX_EXPANDED_BYTES:
                    raise InstallError("cargo-about archive exceeds its expanded bound")
            elif not member.isdir():
                raise InstallError(
                    f"cargo-about archive contains a link or special entry: {member.name!r}"
                )
        bundle.extractall(destination, members=members, filter="data")
    source = destination / ARCHIVE_ROOT
    for required in ("Cargo.toml", "Cargo.lock", "src/cargo-about/main.rs"):
        path = source / required
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise InstallError(f"cargo-about source input is not a plain file: {path}")
    return source


def clean_cargo_environment(root: Path) -> dict[str, str]:
    forbidden = (
        "CARGO_REGISTRIES_",
        "CARGO_SOURCE_",
        "CARGO_HTTP_",
        "CARGO_NET_",
        "RUSTC_WRAPPER",
        "RUSTFLAGS",
    )
    inherited = [
        key for key in os.environ if any(key.startswith(prefix) for prefix in forbidden)
    ]
    if inherited:
        raise InstallError(
            "refusing inherited Cargo source/tool overrides: " + ", ".join(inherited)
        )
    environment = os.environ.copy()
    cargo_home = root / "cargo-home"
    cargo_home.mkdir(mode=0o700)
    environment.update(
        {
            "CARGO_HOME": str(cargo_home),
            "CARGO_NET_GIT_FETCH_WITH_CLI": "false",
            "CARGO_HTTP_TIMEOUT": "60",
            "CARGO_TERM_COLOR": "never",
        }
    )
    return environment


def append_github_path(path: Path | None, value: Path) -> None:
    if path is None:
        return
    if "\n" in str(value) or "\r" in str(value):
        raise InstallError("refusing a multiline GitHub PATH entry")
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(f"{value}\n")


def install(root: Path, github_path: Path | None) -> Path:
    try:
        root.mkdir(mode=0o700)
    except FileExistsError as error:
        raise InstallError(
            f"cargo-about install root already exists: {root}"
        ) from error
    archive = root / f"cargo-about-{VERSION}.crate"
    download(archive)
    if sha256_file(archive) != ASSET_SHA256:
        raise InstallError("cargo-about crate changed after download")
    source = extract(archive, root / "source")
    cargo = shutil.which("cargo")
    if cargo is None:
        raise InstallError("verified Cargo is unavailable")
    install_root = root / "installed"
    environment = clean_cargo_environment(root)
    subprocess.run(
        [
            cargo,
            "install",
            "--path",
            str(source),
            "--locked",
            "--features",
            "cli",
            "--root",
            str(install_root),
        ],
        check=True,
        timeout=900,
        env=environment,
    )
    executable = (
        install_root / "bin" / ("cargo-about.exe" if os.name == "nt" else "cargo-about")
    )
    metadata = executable.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise InstallError("built cargo-about is not a plain regular file")
    version = subprocess.run(
        [executable, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
        env=environment,
    ).stdout.strip()
    if version != f"cargo-about {VERSION}":
        raise InstallError(f"unexpected cargo-about version: {version!r}")
    append_github_path(github_path, executable.parent)
    print(
        f"Pinned cargo-about verified: version={version} crate={ASSET_SHA256} "
        f"binary_sha256={sha256_file(executable)}"
    )
    return executable


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--install-root", required=True, type=Path)
    parser.add_argument(
        "--github-path",
        type=Path,
        default=Path(os.environ["GITHUB_PATH"])
        if "GITHUB_PATH" in os.environ
        else None,
    )
    args = parser.parse_args()
    try:
        install(args.install_root, args.github_path)
    except (
        InstallError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
    ) as error:
        print(f"Pinned cargo-about installation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
