#!/usr/bin/env python3
"""Install hash-pinned uv and its exact managed CPython build for CI/release."""

from __future__ import annotations

import argparse
import hashlib
import json
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

UV_VERSION = "0.11.30"
PYTHON_VERSION = "3.13.14"
PYTHON_BUILD = "20260718"
ENSUREPIP_VERSION = "26.1.2"
PYTHON_MIRROR = "https://github.com/astral-sh/python-build-standalone/releases/download"
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_EXTRACTED_BYTES = 256 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 128

PLATFORMS = {
    ("Darwin", "arm64"): {
        "asset": "uv-aarch64-apple-darwin.tar.gz",
        "archive_sha256": "9bed3567d496d8dab84ecf7a1247551ac94ef1baaebb7b65df008dd93e9dc357",
        "executable": "uv-aarch64-apple-darwin/uv",
        "executable_sha256": "254a9afbcd66edd329a1a00ad5b0142c3285e6b354461800211ecffab74167fe",
        "python_machine": "arm64",
        "kind": "tar",
    },
    ("Darwin", "x86_64"): {
        "asset": "uv-x86_64-apple-darwin.tar.gz",
        "archive_sha256": "ce285fbbfbe294b1e1bc6c87c8b59d9622b85383b88b2b132a2df5c73e83d7c1",
        "executable": "uv-x86_64-apple-darwin/uv",
        "executable_sha256": "81ef2b6fb3e9959034393d1b55c7b0cca34be0fbaf8e2dac56a996d366c9c120",
        "python_machine": "x86_64",
        "kind": "tar",
    },
    ("Linux", "x86_64"): {
        "asset": "uv-x86_64-unknown-linux-gnu.tar.gz",
        "archive_sha256": "04bc7d180d6138bf6dc08387acf507a823f397a98fea55da36b0ccc7fbce3b68",
        "executable": "uv-x86_64-unknown-linux-gnu/uv",
        "executable_sha256": "9a4299a0c3bcc01012acbcdae7b5655e5087e0e5d87459306736a1420a902b81",
        "python_machine": "x86_64",
        "kind": "tar",
    },
    ("Windows", "AMD64"): {
        "asset": "uv-x86_64-pc-windows-msvc.zip",
        "archive_sha256": "be8d78c992312212e5cc05e9f9de3fa996db73b7c86a186dfb9231eb9f91d33e",
        # The authenticated Windows ZIP has exactly three root-level
        # executables, unlike the Unix archives' single directory root.
        "archive_root": None,
        "executable": "uv.exe",
        "executable_sha256": "2773193ff0f378c8b0c7e1417fb35f63a50dbd9fa9a09174aef7cce313e7789e",
        "python_machine": "AMD64",
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


def validated_member_path(name: str, expected_root: str | None) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name:
        raise InstallError(f"unsafe archive member name: {name!r}")
    path = PurePosixPath(name)
    if (
        path.is_absolute()
        or ".." in path.parts
        or any(part in {"", "."} for part in path.parts)
        or expected_root is not None
        and path.parts[0] != expected_root
    ):
        raise InstallError(f"archive member escapes the expected root: {name!r}")
    return path


def download(url: str, destination: Path) -> None:
    deadline = time.monotonic() + 180
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
        final_url = response.geturl()
        if not final_url.startswith("https://"):
            raise InstallError(f"uv download left HTTPS: {final_url}")
        if response.headers.get("Content-Encoding") not in (None, "identity"):
            raise InstallError("compressed HTTP transfer is not allowed")
        length_header = response.headers.get("Content-Length")
        if length_header is None or not length_header.isdecimal():
            raise InstallError("uv download omitted a valid Content-Length")
        expected_length = int(length_header)
        if expected_length <= 0 or expected_length > MAX_ARCHIVE_BYTES:
            raise InstallError("uv download length is outside the allowed bound")
        received = 0
        with destination.open("xb") as output:
            while chunk := response.read(
                min(1024 * 1024, expected_length - received + 1)
            ):
                if time.monotonic() > deadline:
                    raise InstallError("uv download exceeded its total deadline")
                received += len(chunk)
                if received > expected_length or received > MAX_ARCHIVE_BYTES:
                    raise InstallError("uv download exceeded its declared length")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if received != expected_length:
            raise InstallError(
                f"uv download length mismatch: expected {expected_length}, got {received}"
            )


def extract_tar(archive: Path, destination: Path, expected_root: str) -> None:
    with tarfile.open(archive, mode="r:gz") as bundle:
        members = bundle.getmembers()
        if not members or len(members) > MAX_ARCHIVE_ENTRIES:
            raise InstallError("uv tar entry count is outside the allowed bound")
        total = 0
        seen: set[str] = set()
        for member in members:
            path = validated_member_path(member.name, expected_root)
            key = path.as_posix().rstrip("/").casefold()
            if key in seen:
                raise InstallError(
                    f"duplicate/colliding uv tar member: {member.name!r}"
                )
            seen.add(key)
            if member.isfile():
                total += member.size
                if member.size < 0 or total > MAX_EXTRACTED_BYTES:
                    raise InstallError("uv tar payload exceeds the allowed bound")
            elif not member.isdir():
                raise InstallError(f"unsupported uv tar entry type: {member.name!r}")
        bundle.extractall(destination, members=members, filter="data")


def extract_zip(archive: Path, destination: Path, expected_root: str | None) -> None:
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if not members or len(members) > MAX_ARCHIVE_ENTRIES:
            raise InstallError("uv zip entry count is outside the allowed bound")
        total = 0
        seen: set[str] = set()
        for member in members:
            path = validated_member_path(member.filename, expected_root)
            key = path.as_posix().rstrip("/").casefold()
            if key in seen:
                raise InstallError(
                    f"duplicate/colliding uv zip member: {member.filename!r}"
                )
            seen.add(key)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise InstallError(
                    f"uv zip contains a symbolic link: {member.filename!r}"
                )
            file_type = stat.S_IFMT(mode)
            if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise InstallError(
                    f"uv zip contains a special entry: {member.filename!r}"
                )
            total += member.file_size
            if total > MAX_EXTRACTED_BYTES:
                raise InstallError("uv zip payload exceeds the allowed bound")
        bundle.extractall(destination)


def clean_uv_environment(install_root: Path) -> dict[str, str]:
    allowed_parent_keys = {
        "COMSPEC",
        "HOME",
        "LANG",
        "LC_ALL",
        "PATH",
        "PATHEXT",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "SYSTEMROOT",
        "SystemRoot",
        "TEMP",
        "TMP",
        "TMPDIR",
        "USERPROFILE",
        "WINDIR",
    }
    environment = {
        key: value for key, value in os.environ.items() if key in allowed_parent_keys
    }
    config = install_root / "empty-uv.toml"
    with config.open("xb") as handle:
        handle.flush()
        os.fsync(handle.fileno())
    environment.update(
        {
            "UV_NO_CONFIG": "1",
            "UV_CONFIG_FILE": str(config),
            "UV_PYTHON": PYTHON_VERSION,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_PYTHON_DOWNLOADS": "automatic",
            "UV_PYTHON_CPYTHON_BUILD": PYTHON_BUILD,
            "UV_PYTHON_DOWNLOADS_JSON_URL": "",
            "UV_PYTHON_INSTALL_MIRROR": PYTHON_MIRROR,
            "UV_ASTRAL_MIRROR_URL": "",
            "UV_PYTHON_NO_REGISTRY": "1",
            "UV_PYTHON_INSTALL_REGISTRY": "0",
            "UV_PYTHON_INSTALL_DIR": str(install_root / "python"),
            "UV_PYTHON_CACHE_DIR": str(install_root / "python-cache"),
            "UV_CACHE_DIR": str(install_root / "uv-cache"),
            "UV_NO_PROGRESS": "1",
            "UV_NO_MODIFY_PATH": "1",
        }
    )
    if platform.system() == "Linux":
        environment["UV_LIBC"] = "gnu"
    return environment


def append_github_file(path: Path | None, lines: list[str]) -> None:
    if path is None:
        return
    for line in lines:
        if "\n" in line or "\r" in line:
            raise InstallError("refusing a multiline GitHub environment value")
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        for line in lines:
            handle.write(f"{line}\n")


def install(
    install_root: Path, github_path: Path | None, github_env: Path | None
) -> None:
    platform_key = (platform.system(), platform.machine())
    details = PLATFORMS.get(platform_key)
    if details is None:
        raise InstallError(f"unsupported uv build host: {platform_key!r}")
    try:
        install_root.mkdir(mode=0o700)
    except FileExistsError as error:
        raise InstallError(
            f"toolchain install root already exists: {install_root}"
        ) from error

    asset = str(details["asset"])
    archive = install_root / asset
    url = f"https://github.com/astral-sh/uv/releases/download/{UV_VERSION}/{asset}"
    download(url, archive)
    archive_sha = sha256_file(archive)
    if archive_sha != details["archive_sha256"]:
        raise InstallError(
            f"uv archive digest mismatch: expected {details['archive_sha256']}, got {archive_sha}"
        )
    expected_root = details.get(
        "archive_root", asset.removesuffix(".tar.gz").removesuffix(".zip")
    )
    if details["kind"] == "tar":
        extract_tar(archive, install_root, expected_root)
    else:
        extract_zip(archive, install_root, expected_root)

    uv = install_root / str(details["executable"])
    if uv.is_symlink() or not uv.is_file():
        raise InstallError("uv executable is not a regular non-link file")
    executable_sha = sha256_file(uv)
    if executable_sha != details["executable_sha256"]:
        raise InstallError(
            f"uv executable digest mismatch: expected {details['executable_sha256']}, "
            f"got {executable_sha}"
        )
    environment = clean_uv_environment(install_root)
    uv_version = subprocess.run(
        [uv, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
        env=environment,
    ).stdout.strip()
    if uv_version.split()[:2] != ["uv", UV_VERSION]:
        raise InstallError(f"unexpected uv version: {uv_version!r}")

    venv = install_root / "venv"
    subprocess.run(
        [
            uv,
            "venv",
            str(venv),
            "--python",
            PYTHON_VERSION,
            "--no-project",
            "--clear",
        ],
        check=True,
        timeout=300,
        cwd=install_root,
        env=environment,
    )
    venv_bin = venv / ("Scripts" if platform.system() == "Windows" else "bin")
    python = venv_bin / ("python.exe" if platform.system() == "Windows" else "python3")
    # The exact PBS archive carries CPython's bundled ensurepip wheel. Use that
    # already-authenticated byte source instead of resolving a mutable pip from
    # an index; packaging helpers legitimately need ``python -m pip download``.
    subprocess.run(
        [python, "-I", "-B", "-m", "ensurepip", "--default-pip"],
        check=True,
        timeout=120,
        cwd=install_root,
        env=environment,
    )
    pip_probe = subprocess.run(
        [
            python,
            "-I",
            "-B",
            "-c",
            (
                "import json,pip; "
                "print(json.dumps({'version': pip.__version__, 'file': pip.__file__}))"
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
        env=environment,
    )
    pip_identity = json.loads(pip_probe.stdout)
    if pip_identity["version"] != ENSUREPIP_VERSION:
        raise InstallError(f"unexpected ensurepip version: {pip_identity['version']!r}")
    if not Path(pip_identity["file"]).resolve().is_relative_to(venv.resolve()):
        raise InstallError("ensurepip package escaped the private venv")
    probe = subprocess.run(
        [
            python,
            "-I",
            "-B",
            "-c",
            (
                "import json,platform,sys; "
                "print(json.dumps({'version': list(sys.version_info[:3]), "
                "'machine': platform.machine(), 'executable': sys.executable, "
                "'prefix': sys.prefix, 'base_prefix': sys.base_prefix}))"
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
        env=environment,
    )
    identity = json.loads(probe.stdout)
    if identity["version"] != [3, 13, 14]:
        raise InstallError(
            f"unexpected managed Python version: {identity['version']!r}"
        )
    if identity["machine"].casefold() != str(details["python_machine"]).casefold():
        raise InstallError(
            f"unexpected managed Python architecture: {identity['machine']!r}"
        )
    if not Path(identity["prefix"]).resolve().is_relative_to(venv.resolve()):
        raise InstallError("managed Python prefix escaped the private venv")
    python_root = (install_root / "python").resolve()
    base_prefix = Path(identity["base_prefix"]).resolve()
    if not base_prefix.is_relative_to(python_root):
        raise InstallError(
            "managed Python base prefix escaped the private install root"
        )
    if base_prefix.parent != python_root:
        raise InstallError("managed Python base prefix was not an exact private child")
    build_file = base_prefix / "BUILD"
    if (
        build_file.is_symlink()
        or not build_file.is_file()
        or build_file.read_bytes() != PYTHON_BUILD.encode("ascii")
    ):
        raise InstallError("managed Python did not carry the exact PBS build identity")

    uv_dir = uv.parent
    append_github_file(github_path, [str(uv_dir), str(venv_bin)])
    exported_environment = {
        key: value for key, value in environment.items() if key.startswith("UV_")
    }
    exported_environment["VIRTUAL_ENV"] = str(venv)
    append_github_file(
        github_env,
        [f"{key}={value}" for key, value in sorted(exported_environment.items())],
    )
    print(
        f"Pinned uv/Python verified: uv={uv_version} uv_archive={archive_sha} "
        f"uv_executable={executable_sha} python={identity['version']} "
        f"pbs_build={PYTHON_BUILD} pip={pip_identity['version']} "
        f"machine={identity['machine']}"
    )


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
        ValueError,
        subprocess.SubprocessError,
        tarfile.TarError,
        zipfile.BadZipFile,
    ) as error:
        print(f"Pinned uv/Python installation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
