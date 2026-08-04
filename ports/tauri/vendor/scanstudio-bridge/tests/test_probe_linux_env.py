"""Stubbed unit tests for scripts/probe-linux-env.py (BRDG-06).

Every check function is tested in isolation with its primitives
(shutil.which, subprocess.run, ctypes.util.find_library, glob.glob,
grp.getgrnam, os.getgroups) monkeypatched -- no real filesystem, no real
system state, no hardware. The script's filename contains a hyphen, so it
is loaded via importlib.util rather than a plain import.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "probe-linux-env.py"
_spec = importlib.util.spec_from_file_location("probe_linux_env", _SCRIPT_PATH)
assert _spec is not None and _spec.loader is not None
probe = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = probe
_spec.loader.exec_module(probe)


class _Completed:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


# -- check_sane_backends -------------------------------------------------------


def test_check_sane_backends_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.shutil, "which", lambda _name: "/usr/bin/sane-config")
    monkeypatch.setattr(
        probe.subprocess, "run", lambda _cmd, **_kwargs: _Completed(0)
    )
    result = probe.check_sane_backends()
    assert result.ok is True
    assert result.name == "sane-backends"


def test_check_sane_backends_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.shutil, "which", lambda _name: None)
    result = probe.check_sane_backends()
    assert result.ok is False
    assert result.fix == "sudo apt install sane-utils libsane1 libusb-1.0-0"


# -- check_scanimage -----------------------------------------------------------


def test_check_scanimage_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.shutil, "which", lambda _name: "/usr/bin/scanimage")
    monkeypatch.setattr(
        probe.subprocess, "run", lambda _cmd, **_kwargs: _Completed(0)
    )
    result = probe.check_scanimage()
    assert result.ok is True


def test_check_scanimage_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.shutil, "which", lambda _name: None)
    result = probe.check_scanimage()
    assert result.ok is False
    assert result.fix == "sudo apt install sane-utils"


# -- check_libusb --------------------------------------------------------------


def test_check_libusb_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        probe.ctypes.util, "find_library", lambda _name: "libusb-1.0.so.0"
    )
    result = probe.check_libusb()
    assert result.ok is True


def test_check_libusb_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.ctypes.util, "find_library", lambda _name: None)
    result = probe.check_libusb()
    assert result.ok is False
    assert result.fix == "sudo apt install libusb-1.0-0"


# -- check_lsusb_device ----------------------------------------------------------


def test_check_lsusb_device_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.shutil, "which", lambda _name: "/usr/bin/lsusb")
    monkeypatch.setattr(
        probe.subprocess,
        "run",
        lambda _cmd, **_kwargs: _Completed(
            0, stdout="Bus 001 Device 005: ID 04b0:4002 Nikon Corp. CoolScan LS-5000\n"
        ),
    )
    result = probe.check_lsusb_device()
    assert result.ok is True


def test_check_lsusb_device_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.shutil, "which", lambda _name: "/usr/bin/lsusb")
    monkeypatch.setattr(
        probe.subprocess,
        "run",
        lambda _cmd, **_kwargs: _Completed(
            0, stdout="Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub\n"
        ),
    )
    result = probe.check_lsusb_device()
    assert result.ok is False
    assert result.fix == "connect the LS-5000 via USB, then re-run this probe"


# -- check_udev_rules --------------------------------------------------------------


def test_check_udev_rules_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        probe.glob, "glob", lambda _pattern: ["/etc/udev/rules.d/99-coolscan.rules"]
    )
    result = probe.check_udev_rules()
    assert result.ok is True


def test_check_udev_rules_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.glob, "glob", lambda _pattern: [])
    result = probe.check_udev_rules()
    assert result.ok is False
    assert result.fix is not None
    assert "libsane-dev" in result.fix


# -- check_usb_permission --------------------------------------------------------


class _FakeGroup:
    def __init__(self, gr_gid: int) -> None:
        self.gr_gid = gr_gid


def test_check_usb_permission_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe.grp, "getgrnam", lambda _name: _FakeGroup(7))
    monkeypatch.setattr(probe.os, "getgroups", lambda: [5, 7, 20])
    result = probe.check_usb_permission()
    assert result.ok is True


def test_check_usb_permission_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    def _no_such_group(_name: str):
        raise KeyError("scanner")

    monkeypatch.setattr(probe.grp, "getgrnam", _no_such_group)
    result = probe.check_usb_permission()
    assert result.ok is False
    assert result.fix is not None
    assert "usermod -aG scanner" in result.fix


# -- main() aggregation -----------------------------------------------------------


def test_main_prints_one_line_per_check_and_returns_nonzero_on_any_failure(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        probe,
        "ALL_CHECKS",
        (
            lambda: probe.CheckResult("ok-check", True, "all good"),
            lambda: probe.CheckResult(
                "bad-check", False, "something is missing", fix="run the fix command"
            ),
        ),
    )
    return_code = probe.main()
    out = capsys.readouterr().out
    assert "[OK] ok-check: all good" in out
    assert "[FAIL] bad-check: something is missing" in out
    assert "fix: run the fix command" in out
    assert return_code == 1
