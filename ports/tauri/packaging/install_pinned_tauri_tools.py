#!/usr/bin/env python3
"""Prepare and verify Tauri 2.11.4's unpackaged external build tools.

Cargo and npm locks do not cover the programs that Tauri downloads while it
builds AppImage and NSIS bundles.  Release packaging calls this program before
Tauri so those mutable downloads are replaced by an exact, private tool tree.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import time
import unicodedata
import urllib.request
import zipfile


TAURI_VERSION = "2.11.4"
DOWNLOAD_DEADLINE_SECONDS = 900
DOWNLOAD_CHUNK_BYTES = 1024 * 1024
MAX_NSIS_ENTRIES = 1_000
MAX_NSIS_EXPANDED_BYTES = 32 * 1024 * 1024

DANGEROUS_ENVIRONMENT = (
    "CARGO_TARGET_DIR",
    "NSIS_PATH",
    "TAURI_BUNDLER_TOOLS_GITHUB_MIRROR",
    "TAURI_BUNDLER_TOOLS_GITHUB_MIRROR_TEMPLATE",
)

LINUX_ASSETS = (
    {
        "name": "AppRun-x86_64",
        "url": (
            "https://api.github.com/repos/tauri-apps/binary-releases/"
            "releases/assets/274691722"
        ),
        "size": 31_552,
        "sha256": "f30140a43a0a59e46db21bdefdf749b9e9f2c6946e92afabbacf98b8ae73fb4f",
    },
    {
        "name": "linuxdeploy-x86_64.AppImage",
        "url": (
            "https://api.github.com/repos/tauri-apps/binary-releases/"
            "releases/assets/182515537"
        ),
        "size": 13_264_064,
        "sha256": "e762bea85c8eb0d4b3508d46e5c1f037f717d0f9303ae3b4aafc8b04991fa1ef",
        "installed_sha256": (
            "20eebde3c18ae2e44279bd624fc72482503aece216d5d77f10932235342f71c1"
        ),
        "zero_range": (8, 11),
    },
    {
        "name": "linuxdeploy-plugin-gtk.sh",
        "url": (
            "https://raw.githubusercontent.com/tauri-apps/"
            "linuxdeploy-plugin-gtk/"
            "b5eb8d05b4c0ed40107fe2158c5d8527f94568ef/"
            "linuxdeploy-plugin-gtk.sh"
        ),
        "size": 11_648,
        "sha256": "cb379f9b0733e9ad9f8bd78f8c2fa038aef2478523bb7d4c8e64ff6a1ea3501a",
    },
    {
        "name": "linuxdeploy-plugin-gstreamer.sh",
        "url": (
            "https://raw.githubusercontent.com/tauri-apps/"
            "linuxdeploy-plugin-gstreamer/"
            "2a2e67491c32995a3f279ad0ecbe77abd512b42a/"
            "linuxdeploy-plugin-gstreamer.sh"
        ),
        "size": 4_857,
        "sha256": "c107b49d84edbffc6ab226ed1007e0626a4f7aa2c3a36b7782bef62351d49e94",
    },
    {
        "name": "linuxdeploy-plugin-appimage.AppImage",
        "url": (
            "https://api.github.com/repos/linuxdeploy/"
            "linuxdeploy-plugin-appimage/releases/assets/497460911"
        ),
        "size": 16_484_856,
        "sha256": "a45d3e227bc7f397e9cf6bfa4c9507494efa2293357b6e86690a3de2ca992e79",
    },
)

NSIS_ARCHIVE = {
    "name": "nsis-3.11.zip",
    "url": (
        "https://api.github.com/repos/tauri-apps/binary-releases/"
        "releases/assets/317051073"
    ),
    "size": 2_361_546,
    "sha256": "c7d27f780ddb6cffb4730138cd1591e841f4b7edb155856901cdf5f214394fa1",
}
NSIS_ARCHIVE_ROOT = "nsis-3.11"
NSIS_BASE_FILE_COUNT = 441
NSIS_BASE_DIRECTORY_COUNT = 56
NSIS_BASE_EXPANDED_BYTES = 7_134_287
NSIS_BASE_TREE_SHA256 = (
    "bc20c89980c5fc301b692ae2b16f6c7b07d86fa8aa716787bfa033ee94a1f501"
)
NSIS_PLUGIN = {
    "name": "nsis_tauri_utils.dll",
    "url": (
        "https://api.github.com/repos/tauri-apps/nsis-tauri-utils/"
        "releases/assets/345882097"
    ),
    "size": 34_304,
    "sha256": "5ba143b5db4a87d32d6e7802e033330aae56cbceabe0d1e3ba41948385ad4709",
}

WEBVIEW2_GUID = "e4dd9b83-b7e3-4d17-8d7c-e14cdd7c3a51"
WEBVIEW2_ASSET = {
    "name": "MicrosoftEdgeWebView2RuntimeInstallerX64.exe",
    "url": (
        "https://msedge.sf.dl.delivery.mp.microsoft.com/"
        "filestreamingservice/files/"
        f"{WEBVIEW2_GUID}/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
    ),
    "size": 209_653_456,
    "sha256": "f8d4ab074c22a0cd136434f37c6b34dfb64ebf8a32ce42e03bd8f2a6b51a3892",
}

WINDOWS_RESERVED_NAMES = {
    "AUX",
    "CON",
    "NUL",
    "PRN",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}


class ToolError(RuntimeError):
    """Raised when pinned tool preparation or verification must fail closed."""


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_reparse_point(metadata: os.stat_result) -> bool:
    attributes = getattr(metadata, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attributes & reparse_flag)


def _assert_plain_directory(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ToolError(f"required directory is missing: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode) or _is_reparse_point(metadata):
        raise ToolError(f"directory is a link, reparse point, or special file: {path}")


def _assert_plain_path_components(path: Path) -> None:
    absolute = path.absolute()
    existing: list[Path] = []
    current = absolute
    while True:
        if current.exists() or current.is_symlink():
            existing.append(current)
        if current.parent == current:
            break
        current = current.parent
    for component in reversed(existing):
        _assert_plain_directory(component)


def _assert_plain_regular_file(path: Path) -> os.stat_result:
    try:
        before = path.lstat()
    except FileNotFoundError as error:
        raise ToolError(f"required pinned tool is missing: {path}") from error
    if (
        not stat.S_ISREG(before.st_mode)
        or _is_reparse_point(before)
        or before.st_nlink != 1
    ):
        raise ToolError(
            f"pinned tool is a link, reparse point, hard link, or special file: {path}"
        )
    return before


def hash_regular_file(path: Path, *, expected_size: int | None = None) -> str:
    _assert_plain_regular_file(path)

    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        held = os.fstat(descriptor)
        if (
            not stat.S_ISREG(held.st_mode)
            or _is_reparse_point(held)
            or held.st_nlink != 1
        ):
            raise ToolError(
                f"opened pinned tool is a link, reparse point, hard link, "
                f"or special file: {path}"
            )
        authoritative_size = held.st_size
        if expected_size is not None and authoritative_size != expected_size:
            raise ToolError(
                f"pinned tool size mismatch for {path}: "
                f"expected {expected_size}, got {authoritative_size}"
            )

        def held_digest() -> str:
            os.lseek(descriptor, 0, os.SEEK_SET)
            digest = hashlib.sha256()
            received = 0
            while chunk := os.read(descriptor, DOWNLOAD_CHUNK_BYTES):
                received += len(chunk)
                if received > authoritative_size:
                    raise ToolError(f"pinned tool grew while hashing: {path}")
                digest.update(chunk)
            if received != authoritative_size:
                raise ToolError(f"short read while hashing pinned tool: {path}")
            return digest.hexdigest()

        first_digest = held_digest()
        second_digest = held_digest()
        after = os.fstat(descriptor)
        if (
            not stat.S_ISREG(after.st_mode)
            or _is_reparse_point(after)
            or after.st_nlink != 1
            or after.st_size != authoritative_size
            or second_digest != first_digest
        ):
            raise ToolError(f"pinned tool changed while hashing: {path}")
        return first_digest
    finally:
        os.close(descriptor)


def _check_no_environment_overrides() -> None:
    inherited = [name for name in DANGEROUS_ENVIRONMENT if name in os.environ]
    if inherited:
        raise ToolError(
            "refusing inherited Tauri toolchain overrides: " + ", ".join(inherited)
        )


def _open_exclusive(path: Path, mode: int = 0o600):
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
        mode,
    )
    return os.fdopen(descriptor, "wb")


def download_asset(asset: dict[str, object], destination: Path) -> None:
    url = str(asset["url"])
    expected_size = int(asset["size"])
    expected_sha256 = str(asset["sha256"])
    if not url.startswith("https://"):
        raise ToolError(f"pinned tool URL is not HTTPS: {url}")

    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/octet-stream",
            "Accept-Encoding": "identity",
            "User-Agent": f"ScanStudio-Tauri/{TAURI_VERSION}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    deadline = time.monotonic() + DOWNLOAD_DEADLINE_SECONDS
    with urllib.request.urlopen(request, timeout=45) as response:  # noqa: S310
        final_url = response.geturl()
        if not final_url.startswith("https://"):
            raise ToolError(f"pinned tool download left HTTPS: {final_url}")
        if response.headers.get("Content-Encoding") not in (None, "identity"):
            raise ToolError("compressed HTTP transfer is not allowed")
        length_header = response.headers.get("Content-Length")
        if length_header is None or not length_header.isdecimal():
            raise ToolError("pinned tool download omitted a valid Content-Length")
        declared_size = int(length_header)
        if declared_size != expected_size:
            raise ToolError(
                "pinned tool Content-Length mismatch: "
                f"expected {expected_size}, got {declared_size}"
            )

        digest = hashlib.sha256()
        received = 0
        with _open_exclusive(destination) as output:
            while chunk := response.read(
                min(DOWNLOAD_CHUNK_BYTES, expected_size - received + 1)
            ):
                if time.monotonic() > deadline:
                    raise ToolError("pinned tool download exceeded its total deadline")
                received += len(chunk)
                if received > expected_size:
                    raise ToolError("pinned tool download exceeded its pinned size")
                digest.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if received != expected_size:
            raise ToolError(
                f"pinned tool download was short: expected {expected_size}, got {received}"
            )
        actual_sha256 = digest.hexdigest()
        if actual_sha256 != expected_sha256:
            raise ToolError(
                "pinned tool digest mismatch: "
                f"expected {expected_sha256}, got {actual_sha256}"
            )


def validated_zip_member(name: str, expected_root: str) -> PurePosixPath:
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        raise ToolError(f"unsafe NSIS archive member name: {name!r}")
    raw_parts = name.rstrip("/").split("/")
    if not raw_parts or any(part in ("", ".", "..") for part in raw_parts):
        raise ToolError(f"unsafe NSIS archive member path: {name!r}")
    for part in raw_parts:
        if ":" in part or part.endswith((".", " ")):
            raise ToolError(f"Windows-ambiguous NSIS archive member: {name!r}")
        stem = part.split(".", 1)[0].upper()
        if stem in WINDOWS_RESERVED_NAMES:
            raise ToolError(f"Windows device name in NSIS archive: {name!r}")
    path = PurePosixPath(*raw_parts)
    if len(path.parts) < 2 or path.parts[0] != expected_root:
        raise ToolError(f"NSIS archive member escaped its pinned root: {name!r}")
    return path


def _collision_key(path: PurePosixPath) -> str:
    return unicodedata.normalize("NFC", path.as_posix()).casefold()


def extract_nsis_archive(archive: Path, destination: Path) -> None:
    try:
        destination.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ToolError(f"NSIS destination already exists: {destination}") from error

    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        if len(members) != NSIS_BASE_FILE_COUNT or len(members) > MAX_NSIS_ENTRIES:
            raise ToolError(
                "unexpected NSIS archive entry count: "
                f"expected {NSIS_BASE_FILE_COUNT}, got {len(members)}"
            )
        total = 0
        seen: set[str] = set()
        validated: list[tuple[zipfile.ZipInfo, PurePosixPath]] = []
        for member in members:
            path = validated_zip_member(member.filename, NSIS_ARCHIVE_ROOT)
            key = _collision_key(path)
            if key in seen:
                raise ToolError(
                    f"duplicate or case-colliding NSIS archive member: {member.filename!r}"
                )
            seen.add(key)
            if member.is_dir() or member.flag_bits & 0x1:
                raise ToolError(f"unsupported NSIS archive member: {member.filename!r}")
            mode = member.external_attr >> 16
            file_type = stat.S_IFMT(mode)
            if stat.S_ISLNK(mode) or file_type not in (0, stat.S_IFREG):
                raise ToolError(
                    f"NSIS archive contains a link or special file: {member.filename!r}"
                )
            total += member.file_size
            if member.file_size < 0 or total > MAX_NSIS_EXPANDED_BYTES:
                raise ToolError("NSIS archive expanded size exceeds its bound")
            validated.append((member, path))
        if total != NSIS_BASE_EXPANDED_BYTES:
            raise ToolError(
                "NSIS archive expanded size mismatch: "
                f"expected {NSIS_BASE_EXPANDED_BYTES}, got {total}"
            )

        for member, path in validated:
            relative = Path(*path.parts[1:])
            output_path = destination / relative
            output_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            copied = 0
            with (
                bundle.open(member, "r") as source,
                _open_exclusive(output_path) as output,
            ):
                while chunk := source.read(DOWNLOAD_CHUNK_BYTES):
                    copied += len(chunk)
                    if copied > member.file_size:
                        raise ToolError(
                            f"NSIS member exceeded declared size: {member.filename!r}"
                        )
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            if copied != member.file_size:
                raise ToolError(f"short NSIS archive member: {member.filename!r}")


def _tree_commit(
    root: Path, *, excluded_directories: frozenset[str] = frozenset()
) -> tuple[str, int, int, int]:
    _assert_plain_directory(root)
    records: list[str] = []
    file_count = 0
    directory_count = 0
    total_bytes = 0
    seen: set[str] = set()

    def visit(directory: Path, relative_directory: PurePosixPath) -> None:
        nonlocal file_count, directory_count, total_bytes
        with os.scandir(directory) as scanner:
            entries = sorted(scanner, key=lambda item: item.name)
        for entry in entries:
            relative = relative_directory / entry.name
            relative_text = relative.as_posix()
            key = unicodedata.normalize("NFC", relative_text).casefold()
            if key in seen:
                raise ToolError(
                    f"case-colliding path in pinned tool tree: {relative_text}"
                )
            seen.add(key)
            metadata = entry.stat(follow_symlinks=False)
            if _is_reparse_point(metadata) or stat.S_ISLNK(metadata.st_mode):
                raise ToolError(
                    f"link or reparse point in pinned tool tree: {relative_text}"
                )
            if stat.S_ISDIR(metadata.st_mode):
                if relative_text in excluded_directories:
                    continue
                directory_count += 1
                records.append(f"D\0{relative_text}\n")
                visit(Path(entry.path), relative)
            elif stat.S_ISREG(metadata.st_mode):
                digest = hash_regular_file(
                    Path(entry.path), expected_size=metadata.st_size
                )
                file_count += 1
                total_bytes += metadata.st_size
                records.append(f"F\0{relative_text}\0{metadata.st_size}\0{digest}\n")
            else:
                raise ToolError(f"special file in pinned tool tree: {relative_text}")

    visit(root, PurePosixPath())
    payload = "".join(sorted(records)).encode("utf-8")
    return sha256_bytes(payload), file_count, directory_count, total_bytes


def _exact_entries(directory: Path, *, directories: set[str], files: set[str]) -> None:
    _assert_plain_directory(directory)
    actual_directories: set[str] = set()
    actual_files: set[str] = set()
    collision_keys: set[str] = set()
    with os.scandir(directory) as scanner:
        entries = list(scanner)
    for entry in entries:
        key = unicodedata.normalize("NFC", entry.name).casefold()
        if key in collision_keys:
            raise ToolError(
                f"case-colliding entry in pinned tool directory: {entry.path}"
            )
        collision_keys.add(key)
        metadata = entry.stat(follow_symlinks=False)
        if _is_reparse_point(metadata) or stat.S_ISLNK(metadata.st_mode):
            raise ToolError(
                f"link or reparse point in pinned tool directory: {entry.path}"
            )
        if stat.S_ISDIR(metadata.st_mode):
            actual_directories.add(entry.name)
        elif stat.S_ISREG(metadata.st_mode):
            actual_files.add(entry.name)
        else:
            raise ToolError(f"special entry in pinned tool directory: {entry.path}")
    if actual_directories != directories or actual_files != files:
        raise ToolError(
            f"unexpected pinned tool directory contents at {directory}: "
            f"directories={sorted(actual_directories)}, files={sorted(actual_files)}"
        )


def _assert_asset(path: Path, asset: dict[str, object], *, installed: bool) -> str:
    expected_sha256 = str(
        asset.get("installed_sha256", asset["sha256"]) if installed else asset["sha256"]
    )
    actual_sha256 = hash_regular_file(path, expected_size=int(asset["size"]))
    if actual_sha256 != expected_sha256:
        raise ToolError(
            f"pinned tool digest mismatch for {path}: "
            f"expected {expected_sha256}, got {actual_sha256}"
        )
    return actual_sha256


def verify_linux(tools_root: Path) -> None:
    expected_names = {str(asset["name"]) for asset in LINUX_ASSETS}
    _exact_entries(tools_root, directories=set(), files=expected_names)
    for asset in LINUX_ASSETS:
        path = tools_root / str(asset["name"])
        _assert_asset(path, asset, installed=True)
        if os.name != "nt" and stat.S_IMODE(path.stat().st_mode) != 0o700:
            raise ToolError(f"pinned Linux tool mode is not exactly 0700: {path}")


def _verify_nsis_base(nsis_root: Path) -> None:
    tree_sha256, files, directories, total_bytes = _tree_commit(
        nsis_root,
        excluded_directories=frozenset({"Plugins/x86-unicode/additional"}),
    )
    actual = (tree_sha256, files, directories, total_bytes)
    expected = (
        NSIS_BASE_TREE_SHA256,
        NSIS_BASE_FILE_COUNT,
        NSIS_BASE_DIRECTORY_COUNT,
        NSIS_BASE_EXPANDED_BYTES,
    )
    if actual != expected:
        raise ToolError(
            f"NSIS 3.11 full-tree manifest mismatch: expected {expected}, got {actual}"
        )


def verify_windows(tools_root: Path) -> None:
    nsis_root = tools_root / "NSIS"
    architecture_root = tools_root / "x64"
    guid_root = architecture_root / WEBVIEW2_GUID
    plugin_root = nsis_root / "Plugins" / "x86-unicode" / "additional"

    _exact_entries(tools_root, directories={"NSIS", "x64"}, files=set())
    _exact_entries(architecture_root, directories={WEBVIEW2_GUID}, files=set())
    _exact_entries(guid_root, directories=set(), files={str(WEBVIEW2_ASSET["name"])})
    _exact_entries(plugin_root, directories=set(), files={str(NSIS_PLUGIN["name"])})
    _verify_nsis_base(nsis_root)
    _assert_asset(plugin_root / str(NSIS_PLUGIN["name"]), NSIS_PLUGIN, installed=True)
    _assert_asset(
        guid_root / str(WEBVIEW2_ASSET["name"]), WEBVIEW2_ASSET, installed=True
    )


def _create_tools_root(target_directory: Path) -> Path:
    _assert_plain_path_components(target_directory.parent)
    if target_directory.exists() or target_directory.is_symlink():
        _assert_plain_directory(target_directory)
    else:
        target_directory.mkdir(mode=0o700)
    tools_root = target_directory / ".tauri"
    try:
        tools_root.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ToolError(
            f"refusing pre-existing Tauri tool cache: {tools_root}"
        ) from error
    return tools_root


def prepare_linux(tools_root: Path) -> None:
    for asset in LINUX_ASSETS:
        path = tools_root / str(asset["name"])
        download_asset(asset, path)
        before = _assert_plain_regular_file(path)
        _assert_asset(path, asset, installed=False)
        flags = os.O_RDWR | getattr(os, "O_BINARY", 0)
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            held = os.fstat(descriptor)
            if (held.st_dev, held.st_ino) != (before.st_dev, before.st_ino):
                raise ToolError(f"Linux tool changed before finalization: {path}")
            if "zero_range" in asset:
                start, end = asset["zero_range"]  # type: ignore[misc]
                start = int(start)
                end = int(end)
                if start < 0 or end <= start or end > held.st_size:
                    raise ToolError(f"invalid pinned Linux tool patch range: {path}")
                os.lseek(descriptor, start, os.SEEK_SET)
                if os.write(descriptor, b"\0" * (end - start)) != end - start:
                    raise ToolError(f"short pinned Linux tool patch write: {path}")
            os.fchmod(descriptor, 0o700)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        _assert_asset(path, asset, installed=True)
    verify_linux(tools_root)


def prepare_windows(tools_root: Path) -> None:
    archive = tools_root / "_nsis-3.11.zip"
    download_asset(NSIS_ARCHIVE, archive)
    _assert_asset(archive, NSIS_ARCHIVE, installed=False)
    nsis_root = tools_root / "NSIS"
    extract_nsis_archive(archive, nsis_root)
    _verify_nsis_base(nsis_root)
    archive.unlink()

    plugin_root = nsis_root / "Plugins" / "x86-unicode" / "additional"
    plugin_root.mkdir(mode=0o700)
    plugin = plugin_root / str(NSIS_PLUGIN["name"])
    download_asset(NSIS_PLUGIN, plugin)

    guid_root = tools_root / "x64" / WEBVIEW2_GUID
    guid_root.mkdir(mode=0o700, parents=True)
    webview = guid_root / str(WEBVIEW2_ASSET["name"])
    download_asset(WEBVIEW2_ASSET, webview)
    verify_windows(tools_root)


def prepare(platform_name: str, target_directory: Path) -> Path:
    _check_no_environment_overrides()
    tools_root = _create_tools_root(target_directory.absolute())
    if platform_name == "linux":
        prepare_linux(tools_root)
    elif platform_name == "windows":
        prepare_windows(tools_root)
    else:  # pragma: no cover - argparse owns this boundary
        raise ToolError(f"unsupported Tauri tool platform: {platform_name}")
    return tools_root


def verify(platform_name: str, target_directory: Path) -> Path:
    _check_no_environment_overrides()
    target_directory = target_directory.absolute()
    _assert_plain_path_components(target_directory)
    tools_root = target_directory / ".tauri"
    if platform_name == "linux":
        verify_linux(tools_root)
    elif platform_name == "windows":
        verify_windows(tools_root)
    else:  # pragma: no cover - argparse owns this boundary
        raise ToolError(f"unsupported Tauri tool platform: {platform_name}")
    return tools_root


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "verify"))
    parser.add_argument("platform", choices=("linux", "windows"))
    parser.add_argument(
        "--target-directory",
        required=True,
        type=Path,
        help="the exact Cargo target directory that will contain .tauri",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.operation == "prepare":
            tools_root = prepare(args.platform, args.target_directory)
        else:
            tools_root = verify(args.platform, args.target_directory)
    except (OSError, ToolError, zipfile.BadZipFile) as error:
        print(f"pinned Tauri tool verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Tauri {TAURI_VERSION} {args.platform} external tools "
        f"{args.operation} verified at {tools_root}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
