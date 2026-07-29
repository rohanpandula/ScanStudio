from __future__ import annotations

import sys
from pathlib import Path

import pytest

from coolscanpy.protocol.ls5000_single_pass import usb_backend


def test_frozen_bundle_resolver_uses_only_app_owned_binary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    frameworks = tmp_path / "NegPy.app" / "Contents" / "Frameworks"
    executable = tmp_path / "NegPy.app" / "Contents" / "MacOS" / "NegPy"
    frameworks.mkdir(parents=True)
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"app")
    library = frameworks / "coolscanpy" / "_native" / "libusb-1.0.dylib"
    library.parent.mkdir(parents=True)
    library.write_bytes(b"libusb")

    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)

    assert usb_backend.bundled_libusb_path() == library.resolve()


def test_frozen_bundle_resolver_refuses_missing_binary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable = tmp_path / "NegPy.app" / "Contents" / "MacOS" / "NegPy"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"app")

    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)

    with pytest.raises(usb_backend.LibusbBackendUnavailable, match="does not contain"):
        usb_backend.bundled_libusb_path()


def test_source_backend_uses_pyusb_host_lookup(monkeypatch: pytest.MonkeyPatch) -> None:
    sentinel = object()
    calls: list[object] = []
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(
        "usb.backend.libusb1.get_backend",
        lambda find_library=None: calls.append(find_library) or sentinel,
    )

    assert usb_backend.get_libusb_backend() is sentinel
    assert calls == [None]
