"""Deterministic libusb backend selection for source and packaged builds.

PyUSB normally asks the host dynamic-loader search path for libusb.  That is
fine for an editable checkout, but a Finder-launched macOS application does
not inherit Homebrew's shell paths.  Frozen applications and ScanStudio's
transparent bundled CPython therefore fail closed unless the app contains its
own ``libusb-1.0`` binary.  The binary is covered by the app's code signature;
this module only resolves paths inside that signed bundle and never accepts a
caller-controlled library path.
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


def _app_contents_root(path: Path) -> Path | None:
    """Return the containing ``*.app/Contents`` directory, when present."""

    resolved = path.resolve()
    for parent in resolved.parents:
        if parent.name == "Contents" and parent.parent.suffix == ".app":
            return parent
    return None


def _transparent_app_bundle_roots() -> tuple[Path, ...]:
    """Resolve ScanStudio's signed Frameworks directory without an env path.

    ScanStudio ships a relocatable CPython rather than a PyInstaller-frozen
    executable, so ``sys.frozen`` is deliberately false.  Treat it as a
    packaged context only when both the interpreter and this exact source file
    live in the same app bundle and the interpreter has ScanStudio's fixed
    ``BridgeRuntime/python/bin`` shape.  A developer interpreter importing a
    checkout beside an app therefore remains a normal host-lookup source run.
    """

    executable = Path(sys.executable).resolve()
    executable_contents = _app_contents_root(executable)
    module_contents = _app_contents_root(Path(__file__))
    if executable_contents is None or module_contents != executable_contents:
        return ()
    expected_bin = (
        executable_contents / "Resources" / "BridgeRuntime" / "python" / "bin"
    )
    if executable.parent != expected_bin:
        return ()
    return (executable_contents / "Frameworks",)


def _bundled_library_roots() -> tuple[Path, ...]:
    if getattr(sys, "frozen", False):
        return _frozen_bundle_roots()
    return _transparent_app_bundle_roots()


def bundled_libusb_path() -> Path:
    """Resolve the signed, app-owned libusb binary for a packaged process."""

    roots = _bundled_library_roots()
    if not roots:
        raise LibusbBackendUnavailable(
            "bundled libusb resolution is only valid inside a packaged application"
        )
    candidates: list[Path] = []
    for root in roots:
        root_candidates = tuple(
            root / relative
            for relative in (
                *(
                    Path("coolscanpy") / "_native" / name
                    for name in _LIBUSB_BASENAMES
                ),
                *(Path(name) for name in _LIBUSB_BASENAMES),
            )
        )
        candidates.extend(root_candidates)
        try:
            resolved_parent = root.parent.resolve(strict=True)
            resolved_root = root.resolve(strict=True)
        except OSError:
            continue
        # Reject a Frameworks/MacOS/_MEIPASS root redirected outside its
        # approved containing directory, then reject any nested-directory
        # symlink that makes the library itself escape that root.
        if not resolved_root.is_relative_to(resolved_parent):
            continue
        for candidate in root_candidates:
            if candidate.is_symlink():
                continue
            try:
                resolved_candidate = candidate.resolve(strict=True)
            except OSError:
                continue
            if (
                resolved_candidate.is_file()
                and resolved_candidate.is_relative_to(resolved_root)
            ):
                return resolved_candidate
    rendered = ", ".join(str(path) for path in candidates)
    raise LibusbBackendUnavailable(
        "the frozen application does not contain its required libusb 1.0 "
        f"binary (checked: {rendered})"
    )


def get_libusb_backend() -> Any:
    """Return a usable PyUSB libusb1 backend or raise a precise error.

    Source installs retain PyUSB's normal host lookup.  Packaged processes
    bind the loader to :func:`bundled_libusb_path`, avoiding dependence on
    PATH, Homebrew prefixes, or ambient dynamic-loader variables.
    """

    import usb.backend.libusb1

    if _bundled_library_roots():
        library = bundled_libusb_path()
        backend = usb.backend.libusb1.get_backend(
            find_library=lambda _name: str(library)
        )
    else:
        backend = usb.backend.libusb1.get_backend()
    if backend is None:
        scope = "bundled" if _bundled_library_roots() else "host"
        raise LibusbBackendUnavailable(
            f"PyUSB could not load the {scope} libusb 1.0 backend"
        )
    return backend


__all__ = [
    "LibusbBackendUnavailable",
    "bundled_libusb_path",
    "get_libusb_backend",
]
