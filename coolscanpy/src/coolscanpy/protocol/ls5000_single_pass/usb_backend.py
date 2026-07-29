"""Deterministic libusb backend selection for source and frozen builds.

PyUSB normally asks the host dynamic-loader search path for libusb.  That is
fine for an editable checkout, but a Finder-launched macOS application does
not inherit Homebrew's shell paths.  Frozen builds therefore fail closed
unless the app contains its own ``libusb-1.0`` binary.  The binary is covered
by the app's code signature; this module only resolves paths inside that
signed bundle and never accepts a caller-controlled library path.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any


_LIBUSB_BASENAMES = ("libusb-1.0.dylib", "libusb-1.0.0.dylib")


class LibusbBackendUnavailable(RuntimeError):
    """PyUSB could not load the required libusb 1.0 backend."""


def _frozen_bundle_roots() -> tuple[Path, ...]:
    """Return the bounded locations PyInstaller uses for app binaries."""

    roots: list[Path] = []
    meipass = getattr(sys, "_MEIPASS", None)
    if isinstance(meipass, str) and meipass:
        roots.append(Path(meipass))

    executable = Path(sys.executable).resolve()
    # ``NegPy.app/Contents/MacOS/NegPy`` -> ``Contents/Frameworks``.  Keeping
    # the executable directory as a second candidate also supports one-file
    # and non-macOS PyInstaller layouts without searching the host filesystem.
    roots.extend((executable.parent, executable.parent.parent / "Frameworks"))

    unique: list[Path] = []
    for root in roots:
        if root not in unique:
            unique.append(root)
    return tuple(unique)


def bundled_libusb_path() -> Path:
    """Resolve the signed, app-owned libusb binary for a frozen process."""

    if not getattr(sys, "frozen", False):
        raise LibusbBackendUnavailable(
            "bundled libusb resolution is only valid inside a frozen application"
        )
    candidates = tuple(
        root / relative
        for root in _frozen_bundle_roots()
        for relative in (
            *(Path("coolscanpy") / "_native" / name for name in _LIBUSB_BASENAMES),
            *(Path(name) for name in _LIBUSB_BASENAMES),
        )
    )
    for candidate in candidates:
        if candidate.is_file() and not candidate.is_symlink():
            return candidate.resolve(strict=True)
    rendered = ", ".join(str(path) for path in candidates)
    raise LibusbBackendUnavailable(
        "the frozen application does not contain its required libusb 1.0 "
        f"binary (checked: {rendered})"
    )


def get_libusb_backend() -> Any:
    """Return a usable PyUSB libusb1 backend or raise a precise error.

    Source installs retain PyUSB's normal host lookup.  Frozen processes bind
    the loader to :func:`bundled_libusb_path`, avoiding dependence on PATH,
    Homebrew prefixes, or ambient dynamic-loader variables.
    """

    import usb.backend.libusb1

    if getattr(sys, "frozen", False):
        library = bundled_libusb_path()
        backend = usb.backend.libusb1.get_backend(
            find_library=lambda _name: str(library)
        )
    else:
        backend = usb.backend.libusb1.get_backend()
    if backend is None:
        scope = "bundled" if getattr(sys, "frozen", False) else "host"
        raise LibusbBackendUnavailable(
            f"PyUSB could not load the {scope} libusb 1.0 backend"
        )
    return backend


__all__ = [
    "LibusbBackendUnavailable",
    "bundled_libusb_path",
    "get_libusb_backend",
]
