from __future__ import annotations

import ctypes.util
import sys
from pathlib import Path

import pytest

from coolscanpy.protocol.ls5000_single_pass import usb_backend


def _scanstudio_runtime(
    tmp_path: Path,
) -> tuple[Path, Path, Path]:
    contents = tmp_path / "ScanStudio.app" / "Contents"
    executable = (
        contents
        / "Resources"
        / "BridgeRuntime"
        / "python"
        / "bin"
        / "python3.13"
    )
    module = (
        contents
        / "Resources"
        / "CorrespondingSource"
        / "coolscanpy"
        / "src"
        / "coolscanpy"
        / "protocol"
        / "ls5000_single_pass"
        / "usb_backend.py"
    )
    library = (
        contents
        / "Frameworks"
        / "coolscanpy"
        / "_native"
        / "libusb-1.0.dylib"
    )
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"python")
    module.parent.mkdir(parents=True)
    module.write_bytes(b"module")
    return executable, module, library


def test_scanstudio_runtime_resolver_uses_only_app_owned_binary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable, module, library = _scanstudio_runtime(tmp_path)
    library.parent.mkdir(parents=True)
    library.write_bytes(b"libusb")

    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.setattr(usb_backend, "__file__", str(module))

    assert usb_backend.bundled_libusb_path() == library.resolve()


def test_scanstudio_runtime_resolver_refuses_missing_binary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable, module, _library = _scanstudio_runtime(tmp_path)

    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.setattr(usb_backend, "__file__", str(module))

    with pytest.raises(usb_backend.LibusbBackendUnavailable, match="does not contain"):
        usb_backend.get_libusb_backend()


def test_scanstudio_runtime_resolver_refuses_symlinked_binary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable, module, library = _scanstudio_runtime(tmp_path)
    outside_library = tmp_path / "host-libusb.dylib"
    outside_library.write_bytes(b"host libusb")
    library.parent.mkdir(parents=True)
    library.symlink_to(outside_library)

    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.setattr(usb_backend, "__file__", str(module))

    with pytest.raises(usb_backend.LibusbBackendUnavailable, match="does not contain"):
        usb_backend.get_libusb_backend()


def test_scanstudio_runtime_resolver_refuses_symlinked_parent_escape(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable, module, library = _scanstudio_runtime(tmp_path)
    outside_native = tmp_path / "host-native"
    outside_native.mkdir()
    (outside_native / library.name).write_bytes(b"host libusb")
    library.parent.parent.mkdir(parents=True)
    library.parent.symlink_to(outside_native, target_is_directory=True)

    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.setattr(usb_backend, "__file__", str(module))

    with pytest.raises(usb_backend.LibusbBackendUnavailable, match="does not contain"):
        usb_backend.get_libusb_backend()


def test_scanstudio_runtime_backend_passes_exact_bundled_path_to_pyusb(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executable, module, library = _scanstudio_runtime(tmp_path)
    library.parent.mkdir(parents=True)
    library.write_bytes(b"libusb")
    sentinel = object()
    callbacks: list[object] = []

    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.setattr(usb_backend, "__file__", str(module))
    monkeypatch.setattr(
        "usb.backend.libusb1.get_backend",
        lambda find_library=None: callbacks.append(find_library) or sentinel,
    )

    assert usb_backend.get_libusb_backend() is sentinel
    assert len(callbacks) == 1
    assert callable(callbacks[0])
    assert callbacks[0]("ignored") == str(library.resolve())


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
    monkeypatch.setattr("ctypes.util.find_library", lambda _name: None)
    monkeypatch.setattr(
        "usb.backend.libusb1.get_backend",
        lambda find_library=None: calls.append(find_library) or sentinel,
    )

    assert usb_backend.get_libusb_backend() is sentinel
    assert calls == [None]


def test_frozen_bundle_resolver_finds_linux_so_name(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    frameworks = tmp_path / "NegPy.app" / "Contents" / "Frameworks"
    executable = tmp_path / "NegPy.app" / "Contents" / "MacOS" / "NegPy"
    frameworks.mkdir(parents=True)
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"app")
    library = frameworks / "coolscanpy" / "_native" / "libusb-1.0.so.0"
    library.parent.mkdir(parents=True)
    library.write_bytes(b"libusb")

    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(executable))
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)

    assert usb_backend.bundled_libusb_path() == library.resolve()


def test_source_backend_tries_find_library_before_pyusb_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sentinel = object()
    fake_library = "/fake/libusb-1.0.so.0"
    captured: list[object] = []
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(
        "ctypes.util.find_library",
        lambda name: fake_library if name == "usb-1.0" else None,
    )
    monkeypatch.setattr(
        "usb.backend.libusb1.get_backend",
        lambda find_library=None: captured.append(find_library) or sentinel,
    )

    assert usb_backend.get_libusb_backend() is sentinel
    assert len(captured) == 1
    resolver = captured[0]
    assert resolver is not None
    assert resolver("usb-1.0") == fake_library
