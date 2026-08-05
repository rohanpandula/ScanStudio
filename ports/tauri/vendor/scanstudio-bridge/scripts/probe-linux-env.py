#!/usr/bin/env python3
"""BRDG-06 read-only Linux environment probe for the ScanStudio bridge.

Checks the host for everything the bridge's Linux lane needs before any
scan is attempted:

  1. sane-backends installed (sane-config --version or pkg-config sane-backends)
  2. scanimage available (sane-utils)
  3. libusb-1.0 visible to the dynamic linker
  4. the LS-5000 (USB ID 04b0:4002) visible on the bus via lsusb
  5. a coolscan/sane udev rule installed
  6. the current user in the `scanner` group (USB permission heuristic)

Prints one `[OK]`/`[FAIL]` line per check, with a copy-paste fix command
under every FAIL that has one. This script NEVER executes any fix it
suggests -- fix strings are display-only; a human decides whether to run
them. Read-only: no system state is modified.
"""

from __future__ import annotations

import ctypes.util
import glob
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass

try:
    import grp
except ImportError:  # non-POSIX host
    grp = None

_SUBPROCESS_TIMEOUT_SECONDS = 5

_LS5000_USB_ID = "04b0:4002"

_UDEV_RULE_GLOBS = (
    "/etc/udev/rules.d/*coolscan*",
    "/etc/udev/rules.d/*sane*",
    "/lib/udev/rules.d/*sane*",
    "/usr/lib/udev/rules.d/*sane*",
)


@dataclass
class CheckResult:
    name: str
    ok: bool
    detail: str
    fix: str | None = None


def check_sane_backends() -> CheckResult:
    name = "sane-backends"
    fix = "sudo apt install sane-utils libsane1 libusb-1.0-0"
    probes = (
        ("sane-config", ["--version"]),
        ("pkg-config", ["--exists", "sane-backends"]),
    )
    for tool, args in probes:
        path = shutil.which(tool)
        if path is None:
            continue
        try:
            result = subprocess.run(
                [path, *args],
                timeout=_SUBPROCESS_TIMEOUT_SECONDS,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0:
            return CheckResult(name, True, f"{tool} reports sane-backends present")
    return CheckResult(
        name,
        False,
        "no sane-backends installation found (sane-config/pkg-config missing or negative)",
        fix,
    )


def check_scanimage() -> CheckResult:
    name = "scanimage"
    fix = "sudo apt install sane-utils"
    path = shutil.which("scanimage")
    if path is None:
        return CheckResult(name, False, "scanimage not found on PATH", fix)
    try:
        result = subprocess.run(
            [path, "-V"],
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return CheckResult(
            name, False, f"scanimage found at {path} but failed to run ({exc})", fix
        )
    if result.returncode != 0:
        return CheckResult(
            name,
            False,
            f"scanimage found at {path} but exited with status "
            f"{result.returncode}: {result.stderr.strip()}",
            fix,
        )
    return CheckResult(name, True, f"scanimage found at {path}")


def check_libusb() -> CheckResult:
    name = "libusb"
    fix = "sudo apt install libusb-1.0-0"
    library = ctypes.util.find_library("usb-1.0")
    if library:
        return CheckResult(name, True, f"libusb-1.0 found: {library}")
    return CheckResult(
        name, False, "libusb-1.0 not found by the dynamic linker", fix
    )


def check_lsusb_device() -> CheckResult:
    name = "lsusb-device"
    connect_fix = "connect the LS-5000 via USB, then re-run this probe"
    path = shutil.which("lsusb")
    if path is None:
        return CheckResult(
            name, False, "lsusb not found on PATH", "sudo apt install usbutils"
        )
    try:
        result = subprocess.run(
            [path],
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return CheckResult(name, False, f"lsusb failed to run ({exc})", connect_fix)
    if result.returncode == 0 and _LS5000_USB_ID in result.stdout.lower():
        return CheckResult(
            name, True, f"LS-5000 ({_LS5000_USB_ID}) visible on the USB bus"
        )
    return CheckResult(
        name,
        False,
        f"no {_LS5000_USB_ID} (LS-5000) in lsusb output",
        connect_fix,
    )


def check_udev_rules() -> CheckResult:
    name = "udev-rules"
    fix = "sudo apt install libsane-dev  # reinstalling typically restores the shipped udev rules"
    for pattern in _UDEV_RULE_GLOBS:
        matches = glob.glob(pattern)
        if matches:
            return CheckResult(name, True, f"udev rule present: {matches[0]}")
    return CheckResult(name, False, "no coolscan/sane udev rules found", fix)


def check_usb_permission() -> CheckResult:
    name = "usb-permission"
    fix = "sudo usermod -aG scanner $USER   # then log out and back in for it to take effect"
    if grp is None:
        return CheckResult(
            name,
            False,
            "grp module unavailable (non-POSIX host); run this probe on the Linux machine",
            None,
        )
    try:
        scanner_gid = grp.getgrnam("scanner").gr_gid
    except KeyError:
        return CheckResult(name, False, "no 'scanner' group on this system", fix)
    if scanner_gid in os.getgroups():
        return CheckResult(
            name, True, f"current user is in the scanner group (gid {scanner_gid})"
        )
    return CheckResult(name, False, "current user is not in the scanner group", fix)


ALL_CHECKS = (
    check_sane_backends,
    check_scanimage,
    check_libusb,
    check_lsusb_device,
    check_udev_rules,
    check_usb_permission,
)


def main() -> int:
    failed = False
    for check in ALL_CHECKS:
        result = check()
        status = "OK" if result.ok else "FAIL"
        print(f"[{status}] {result.name}: {result.detail}")
        if not result.ok:
            failed = True
            if result.fix:
                print(f"    fix: {result.fix}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
