"""Create-only output-group reservations shared by both transports.

The bridge must know every possible artifact path before capture starts and
must never let a TIFF writer replace an existing artifact.  Reserving each
path with exclusive creation makes that decision before motion; writes later
use the reservation's same file identity rather than opening an arbitrary
path afresh.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import tifffile

from scanstudio_bridge import domain
from scanstudio_bridge.protocol import BridgeError, ErrorCode


@dataclass(frozen=True)
class OutputGroup:
    """All paths a requested slot may produce."""

    rgb_path: Path
    ir_path: Path | None
    meter_rgbi_path: Path | None

    @property
    def paths(self) -> tuple[Path, ...]:
        return tuple(
            path
            for path in (self.rgb_path, self.ir_path, self.meter_rgbi_path)
            if path is not None
        )


def _normalize_tiff_template(filename_template: str) -> str:
    suffix = Path(filename_template).suffix.casefold()
    if suffix in {".tif", ".tiff"}:
        return filename_template
    return f"{filename_template}.tif"


def _resolve_filename(filename_template: str, slot: int) -> str:
    reserved = re.search(r"\$ScanStudioSequence\(([1-9][0-9]*)\)", filename_template)
    if reserved is not None:
        return (
            filename_template[: reserved.start()]
            + reserved.group(1)
            + filename_template[reserved.end() :]
        )
    match = re.search(r"#+", filename_template)
    if match is not None:
        width = match.end() - match.start()
        return (
            filename_template[: match.start()]
            + f"{slot:0{width}d}"
            + filename_template[match.end() :]
        )
    path = Path(filename_template)
    if path.suffix.casefold() in {".tif", ".tiff", ".jpg", ".jpeg"}:
        return f"{path.stem}_{slot}{path.suffix}"
    return f"{filename_template}_{slot}"


def _resolve_output_path(destination: str, filename_template: str, slot: int) -> Path:
    """Resolve one RGB artifact path without allowing template escape."""
    if not destination.strip():
        raise BridgeError(ErrorCode.INVALID_PARAMS, "output.destination must not be empty")
    filename = _resolve_filename(_normalize_tiff_template(filename_template), slot)
    filename_path = Path(filename)
    if (
        not filename
        or filename in {".", ".."}
        or filename_path.is_absolute()
        or filename_path.name != filename
        or "/" in filename
        or "\\" in filename
    ):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "output.filenameTemplate must resolve to exactly one relative file name: "
            f"{filename_template!r}",
        )
    dest_root = Path(destination).resolve()
    if dest_root.exists() and not dest_root.is_dir():
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"output.destination is not a directory: {destination!r}",
        )
    candidate = dest_root / filename
    # Do not call candidate.resolve(): resolving the leaf would follow an
    # existing or dangling symlink before the create-exclusive reservation.
    # `open('xb')` below then supplies the atomic no-follow decision.
    if candidate.is_symlink():
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"output artifact is an existing symlink: {candidate}",
        )
    return candidate


def output_group_for_slot(
    output: domain.OutputSpec, recipe: domain.CaptureRecipe, slot: int
) -> OutputGroup:
    """Return every path this slot may write, including an optional meter TIFF."""
    template = output.filename_template
    destination = output.destination
    if output.slot_outputs is not None:
        slot_output = output.slot_outputs[str(slot)]
        template = slot_output.filename_template
        destination = slot_output.destination
    rgb_path = _resolve_output_path(destination, template, slot)
    if recipe.channels is not domain.Channels.RGBI:
        # Meter data is an auto-exposure prepass, not an IR sidecar. A real
        # frame can therefore supply it independently of the requested RGB
        # channels, so reserve its only possible target on every route.
        return OutputGroup(
            rgb_path=rgb_path,
            ir_path=None,
            meter_rgbi_path=rgb_path.with_name(f"{rgb_path.stem}_METER.tif"),
        )
    return OutputGroup(
        rgb_path=rgb_path,
        ir_path=rgb_path.with_name(f"{rgb_path.stem}_IR.tif"),
        # CoolscanPy may omit meter_rgbi, but it is the only possible meter
        # target for this requested route and must be collision-safe before
        # scan_many begins. A successful no-meter frame releases this empty
        # reservation.
        meter_rgbi_path=rgb_path.with_name(f"{rgb_path.stem}_METER.tif"),
    )


class OutputReservations:
    """Exclusive placeholders that can only be written by this reservation.

    `cleanup_before_capture_failure()` removes only files whose device/inode
    still match this call's own zero-byte reservation, so it never deletes an
    existing file that appeared at the same path later.
    """

    def __init__(self, groups: dict[int, OutputGroup]) -> None:
        self.groups = groups
        self._owned: dict[Path, tuple[int, int]] = {}
        self._written: set[Path] = set()

    @classmethod
    def reserve(
        cls, slots: list[int], recipe: domain.CaptureRecipe, output: domain.OutputSpec
    ) -> "OutputReservations":
        if output.slot_outputs is not None:
            expected = {str(slot) for slot in slots}
            actual = set(output.slot_outputs)
            if actual != expected:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    "output.slotOutputs must contain exactly the requested slots",
                )
        groups = {slot: output_group_for_slot(output, recipe, slot) for slot in slots}
        seen_targets: dict[str, tuple[int, Path]] = {}
        for slot, group in groups.items():
            for path in group.paths:
                # Fail closed for case-only aliases even when tests run on
                # a case-sensitive filesystem; default macOS volumes are
                # case-insensitive and would identify these leaves.
                key = os.path.normpath(str(path)).casefold()
                if key in seen_targets:
                    other_slot, other_path = seen_targets[key]
                    raise BridgeError(
                        ErrorCode.INVALID_PARAMS,
                        "output artifacts must be physically distinct: "
                        f"slot {slot} {path} aliases slot {other_slot} {other_path}",
                    )
                seen_targets[key] = (slot, path)
        reservations = cls(groups)
        try:
            for group in groups.values():
                for path in group.paths:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        with path.open("xb") as file:
                            stat = os.fstat(file.fileno())
                    except FileExistsError as exc:
                        raise BridgeError(
                            ErrorCode.INVALID_PARAMS,
                            f"output artifact already exists: {path}",
                        ) from exc
                    reservations._owned[path] = (stat.st_dev, stat.st_ino)
        except Exception:
            reservations.release_unused()
            raise
        return reservations

    def open_for_write(self, path: Path):
        """Open an owned reservation for writing, rejecting replacement races."""
        expected = self._owned.get(path)
        if expected is None:
            raise RuntimeError(f"output path was not reserved by this call: {path}")
        flags = os.O_WRONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
        stat = os.fstat(fd)
        if (stat.st_dev, stat.st_ino) != expected:
            os.close(fd)
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"output artifact changed after reservation: {path}",
            )
        os.ftruncate(fd, 0)
        return os.fdopen(fd, "wb")

    def mark_written(self, path: Path) -> None:
        self._written.add(path)

    def release_unused(self, path: Path | None = None) -> None:
        """Remove own untouched placeholders after a successful write/job."""
        candidates = (path,) if path is not None else tuple(self._owned)
        for candidate in candidates:
            if candidate is not None and candidate not in self._written:
                self._unlink_if_owned(candidate)

    def _unlink_if_owned(self, path: Path) -> None:
        expected = self._owned.get(path)
        if expected is None:
            return
        try:
            stat = path.stat(follow_symlinks=False)
        except FileNotFoundError:
            return
        if (stat.st_dev, stat.st_ino) != expected:
            return
        path.unlink()


class _NamedReservationFile:
    """File-object proxy that keeps tifffile on an already-open descriptor.

    tifffile derives metadata from ``file.name`` and ``os.path.split()``;
    ``os.fdopen()`` exposes the numeric descriptor there.  This proxy gives
    it the reserved path while delegating all I/O to that same descriptor.
    """

    def __init__(self, file: Any, path: Path) -> None:
        self._file = file
        self.name = str(path)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._file, name)


def write_tiff(
    reservations: OutputReservations, path: Path, data: Any, **kwargs: object
) -> None:
    """Write TIFF data only through this call's exclusive reservation."""
    with reservations.open_for_write(path) as file:
        tifffile.imwrite(_NamedReservationFile(file, path), data, **kwargs)
    reservations.mark_written(path)
