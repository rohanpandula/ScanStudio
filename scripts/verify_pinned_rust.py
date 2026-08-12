#!/usr/bin/env python3
"""Verify the exact rustup-managed Rust toolchain used by CI and releases."""

from __future__ import annotations

from pathlib import Path
import platform
import subprocess
import sys

VERSION = "1.97.1"
RUSTC_COMMIT = "8bab26f4f68e0e26f0bb7960be334d5b520ea452"
CARGO_COMMIT = "c980f4866141969fab6254a680546a277789d6f0"

HOSTS = {
    ("Darwin", "arm64"): "aarch64-apple-darwin",
    ("Darwin", "x86_64"): "x86_64-apple-darwin",
    ("Linux", "x86_64"): "x86_64-unknown-linux-gnu",
    ("Windows", "AMD64"): "x86_64-pc-windows-msvc",
}


def output(*command: str) -> str:
    return subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    ).stdout.strip()


def parse_verbose(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.splitlines()[1:]:
        if ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    return fields


def main() -> int:
    expected_host = HOSTS.get((platform.system(), platform.machine()))
    if expected_host is None:
        print("Unsupported Rust build host", file=sys.stderr)
        return 1

    rustc = parse_verbose(output("rustc", "-Vv"))
    cargo = parse_verbose(output("cargo", "-Vv"))
    expected = {
        "rustc": (rustc, RUSTC_COMMIT),
        "cargo": (cargo, CARGO_COMMIT),
    }
    for name, (fields, commit) in expected.items():
        if fields.get("release") != VERSION:
            raise RuntimeError(f"unexpected {name} release: {fields.get('release')!r}")
        if fields.get("commit-hash") != commit:
            raise RuntimeError(
                f"unexpected {name} commit: {fields.get('commit-hash')!r}"
            )
        if fields.get("host") != expected_host:
            raise RuntimeError(f"unexpected {name} host: {fields.get('host')!r}")

    active = output("rustup", "show", "active-toolchain").split()[0]
    expected_active = f"{VERSION}-{expected_host}"
    if active != expected_active:
        raise RuntimeError(f"unexpected active Rust toolchain: {active!r}")
    rustc_path = Path(
        output("rustup", "which", "--toolchain", expected_active, "rustc")
    ).resolve()
    cargo_path = Path(
        output("rustup", "which", "--toolchain", expected_active, "cargo")
    ).resolve()
    expected_component = f"toolchains/{expected_active}/bin"
    for name, path in (("rustc", rustc_path), ("cargo", cargo_path)):
        if expected_component not in path.as_posix():
            raise RuntimeError(f"{name} escaped the exact rustup toolchain: {path}")

    print(
        f"Pinned Rust verified: toolchain={expected_active} "
        f"rustc={RUSTC_COMMIT} cargo={CARGO_COMMIT}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
