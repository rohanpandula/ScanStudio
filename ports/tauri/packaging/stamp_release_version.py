#!/usr/bin/env python3
"""Stamp an exact release version into the Tauri app's version-bearing files.

Shared by linux/build-and-verify.sh and windows/build-and-verify.ps1 so both
packaging lanes stamp identically before assembling or building, instead of
each lane maintaining its own copy of the same regex contract (the Windows
copy drifted out of the pre-assembly path once before: PR #85 added this
stamp only to windows/build-and-verify.ps1, which runs in a LATER job on a
fresh checkout, after windows-resources/assemble-staging.sh had already
byte-copied the still-placeholder Cargo.lock and package-lock.json into the
staged Licenses/ tree from an earlier, unstamped checkout).

tauri::generate_context!() embeds tauri.conf.json's "version" at `cargo
build` time -- that's what @tauri-apps/api's getVersion() returns and what
every shipped bundle resolves as its own displayed version -- so the
checked-in files must say the real release version before any build or
resource-assembly step runs, not after. Cargo.toml and package.json are
stamped too so `cargo metadata`, the cargo-about notice generator, and npm
tooling agree with the shipped binary instead of showing the frozen
placeholder "0.3.0". Cargo.lock is stamped because --locked (the
supply-chain gate the pinned toolchain work added) refuses to silently
regenerate a lockfile that has drifted from Cargo.toml, so the stamp must
apply there too or cargo/rustc refuse to run at all before any build step.

Fail-closed: each pattern must match its file exactly once, or this exits
non-zero without writing anything for that file. Stamping an already-stamped
file with the same version is idempotent -- the pattern still matches
exactly once (the field is a single "key": "value" occurrence regardless of
its current value), and rewriting it with the same version is a byte-for-byte
no-op.
"""

from __future__ import annotations

import re
import sys

# Matches tauri.conf.json's and package.json's top-level "version" field.
JSON_VERSION_PATTERN = r'"version":\s*"([^"]*)"'
# Matches Cargo.toml's own [package] version = "..." line.
CARGO_TOML_VERSION_PATTERN = r'(?m)^version = "([^"]*)"'
# Cargo.lock records this workspace member's own version in its [[package]]
# block. CRLF-tolerant (\r?\n) because a checkout that produces this file is
# not guaranteed to be LF-only (e.g. a Windows runner's git core.autocrlf).
CARGO_LOCK_APP_VERSION_PATTERN = (
    r'(?m)^name = "scanstudio-app"\r?\nversion = "([^"]*)"'
)


class StampError(RuntimeError):
    """A version field did not match its file exactly once."""


def stamp(path: str, pattern: str, version: str) -> None:
    # newline="" disables Python's universal-newline translation on both
    # read and write. Without it, text-mode I/O silently normalizes line
    # endings to "\n" on read and re-expands "\n" to the RUNNING PLATFORM's
    # os.linesep on write -- so behavior would depend on which OS happens to
    # execute this script rather than on the file's own actual bytes. This
    # script runs from a Linux job (linux/build-and-verify.sh) and, via
    # `python`, from a Windows job (windows/build-and-verify.ps1) whose
    # checkout has CRLF line endings (no .gitattributes forces LF in this
    # repo). newline="" makes the stamp byte-for-byte outside the matched
    # span on every platform, matching what the PowerShell implementation
    # this replaces already did (Get-Content -Raw / Set-Content -NoNewline
    # perform no EOL translation either).
    with open(path, "r", encoding="utf-8", newline="") as handle:
        content = handle.read()
    found = list(re.finditer(pattern, content, flags=re.MULTILINE))
    if len(found) != 1:
        raise StampError(
            f"expected exactly one version field in {path}, found {len(found)}"
        )
    start, end = found[0].span(1)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(content[:start] + version + content[end:])


def stamp_release_version(
    tauri_conf_path: str,
    package_json_path: str,
    cargo_toml_path: str,
    cargo_lock_path: str,
    version: str,
) -> None:
    stamp(tauri_conf_path, JSON_VERSION_PATTERN, version)
    stamp(package_json_path, JSON_VERSION_PATTERN, version)
    stamp(cargo_toml_path, CARGO_TOML_VERSION_PATTERN, version)
    stamp(cargo_lock_path, CARGO_LOCK_APP_VERSION_PATTERN, version)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 5:
        print(
            "usage: stamp_release_version.py <tauri.conf.json> <package.json> "
            "<Cargo.toml> <Cargo.lock> <version>",
            file=sys.stderr,
        )
        return 64
    tauri_conf_path, package_json_path, cargo_toml_path, cargo_lock_path, version = argv
    try:
        stamp_release_version(
            tauri_conf_path,
            package_json_path,
            cargo_toml_path,
            cargo_lock_path,
            version,
        )
    except (StampError, OSError) as error:
        print(f"stamp_release_version failed: {error}", file=sys.stderr)
        return 1
    print(f"stamped release version {version} into 4 files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
