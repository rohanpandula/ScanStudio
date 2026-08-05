import json
import os
import shutil
import tempfile
from hashlib import sha256
from pathlib import Path
from typing import cast

import numpy as np
import tifffile

from coolscanpy.session.result import ScanResult, SplitSourceCapture
from coolscanpy.receipts.quality import inspect_tiff_payload
from coolscanpy.io.encoders import (
    _fsync_directory,
    _fsync_file,
    _unlink_if_present,
    _unused_sibling_path,
    _write_temp_tiff,
)
from coolscanpy._logging import get_logger

logger = get_logger(__name__)

_SPLIT_SOURCE_BUNDLE_VERSION = 1
_SPLIT_SOURCE_BUNDLE_KIND = "negpy.full-negative-split-source"


def _write_staged_tiff(data: np.ndarray, path: Path, *, photometric: str, dpi: int) -> None:
    temporary = _write_temp_tiff(data, str(path), photometric=photometric, dpi=dpi)
    os.replace(temporary, path)
    _fsync_directory(path.parent)


def _update_array_digest(digest, role: str, array: np.ndarray) -> None:
    contiguous = np.ascontiguousarray(array)
    header = json.dumps(
        {"role": role, "shape": list(contiguous.shape), "dtype": contiguous.dtype.str},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest.update(len(header).to_bytes(8, "big"))
    digest.update(header)
    digest.update(memoryview(contiguous).cast("B"))


def _artifact_evidence(path: Path, *, root: Path | None = None) -> dict[str, object]:
    inspection = inspect_tiff_payload(path)
    name = path.name if root is None else str(path.relative_to(root))
    return {
        "path": name,
        "sha256": inspection.sha256,
        "bytes": inspection.byte_length,
        "shape": list(inspection.shape),
        "dtype": inspection.dtype,
        "page_count": inspection.page_count,
        "payload_within_file": inspection.payload_within_file,
        "x_resolution": list(inspection.x_resolution) if inspection.x_resolution is not None else None,
        "y_resolution": list(inspection.y_resolution) if inspection.y_resolution is not None else None,
        "resolution_unit": inspection.resolution_unit,
    }


def _require_committed_bundle_evidence(target: Path, manifest: dict[str, object]) -> None:
    artifacts = manifest.get("artifacts")
    if type(artifacts) is not dict or not artifacts:
        raise RuntimeError(f"committed bundle {target} has invalid artifact evidence")
    for role, raw_evidence in artifacts.items():
        if type(role) is not str or type(raw_evidence) is not dict:
            raise RuntimeError(f"committed bundle {target} has invalid artifact evidence")
        evidence = cast(dict[str, object], raw_evidence)
        relative_path = evidence.get("path")
        if type(relative_path) is not str or Path(relative_path).name != relative_path:
            raise RuntimeError(f"committed bundle {target} has invalid artifact evidence")
        try:
            live = _artifact_evidence(target / relative_path)
        except (OSError, ValueError, tifffile.TiffFileError) as exc:
            raise RuntimeError(f"committed bundle {target} has invalid artifact evidence") from exc
        if live != evidence:
            raise RuntimeError(f"committed bundle {target} has conflicting artifact evidence for {role}")


def write_split_source_bundle(
    source: SplitSourceCapture,
    *,
    aligned_ir: np.ndarray,
    ir_valid_mask: np.ndarray,
    output_dir: str | os.PathLike[str],
    dpi: int,
) -> dict[str, object]:
    """Commit one immutable legacy SANE RGB-plus-IR source bundle.

    The bundle directory is addressed by the exact array content and DPI.
    TIFF payloads are written inside a hidden staging directory; the manifest
    is written last, then the complete directory is renamed into place.
    """

    if type(dpi) is not int or dpi < 1:
        raise ValueError("bundle DPI must be a positive integer")
    rgb4x = np.asarray(source.rgb4x)
    rgb1x_proxy = np.asarray(source.rgb1x_proxy)
    ir1x = np.asarray(source.ir1x)
    aligned = np.asarray(aligned_ir)
    valid = np.asarray(ir_valid_mask)
    if rgb4x.ndim != 3 or rgb4x.shape[2] != 3 or rgb4x.dtype != np.uint16:
        raise ValueError("rgb4x must be a uint16 RGB array")
    if rgb1x_proxy.ndim != 3 or rgb1x_proxy.shape[2] != 3 or rgb1x_proxy.dtype != np.uint16:
        raise ValueError("rgb1x_proxy must be a uint16 RGB array")
    if ir1x.ndim != 2 or ir1x.dtype != np.uint16 or ir1x.shape != rgb1x_proxy.shape[:2]:
        raise ValueError("ir1x must be a uint16 plane matching rgb1x_proxy")
    if aligned.ndim != 2 or aligned.dtype != np.uint16 or aligned.shape != rgb4x.shape[:2]:
        raise ValueError("aligned_ir must be a uint16 plane matching rgb4x")
    if valid.ndim != 2 or valid.shape != aligned.shape or valid.dtype != np.bool_:
        raise ValueError("ir_valid_mask must be a bool plane matching aligned_ir")

    valid_u8 = valid.astype(np.uint8) * np.uint8(255)
    arrays = {
        "rgb4x": rgb4x,
        "rgb1x_proxy": rgb1x_proxy,
        "ir1x": ir1x,
        "aligned_ir": aligned,
        "ir_valid_mask": valid_u8,
    }
    digest = sha256()
    digest.update(f"{_SPLIT_SOURCE_BUNDLE_KIND}:{_SPLIT_SOURCE_BUNDLE_VERSION}:{dpi}".encode("ascii"))
    for role, array in arrays.items():
        _update_array_digest(digest, role, array)
    content_sha256 = digest.hexdigest()
    bundle_name = f"split-source-{content_sha256}"
    root = Path(output_dir).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    target = root / bundle_name
    manifest_path = target / "manifest.json"
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("content_sha256") != content_sha256:
            raise RuntimeError(f"committed bundle {target} has conflicting content")
        _require_committed_bundle_evidence(target, manifest)
        return cast(dict[str, object], manifest)
    if target.exists():
        raise RuntimeError(f"bundle path {target} exists without a committed manifest")

    staging = Path(tempfile.mkdtemp(prefix=f".{bundle_name}.", dir=root))
    filenames = {
        "rgb4x": "rgb4x.tif",
        "rgb1x_proxy": "rgb1x-proxy.tif",
        "ir1x": "ir1x.tif",
        "aligned_ir": "aligned-ir.tif",
        "ir_valid_mask": "ir-valid.tif",
    }
    try:
        for role, array in arrays.items():
            _write_staged_tiff(
                array,
                staging / filenames[role],
                photometric="rgb" if array.ndim == 3 else "minisblack",
                dpi=dpi,
            )
        artifacts = {role: _artifact_evidence(staging / filenames[role]) for role in arrays}
        manifest: dict[str, object] = {
            "version": _SPLIT_SOURCE_BUNDLE_VERSION,
            "kind": _SPLIT_SOURCE_BUNDLE_KIND,
            "content_sha256": content_sha256,
            "bundle_path": bundle_name,
            "dpi": dpi,
            "artifacts": artifacts,
        }
        with (staging / "manifest.json").open("x", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        _fsync_directory(staging)
        os.rename(staging, target)
        _fsync_directory(root)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _commit_tiff_triplet(temporaries: dict[str, str], targets: dict[str, str]) -> None:
    """Commit a prepared RGB/IR/validity triplet with synchronous rollback."""

    roles = ("rgb", "ir", "ir_valid_mask")
    backups: dict[str, str | None] = {role: None for role in roles}
    moved_old: set[str] = set()
    committed_new: set[str] = set()
    try:
        for role in roles:
            target = targets[role]
            if os.path.exists(target):
                backup = _unused_sibling_path(target)
                backups[role] = backup
                os.replace(target, backup)
                moved_old.add(role)
        for role in roles:
            os.replace(temporaries[role], targets[role])
            temporaries[role] = ""
            committed_new.add(role)
    except BaseException as commit_error:
        rollback_errors: list[str] = []
        for role in reversed(roles):
            try:
                backup = backups[role]
                if role in moved_old and backup is not None:
                    os.replace(backup, targets[role])
                elif role in committed_new:
                    _unlink_if_present(targets[role])
            except BaseException as rollback_error:
                rollback_errors.append(f"{targets[role]}: {rollback_error}")
        for role in roles:
            try:
                _unlink_if_present(temporaries[role])
            except BaseException as cleanup_error:
                rollback_errors.append(f"{role} temp: {cleanup_error}")
        for role in roles:
            backup = backups[role]
            if backup is not None and role not in moved_old:
                try:
                    _unlink_if_present(backup)
                except BaseException as cleanup_error:
                    rollback_errors.append(f"{role} backup reservation: {cleanup_error}")
        if rollback_errors:
            raise RuntimeError("TIFF triplet commit failed and rollback was incomplete; " + "; ".join(rollback_errors)) from commit_error
        raise

    for backup in backups.values():
        try:
            _unlink_if_present(backup)
        except OSError as cleanup_error:
            logger.warning(f"Could not remove TIFF transaction backup {backup}: {cleanup_error}")


def write_full_negative_tiff(
    result: ScanResult,
    *,
    ir_valid_mask: np.ndarray,
    path: str | os.PathLike[str],
) -> dict[str, dict[str, object]]:
    """Transactionally persist a full-negative RGB/IR/validity triplet.

    Invalid aligned-IR pixels are written at sensor white so a legacy
    ``ir < threshold`` dust detector cannot mistake a warp border for dust.
    The separate validity TIFF preserves the exact audit mask.
    """

    target = Path(path).expanduser().resolve()
    if target.suffix.lower() not in {".tif", ".tiff"}:
        target = target.with_suffix(".tif")
    target.parent.mkdir(parents=True, exist_ok=True)
    rgb = np.asarray(result.rgb)
    if rgb.ndim != 3 or rgb.shape[2] != 3 or rgb.dtype != np.uint16:
        raise ValueError("full-negative RGB must be a uint16 RGB array")
    if result.ir is None:
        raise ValueError("full-negative output requires aligned IR")
    ir = np.asarray(result.ir)
    valid = np.asarray(ir_valid_mask)
    if ir.ndim != 2 or ir.dtype != np.uint16 or ir.shape != rgb.shape[:2]:
        raise ValueError("full-negative IR must be a uint16 plane matching RGB")
    if valid.ndim != 2 or valid.dtype != np.bool_ or valid.shape != ir.shape:
        raise ValueError("full-negative IR validity must be a bool plane matching IR")
    if type(result.dpi) is not int or result.dpi < 1:
        raise ValueError("full-negative DPI must be a positive integer")

    safe_ir = ir.copy()
    safe_ir[~valid] = np.iinfo(np.uint16).max
    valid_u8 = valid.astype(np.uint8) * np.uint8(255)
    base = target.with_suffix("")
    targets = {
        "rgb": str(target),
        "ir": f"{base}_IR.tif",
        "ir_valid_mask": f"{base}_IR_VALID.tif",
    }
    temporaries: dict[str, str] = {}
    try:
        temporaries["rgb"] = _write_temp_tiff(rgb, targets["rgb"], photometric="rgb", dpi=result.dpi)
        temporaries["ir"] = _write_temp_tiff(safe_ir, targets["ir"], photometric="minisblack", dpi=result.dpi)
        temporaries["ir_valid_mask"] = _write_temp_tiff(
            valid_u8,
            targets["ir_valid_mask"],
            photometric="minisblack",
            dpi=result.dpi,
        )
    except BaseException:
        for temporary in temporaries.values():
            _unlink_if_present(temporary)
        raise

    try:
        evidence = {role: _artifact_evidence(Path(temporary)) for role, temporary in temporaries.items()}
        for role, artifact in evidence.items():
            artifact["path"] = Path(targets[role]).name
    except BaseException:
        for temporary in temporaries.values():
            _unlink_if_present(temporary)
        raise

    _commit_tiff_triplet(temporaries, targets)
    for committed in targets.values():
        _fsync_file(committed)
    _fsync_directory(target.parent)
    return evidence
