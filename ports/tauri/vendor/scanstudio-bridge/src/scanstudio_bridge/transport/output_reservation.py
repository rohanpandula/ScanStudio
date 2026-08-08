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
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import tifffile

from scanstudio_bridge import domain
from scanstudio_bridge.protocol import BridgeError, ErrorCode

WSL_STAGING_BASE = Path("/tmp/scanstudio-wsl-staging")


def _safe_staging_token(value: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9_-]+", value)) and value not in {".", ".."}


def _secure_private_staging_destination(destination: str) -> Path | None:
    """Create one engine-requested WSL staging directory privately.

    Ordinary output destinations retain the existing behavior. The exact
    `/tmp/scanstudio-wsl-staging/<owner>` lane is a native/WSL trust boundary:
    its shared parent is private to this Unix user and each owner directory is
    created exactly once, never followed through a pre-existing symlink.
    """
    path = Path(destination)
    if path.parent != WSL_STAGING_BASE:
        return None
    if not path.is_absolute() or not _safe_staging_token(path.name):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "WSL staging destination must be one safe direct child of "
            f"{WSL_STAGING_BASE}",
        )

    parent = WSL_STAGING_BASE.parent
    try:
        parent_stat = parent.lstat()
    except OSError as exc:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"cannot inspect WSL staging ancestor {parent}: {exc}",
        ) from exc
    if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"WSL staging ancestor must be a real directory: {parent}",
        )

    try:
        WSL_STAGING_BASE.mkdir(mode=0o700)
    except FileExistsError:
        pass
    try:
        base_stat = WSL_STAGING_BASE.lstat()
    except OSError as exc:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"cannot inspect WSL staging base {WSL_STAGING_BASE}: {exc}",
        ) from exc
    if stat.S_ISLNK(base_stat.st_mode) or not stat.S_ISDIR(base_stat.st_mode):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"WSL staging base must be a real directory: {WSL_STAGING_BASE}",
        )
    if hasattr(os, "getuid") and base_stat.st_uid != os.getuid():
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"WSL staging base is not owned by the bridge user: {WSL_STAGING_BASE}",
        )
    try:
        WSL_STAGING_BASE.chmod(0o700, follow_symlinks=False)
        path.mkdir(mode=0o700)
        path.chmod(0o700, follow_symlinks=False)
    except FileExistsError as exc:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"WSL staging owner directory already exists: {path}",
        ) from exc
    except OSError as exc:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"cannot create private WSL staging directory {path}: {exc}",
        ) from exc
    return path


@dataclass(frozen=True)
class OutputGroup:
    """All paths a requested slot may produce."""

    rgb_path: Path
    ir_path: Path | None
    meter_rgbi_path: Path | None
    raw_export_path: Path | None
    raw_export_ir_path: Path | None

    @property
    def paths(self) -> tuple[Path, ...]:
        return tuple(
            path
            for path in (
                self.rgb_path,
                self.ir_path,
                self.meter_rgbi_path,
                self.raw_export_path,
                self.raw_export_ir_path,
            )
            if path is not None
        )


def _normalize_tiff_template(filename_template: str) -> str:
    suffix = Path(filename_template).suffix.casefold()
    if suffix in {".tif", ".tiff"}:
        return filename_template
    return f"{filename_template}.tif"


def _normalize_raw_template(
    filename_template: str, file_format: domain.RawExportFormat
) -> str:
    desired = ".dng" if file_format is domain.RawExportFormat.LINEAR_DNG else ".tif"
    path = Path(filename_template)
    if path.suffix.casefold() == desired:
        return filename_template
    if path.suffix.casefold() in {".tif", ".tiff", ".dng", ".jpg", ".jpeg"}:
        return f"{filename_template[: -len(path.suffix)]}{desired}"
    return f"{filename_template}{desired}"


def raw_export_ir_sidecar_path(raw_export_path: Path) -> Path:
    """Derive the documented lowercase ``-ir.tif`` paired-artifact name."""
    return raw_export_path.with_name(f"{raw_export_path.stem}-ir.tif")


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
    if path.suffix.casefold() in {".tif", ".tiff", ".dng", ".jpg", ".jpeg"}:
        return f"{path.stem}_{slot}{path.suffix}"
    return f"{filename_template}_{slot}"


def _resolve_output_path(
    destination: str,
    filename_template: str,
    slot: int,
    *,
    normalize_tiff: bool = True,
) -> Path:
    """Resolve one RGB artifact path without allowing template escape."""
    if not destination.strip():
        raise BridgeError(ErrorCode.INVALID_PARAMS, "output.destination must not be empty")
    normalized = _normalize_tiff_template(filename_template) if normalize_tiff else filename_template
    filename = _resolve_filename(normalized, slot)
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
    raw_export = output.raw_export
    if output.slot_outputs is not None:
        slot_output = output.slot_outputs[str(slot)]
        template = slot_output.filename_template
        destination = slot_output.destination
        raw_export = slot_output.raw_export
    rgb_path = _resolve_output_path(destination, template, slot)
    raw_export_path = None
    raw_export_ir_path = None
    if raw_export is not None:
        raw_export_path = _resolve_output_path(
            raw_export.destination,
            _normalize_raw_template(raw_export.filename_template, raw_export.file_format),
            slot,
            normalize_tiff=False,
        )
        if (
            recipe.channels is domain.Channels.RGBI
            and raw_export.tiff_infrared is domain.RawTiffInfrared.SIDECAR
        ):
            raw_export_ir_path = raw_export_ir_sidecar_path(raw_export_path)
    if recipe.channels is not domain.Channels.RGBI:
        # Meter data is an auto-exposure prepass, not an IR sidecar. A real
        # frame can therefore supply it independently of the requested RGB
        # channels, so reserve its only possible target on every route.
        return OutputGroup(
            rgb_path=rgb_path,
            ir_path=None,
            meter_rgbi_path=rgb_path.with_name(f"{rgb_path.stem}_METER.tif"),
            raw_export_path=raw_export_path,
            raw_export_ir_path=raw_export_ir_path,
        )
    return OutputGroup(
        rgb_path=rgb_path,
        ir_path=rgb_path.with_name(f"{rgb_path.stem}_IR.tif"),
        # CoolscanPy may omit meter_rgbi, but it is the only possible meter
        # target for this requested route and must be collision-safe before
        # scan_many begins. A successful no-meter frame releases this empty
        # reservation.
        meter_rgbi_path=rgb_path.with_name(f"{rgb_path.stem}_METER.tif"),
        raw_export_path=raw_export_path,
        raw_export_ir_path=raw_export_ir_path,
    )


def raw_export_for_slot(
    output: domain.OutputSpec, slot: int
) -> domain.RawExportSpec | None:
    if output.slot_outputs is not None:
        return output.slot_outputs[str(slot)].raw_export
    return output.raw_export


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
        raw_specs = (
            [slot.raw_export for slot in output.slot_outputs.values()]
            if output.slot_outputs is not None
            else [output.raw_export]
        )
        if recipe.channels is not domain.Channels.RGBI and any(
            spec is not None
            and spec.file_format is domain.RawExportFormat.LINEAR_TIFF
            and spec.tiff_infrared is domain.RawTiffInfrared.FOURTH_CHANNEL
            for spec in raw_specs
        ):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                "fourth-channel linear TIFF requires recipe.channels=rgbi",
            )
        destinations = {output.destination}
        if output.slot_outputs is not None:
            destinations.update(value.destination for value in output.slot_outputs.values())
        private_staging_dirs: list[Path] = []
        try:
            for destination in sorted(destinations):
                created = _secure_private_staging_destination(destination)
                if created is not None:
                    private_staging_dirs.append(created)
            groups = {slot: output_group_for_slot(output, recipe, slot) for slot in slots}
        except Exception:
            for directory in reversed(private_staging_dirs):
                try:
                    directory.rmdir()
                except OSError:
                    pass
            raise
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
            for directory in reversed(private_staging_dirs):
                try:
                    directory.rmdir()
                except OSError:
                    pass
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

    def open_for_update(self, path: Path):
        """Open written reservation bytes read/write without truncating them."""
        expected = self._owned.get(path)
        if expected is None:
            raise RuntimeError(f"output path was not reserved by this call: {path}")
        flags = os.O_RDWR
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
        return os.fdopen(fd, "r+b")

    def mark_written(self, path: Path) -> None:
        self._written.add(path)

    def discard_owned(self, *paths: Path) -> None:
        """Remove owned paths even after a completed write marked them durable."""
        for path in paths:
            self._written.discard(path)
            self._unlink_if_owned(path)

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


def write_raw_export(
    reservations: OutputReservations,
    path: Path,
    ir_path: Path | None,
    spec: domain.RawExportSpec,
    *,
    rgb: np.ndarray,
    ir: np.ndarray | None,
    dpi: int,
    device_model: str,
) -> None:
    """Write one untouched-negative export, atomically as a pair when requested."""
    if rgb.dtype != np.uint16 or rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError("raw export RGB must be a uint16 (height, width, 3) array")
    if ir is not None and (
        ir.dtype != np.uint16 or ir.ndim != 2 or ir.shape != rgb.shape[:2]
    ):
        raise ValueError("raw export IR must be a uint16 plane matching RGB")

    wants_sidecar = spec.tiff_infrared is domain.RawTiffInfrared.SIDECAR
    if (ir_path is not None) != (wants_sidecar and ir is not None):
        raise ValueError("raw IR sidecar reservation does not match the captured IR plane")

    pair_paths = (path, ir_path) if ir_path is not None else (path,)
    try:
        if spec.file_format is domain.RawExportFormat.LINEAR_DNG:
            # Lazy imports preserve the bridge's hardware-free module import
            # boundary; only an actually requested DNG loads CoolscanPy's
            # scanning-agnostic encoder and result value type.
            from coolscanpy.io.encoders import write_dng_linear_to_file
            from coolscanpy.session.result import ScanResult

            result = ScanResult(
                rgb=rgb,
                ir=None if wants_sidecar else ir,
                dpi=dpi,
                device_model=device_model,
            )
            with reservations.open_for_update(path) as file:
                write_dng_linear_to_file(_NamedReservationFile(file, path), result)
                os.fsync(file.fileno())
        else:
            kwargs: dict[str, object] = {
                "photometric": "rgb",
                "compression": None,
                "metadata": None,
                "resolution": (dpi, dpi),
                "resolutionunit": "INCH",
                "software": "ScanStudio",
            }
            data = rgb
            if spec.tiff_infrared is domain.RawTiffInfrared.FOURTH_CHANNEL:
                if ir is None:
                    raise ValueError("fourth-channel linear TIFF requires an infrared capture plane")
                data = np.ascontiguousarray(np.dstack((rgb, ir)))
                kwargs["extrasamples"] = (0,)
                kwargs["extratags"] = [
                    (65001, "s", 0, "scanstudio.infrared.linear.uint16.v1", True)
                ]
            with reservations.open_for_write(path) as file:
                tifffile.imwrite(_NamedReservationFile(file, path), data, **kwargs)
                file.flush()
                os.fsync(file.fileno())

        if ir_path is not None:
            assert ir is not None
            with reservations.open_for_write(ir_path) as file:
                tifffile.imwrite(
                    _NamedReservationFile(file, ir_path),
                    ir,
                    photometric="minisblack",
                    compression=None,
                    metadata=None,
                    resolution=(dpi, dpi),
                    resolutionunit="INCH",
                    software="ScanStudio",
                    extratags=[
                        (254, "I", 1, 0, True),
                        (274, "H", 1, 1, True),
                        (270, "s", 0, "Untouched scanner infrared plane", True),
                        (65001, "s", 0, "scanstudio.infrared.linear.uint16.v1", True),
                    ],
                )
                file.flush()
                os.fsync(file.fileno())
    except BaseException:
        reservations.discard_owned(*pair_paths)
        raise

    for pair_path in pair_paths:
        reservations.mark_written(pair_path)
