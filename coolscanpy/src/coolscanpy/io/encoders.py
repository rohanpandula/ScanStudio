import os
import struct
import tempfile
from pathlib import Path
from typing import BinaryIO

import numpy as np
import tifffile

from coolscanpy.receipts.tiff_contract import LINEAR_SCANNER_RGB_EXTRATAG
from coolscanpy.session.result import ScanResult
from coolscanpy._logging import get_logger

logger = get_logger(__name__)


def _fsync_file(path: str | os.PathLike[str]) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_directory(path: str | os.PathLike[str]) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write_text(path: Path, text: str) -> None:
    """mkstemp beside path, write+fsync, os.replace, fsync parent.

    The temp file is removed if anything fails before the replace commits.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_str = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_str)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _to_uint16(arr: np.ndarray) -> np.ndarray:
    """Convert array to uint16. For uint8, replicate byte (x<<8 | x) so 8-bit
    values span the full 16-bit range instead of being capped at 255."""
    if arr.dtype == np.uint16:
        return arr
    if arr.dtype == np.uint8:
        a16 = arr.astype(np.uint16)
        return (a16 << 8) | a16
    return arr.astype(np.uint16)


def _write_temp_tiff(
    data: np.ndarray,
    target_path: str,
    *,
    photometric: str,
    compression: str = "lzw",
    predictor: bool = False,
    dpi: int | None = None,
) -> str:
    """Write `data` to a temp TIFF next to `target_path`. Returns the temp path.

    Caller commits it (os.replace to the real path) and is responsible for
    cleaning up the temp file if anything downstream fails. On failure here,
    the temp file is cleaned up before re-raising and `target_path` itself is
    never touched.

    `compression`/`predictor` default to the archival bundle/full-negative
    writers' validated lzw-no-predictor setting; `write_tiff_16bit` overrides
    both to match upstream v0.37.0's zlib+predictor tuning for that writer.
    """
    fd, tmp_path = tempfile.mkstemp(suffix=".tif", dir=os.path.dirname(target_path) or ".")
    os.close(fd)
    kwargs: dict = {}
    if dpi and dpi > 0:
        # archival provenance: without this, tifffile stamps XResolution=1
        kwargs["resolution"] = (dpi, dpi)
        kwargs["resolutionunit"] = "INCH"
    if photometric == "rgb":
        # Every RGB payload produced by this module is canonical scanner data,
        # not sRGB-encoded display data.  Stamp a durable, versioned TIFF
        # contract so TiffLoader does not apply a second transfer function.
        kwargs["extratags"] = [LINEAR_SCANNER_RGB_EXTRATAG]
    try:
        tifffile.imwrite(tmp_path, data, photometric=photometric, compression=compression, predictor=predictor, **kwargs)
        _fsync_file(tmp_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise
    return tmp_path


def _unused_sibling_path(target_path: str) -> str:
    """Reserve a unique sibling name until the caller atomically replaces it.

    The returned path is used as a rename target for an existing TIFF while a
    replacement pair is committed. Keeping it in the same directory preserves
    the atomic-rename guarantee of ``os.replace`` for each individual file.
    The placeholder must remain present so another process cannot reserve the
    same backup name before the replace.
    """
    fd, backup_path = tempfile.mkstemp(
        prefix=f".{os.path.basename(target_path)}.",
        suffix=".bak",
        dir=os.path.dirname(target_path) or ".",
    )
    os.close(fd)
    return backup_path


def _unlink_if_present(path: str | None) -> None:
    if path is not None and os.path.exists(path):
        os.unlink(path)


def _commit_tiff_pair(tmp_rgb: str, tmp_ir: str | None, rgb_path: str, ir_path: str) -> None:
    """Commit prepared TIFFs while preserving any prior pair on an error.

    This protects against synchronous rename failures in the running process.
    It is not a two-file filesystem transaction: a crash or power loss between
    the sequential renames can leave destinations missing or mixed, with
    sibling backup files requiring recovery.
    """
    backup_rgb = None
    backup_ir = None
    moved_old_rgb = False
    moved_old_ir = False
    committed_rgb = False
    committed_ir = False

    try:
        backup_rgb = _unused_sibling_path(rgb_path) if os.path.exists(rgb_path) else None
        backup_ir = _unused_sibling_path(ir_path) if os.path.exists(ir_path) else None
        if backup_rgb is not None:
            os.replace(rgb_path, backup_rgb)
            moved_old_rgb = True
        if backup_ir is not None:
            os.replace(ir_path, backup_ir)
            moved_old_ir = True

        os.replace(tmp_rgb, rgb_path)
        committed_rgb = True
        tmp_rgb = ""
        if tmp_ir is not None:
            os.replace(tmp_ir, ir_path)
            committed_ir = True
            tmp_ir = None
    except BaseException as commit_error:
        rollback_errors: list[str] = []

        def _restore(target: str, backup: str | None, moved_old: bool, committed_new: bool) -> None:
            try:
                if moved_old and backup is not None:
                    os.replace(backup, target)
                elif committed_new:
                    _unlink_if_present(target)
            except BaseException as rollback_error:
                rollback_errors.append(f"{target}: {rollback_error}")

        # Restore in reverse commit order. A successful os.replace both removes
        # the new payload and returns the old payload to its original name.
        _restore(ir_path, backup_ir, moved_old_ir, committed_ir)
        _restore(rgb_path, backup_rgb, moved_old_rgb, committed_rgb)
        for label, cleanup_path in (("RGB temp", tmp_rgb), ("IR temp", tmp_ir)):
            try:
                _unlink_if_present(cleanup_path)
            except BaseException as cleanup_error:
                rollback_errors.append(f"{label}: {cleanup_error}")
        for label, backup_path, moved_old in (
            ("RGB backup reservation", backup_rgb, moved_old_rgb),
            ("IR backup reservation", backup_ir, moved_old_ir),
        ):
            if backup_path is not None and not moved_old:
                try:
                    _unlink_if_present(backup_path)
                except BaseException as cleanup_error:
                    rollback_errors.append(f"{label}: {cleanup_error}")

        if rollback_errors:
            details = "; ".join(rollback_errors)
            raise RuntimeError(
                f"TIFF pair commit failed and rollback was incomplete; preserved backup files may remain: {details}"
            ) from commit_error
        raise

    # The replacement pair is complete. Backup deletion is cleanup, not part
    # of the pair commit: if deletion fails, keep the valid new pair and leave
    # the uniquely named backup recoverable instead of attempting a late
    # rollback after one backup may already have been removed.
    for backup_path in (backup_rgb, backup_ir):
        try:
            _unlink_if_present(backup_path)
        except OSError as cleanup_error:
            logger.warning(f"Could not remove TIFF transaction backup {backup_path}: {cleanup_error}")
    _fsync_file(rgb_path)
    if os.path.exists(ir_path):
        _fsync_file(ir_path)
    _fsync_directory(os.path.dirname(rgb_path) or ".")


def write_tiff_16bit(result: ScanResult, path: str) -> str:
    """Write ScanResult to 16-bit TIFF. IR written as sidecar `<basename>_IR.tif`.

    RGB and (if present) IR are encoded completely before either destination
    changes. A synchronous commit error restores the entire prior RGB/IR pair
    and removes new temporary payloads. This is exception-safe, not a claim of
    power-loss atomicity: two filenames require sequential filesystem renames,
    so a process crash or power loss between them can expose a mixed pair.
    When this write has no IR, a stale `<basename>_IR.tif` sidecar from the
    prior pair is removed as part of the same exception-safe replacement.

    Returns final RGB path.
    """
    if not path.lower().endswith((".tif", ".tiff")):
        path = path + ".tif"

    rgb = _to_uint16(result.rgb)
    base = os.path.splitext(path)[0]
    ir_path = f"{base}_IR.tif"
    has_ir = result.ir is not None

    # Phase 1: write both payloads to temp files. Nothing under `path` or
    # `ir_path` is touched here, so a failure at this stage (bad array,
    # codec error, disk full) leaves the filesystem exactly as it was.
    # zlib+predictor (rather than _write_temp_tiff's archival-default lzw)
    # matches upstream v0.37.0's tuning for this writer specifically.
    tmp_rgb = _write_temp_tiff(rgb, path, photometric="rgb", compression="zlib", predictor=True, dpi=result.dpi)
    tmp_ir = None
    if has_ir:
        try:
            ir_data = _to_uint16(result.ir)
            tmp_ir = _write_temp_tiff(ir_data, ir_path, photometric="minisblack", compression="zlib", predictor=True, dpi=result.dpi)
        except Exception:
            os.unlink(tmp_rgb)
            raise

    # Phase 2: swap the prepared payloads in, retaining any prior pair until
    # every requested destination has been committed.
    _commit_tiff_pair(tmp_rgb, tmp_ir, path, ir_path)

    return path


_DNG_VERSION = (1, 4, 0, 0)
_DNG_BACKWARD_VERSION = (1, 1, 0, 0)
_INFRARED_TAG = 65001
_INFRARED_MARKER = "scanstudio.infrared.linear.uint16.v1"


class _NamedBinaryFile:
    """Give descriptor-backed streams the path-like name tifffile requires."""

    def __init__(self, file: BinaryIO) -> None:
        self._file = file
        name = getattr(file, "name", None)
        self.name = name if isinstance(name, (str, bytes, os.PathLike)) else "scanstudio.dng"

    def __getattr__(self, name: str):
        return getattr(self._file, name)


def _ascii_scanner_model(value: str) -> str:
    """Return a non-empty TIFF-ASCII model without inventing a different device."""

    model = value.encode("ascii", "replace").decode("ascii").strip()
    return model or "Unknown Coolscan"


def _dng_main_extratags(*, width: int, height: int, model: str) -> list[tuple]:
    unique_model = model if model.casefold().startswith("nikon") else f"Nikon {model}"
    return [
        (254, 4, 1, 0, True),  # NewSubfileType: full-resolution image
        (50706, 1, 4, _DNG_VERSION, True),
        (50707, 1, 4, _DNG_BACKWARD_VERSION, True),
        (274, 3, 1, 1, True),  # Orientation: stored pixels are not transformed
        (271, 2, 0, "Nikon", True),
        (272, 2, 0, model, True),
        (50708, 2, 0, unique_model, True),
        (50714, "2I", 3, (0, 1, 0, 1, 0, 1), True),  # BlackLevel
        (50717, 4, 3, (65535, 65535, 65535), True),  # WhiteLevel
        (50718, "2I", 2, (1, 1, 1, 1), True),  # DefaultScale
        (50719, 4, 2, (0, 0), True),  # DefaultCropOrigin
        (50720, 4, 2, (width, height), True),  # DefaultCropSize
        (50829, 4, 4, (0, 0, height, width), True),  # ActiveArea
        (50728, "2I", 3, (1, 1, 1, 1, 1, 1), True),  # AsShotNeutral
        (50778, 3, 1, 0, True),  # CalibrationIlluminant1: unknown
        # No measured scanner-to-XYZ calibration exists. Identity is an
        # explicit interoperability placeholder, paired with the unknown
        # illuminant above, rather than a false sRGB/camera profile claim.
        (
            50721,
            "2i",
            9,
            (1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1),
            True,
        ),
    ]


def _dng_ir_extratags() -> list[tuple]:
    return [
        (254, 4, 1, 0, True),
        (274, 3, 1, 1, True),
        (270, 2, 0, "Untouched scanner infrared plane", True),
        (_INFRARED_TAG, 2, 0, _INFRARED_MARKER, True),
    ]


def write_dng_linear_to_file(file: BinaryIO, result: ScanResult) -> None:
    """Encode one uncompressed LinearRaw DNG into a readable, seekable file.

    The converter-facing main IFD is always three plain RGB samples. Infrared,
    when present, is a same-size grayscale SubIFD carrying a versioned private
    marker. Keeping IR out of the main image avoids the ambiguous four-sample
    LinearRaw layout that raw processors commonly interpret as one color
    sample plus three auxiliaries.

    ``file`` is not closed. The caller owns publication and durability.
    """

    rgb = np.ascontiguousarray(_to_uint16(result.rgb))
    if rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError("Linear DNG RGB must have shape (height, width, 3)")
    height, width, _ = rgb.shape
    ir: np.ndarray | None = None
    if result.ir is not None:
        ir = np.ascontiguousarray(_to_uint16(result.ir))
        if ir.ndim == 3 and ir.shape[2] == 1:
            ir = ir[:, :, 0]
        if ir.ndim != 2 or ir.shape != (height, width):
            raise ValueError("Linear DNG IR must match the RGB height and width")

    model = _ascii_scanner_model(result.device_model)
    named_file = _NamedBinaryFile(file)
    with tifffile.TiffWriter(named_file, byteorder="<") as writer:
        writer.write(
            rgb,
            photometric=tifffile.PHOTOMETRIC.RGB,
            compression=None,
            metadata=None,
            subifds=1 if ir is not None else None,
            extratags=_dng_main_extratags(width=width, height=height, model=model),
            resolution=(result.dpi, result.dpi),
            resolutionunit="INCH",
            software="ScanStudio",
        )
        if ir is not None:
            writer.write(
                ir,
                photometric=tifffile.PHOTOMETRIC.MINISBLACK,
                compression=None,
                metadata=None,
                extratags=_dng_ir_extratags(),
                resolution=(result.dpi, result.dpi),
                resolutionunit="INCH",
                software="ScanStudio",
            )

    # tifffile models LinearRaw as one photometric sample. Writing the RGB
    # page with RGB first is what produces three color samples and no
    # ExtraSamples; patching only the already-emitted SHORT tag then gives
    # DNG its required LinearRaw value without changing any strip bytes.
    file.flush()
    file.seek(0)
    with tifffile.TiffFile(named_file) as tiff:
        page = tiff.pages[0]
        if page.samplesperpixel != 3 or page.extrasamples:
            raise RuntimeError("Linear DNG main IFD did not encode as three plain RGB samples")
        photometric_offset = page.tags["PhotometricInterpretation"].valueoffset
        byteorder = tiff.byteorder
    file.seek(photometric_offset)
    written = file.write(struct.pack(byteorder + "H", 34892))
    if written != 2:
        raise OSError("short write while setting LinearRaw photometric tag")
    file.flush()


def write_dng_linear(result: ScanResult, path: str) -> str:
    """Atomically write an uncompressed 16-bit LinearRaw DNG.

    The final name is replaced only after the complete RGB main IFD, optional
    embedded IR SubIFD, and LinearRaw tag patch are flushed and synced.
    """
    if not path.lower().endswith(".dng"):
        path = path + ".dng"
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(suffix=".dng", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w+b") as file:
            write_dng_linear_to_file(file, result)
            os.fsync(file.fileno())
        os.replace(tmp_path, path)
        _fsync_directory(target.parent)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

    return path
