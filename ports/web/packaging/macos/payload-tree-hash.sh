#!/usr/bin/env bash
# Compute the exact cache-compatible tree summary. Directory link counts are
# intentionally not constrained: ordinary macOS directories commonly have
# link counts greater than one. Regular files must have exactly one link.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: payload-tree-hash.sh <ScanStudioWebRuntime.bundle>\n' >&2
    exit 64
fi

root="$1"
if [[ ! -d "$root" || -L "$root" || "$(basename "$root")" != 'ScanStudioWebRuntime.bundle' ]]; then
    printf 'Runtime payload root is missing, linked, or misnamed.\n' >&2
    exit 66
fi

python3 -I -S - "$root" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys

input_root = Path(sys.argv[1])
try:
    root_info = os.lstat(input_root)
except OSError:
    raise SystemExit("cannot inspect runtime payload root") from None
if (
    not stat.S_ISDIR(root_info.st_mode)
    or root_info.st_mode & 0o022
    or root_info.st_mode & 0o500 != 0o500
):
    raise SystemExit("unsafe runtime payload root")
try:
    root = input_root.resolve(strict=True)
except OSError:
    raise SystemExit("cannot resolve runtime payload root") from None
entries: list[tuple[int, bytes, int, int, bytes]] = []
file_count = 0
installed_size = 0
maximum_files = 100_000
maximum_installed_size = 8 * 1024 * 1024 * 1024

def relative_name(path: Path) -> str:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError:
        return path.name or "."
    return relative or "."


def fail_walk(error: OSError) -> None:
    path = Path(error.filename) if error.filename else root
    raise SystemExit(f"cannot read runtime directory: {relative_name(path)}") from None


for current, directory_names, file_names in os.walk(
    root,
    topdown=True,
    onerror=fail_walk,
    followlinks=False,
):
    current_path = Path(current)
    directory_names.sort()
    file_names.sort()
    for name in directory_names:
        path = current_path / name
        try:
            info = os.lstat(path)
        except OSError:
            raise SystemExit(
                f"cannot inspect runtime directory: {relative_name(path)}"
            ) from None
        # POSIX directory link counts reflect topology and are normally >= 2.
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_mode & 0o022
            or info.st_mode & 0o500 != 0o500
        ):
            raise SystemExit(
                f"unsafe runtime directory: {relative_name(path)}"
            )
        relative = path.relative_to(root).as_posix().encode()
        entries.append((0x44, relative, stat.S_IMODE(info.st_mode), 0, b""))
        if len(entries) > 100_000:
            raise SystemExit("runtime payload contains too many tree entries")
    for name in file_names:
        path = current_path / name
        try:
            info = os.lstat(path)
        except OSError:
            raise SystemExit(
                f"cannot inspect runtime file: {relative_name(path)}"
            ) from None
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_mode & 0o022
            or not info.st_mode & 0o400
        ):
            raise SystemExit(f"unsafe runtime file: {relative_name(path)}")
        digest = hashlib.sha256()
        try:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        except OSError:
            raise SystemExit(
                f"cannot read runtime file: {relative_name(path)}"
            ) from None
        relative = path.relative_to(root).as_posix().encode()
        entries.append((0x46, relative, stat.S_IMODE(info.st_mode), info.st_size, digest.digest()))
        file_count += 1
        installed_size += info.st_size
        if file_count > maximum_files or installed_size > maximum_installed_size:
            raise SystemExit("runtime payload exceeds the host cache limits")
        if len(entries) > 100_000:
            raise SystemExit("runtime payload contains too many tree entries")

if file_count <= 0 or installed_size <= 0:
    raise SystemExit("runtime payload tree is empty")
if len(entries) > min(100_000, file_count * 4 + 128):
    raise SystemExit("runtime payload directory/file ratio exceeds the host cache limit")
entries.sort(key=lambda item: item[1])
tree = hashlib.sha256()
tree.update(b"ScanStudioWebRuntimeTreeV1\0")
for kind, path, permissions, size, content_digest in entries:
    tree.update(bytes([kind]))
    tree.update(struct.pack(">I", len(path)))
    tree.update(path)
    tree.update(struct.pack(">H", permissions))
    tree.update(struct.pack(">Q", size))
    tree.update(content_digest)

print(json.dumps({
    "fileCount": file_count,
    "installedSize": installed_size,
    "treeSHA256": tree.hexdigest(),
}, sort_keys=True, separators=(",", ":")))
PY
