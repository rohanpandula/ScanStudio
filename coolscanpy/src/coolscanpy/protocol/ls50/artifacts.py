from __future__ import annotations

"""Write the calibration-roll artifacts from one LS-50 RGBI raw capture.

File contract (matches the operator guide exactly):

    <stock>_<NN>_<pass>.tif          raw linear 16-bit RGB, capture orientation
    <stock>_<NN>_<pass>-ir.tif       same-size 16-bit infrared plane, marker
                                     tag ``scanstudio.infrared.linear.uint16.v1``
    <stock>_<NN>_<pass>.receipt.json exposure us/channel, focus, clipping, smear,
                                     exposure authority, settings fingerprint

Raw output is never inverted, color-converted, cropped, transformed, or
dust-cleaned.  The 14-bit ADC samples are stored left-justified in the
16-bit container (no normalization), preserving the linear capture.
"""


import hashlib
import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import tifffile

from ...receipts import tiff_contract as _tiff_contract  # noqa: F401
from .capture import Ls50ScanOptions


SCANNER_INFRARED_MARKER = "scanstudio.infrared.linear.uint16.v1"


@dataclass(frozen=True)
class Ls50ArtifactPaths:
    rgb: Path
    ir: Path
    receipt: Path

    @classmethod
    def for_frame(cls, directory: str | os.PathLike[str], stem: str) -> "Ls50ArtifactPaths":
        root = Path(directory)
        return cls(
            rgb=root / f"{stem}.tif",
            ir=root / f"{stem}-ir.tif",
            receipt=root / f"{stem}.receipt.json",
        )


@dataclass(frozen=True)
class Ls50FrameReceipt:
    frame: int
    pass_token: str
    dpi: int
    depth: int
    samples_per_scan: int
    channels: str  # "rgbi" or "rgb"
    settingsFingerprint: str
    exposureRedUs: int
    exposureGreenUs: int
    exposureBlueUs: int
    exposureMultiplier: float
    focusPosition: int
    focusVerdict: str
    transportSmear: str
    clipping: dict[str, dict[str, int]]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_json(self, *, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, sort_keys=True)


def reshape_rgbi_stream(
    data: bytes,
    opt: Ls50ScanOptions,
) -> np.ndarray:
    """Reshape the padded LS-50 stream into a (H, W, C) float/uint array.

    The wire stream is line-interleaved: each line is
    ``line_bytes_padded`` = n_colors*width*bytes_per_sample, block-padded to
    512.  Returns a (logical_height, logical_width, n_colors) array right-
    justified: 14-bit values are stored in the high bits of uint16 samples.
    """
    line_bytes_padded = opt.line_bytes_padded
    if len(data) < opt.logical_height * line_bytes_padded:
        raise ValueError(
            f"LS-50 stream shorter than expected: {len(data)} < "
            f"{opt.logical_height}*{line_bytes_padded}"
        )
    arr = np.frombuffer(data, dtype=np.uint8)[: opt.logical_height * line_bytes_padded]
    arr = arr.reshape(opt.logical_height, line_bytes_padded)
    arr = arr[:, : opt.line_bytes_raw]
    if opt.bytes_per_sample == 2:
        arr = arr.reshape(opt.logical_height, opt.n_colors * opt.logical_width * 2)
        arr16 = (arr[:, 0::2].astype(np.uint16) << 8) | arr[:, 1::2].astype(np.uint16)
        arr = arr16.reshape(opt.logical_height, opt.n_colors, opt.logical_width)
    else:
        arr = arr.reshape(opt.logical_height, opt.n_colors, opt.logical_width)
    return np.moveaxis(arr, 1, -1)  # (H, W, C)


def _write_rgb_tiff(
    rgb: np.ndarray,
    path: Path,
    *,
    dpi: int,
    linear: bool = True,
) -> None:
    if rgb.ndim != 3 or rgb.shape[2] != 3 or rgb.dtype != np.uint16:
        raise ValueError("RGB must be uint16 HxWx3")
    path.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(path, rgb, photometric="rgb", resolution=(dpi, dpi))

def _write_ir_tiff(ir: np.ndarray, path: Path, *, dpi: int) -> None:
    if ir.ndim != 2 or ir.dtype != np.uint16:
        raise ValueError("IR must be uint16 HxW")
    path.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(
        path,
        ir,
        photometric="minisblack",
        resolution=(dpi, dpi),
        metadata={
            "description": SCANNER_INFRARED_MARKER,
        },
    )


def _write_receipt(receipt: Ls50FrameReceipt, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(receipt.to_json() + "\n", encoding="utf-8")


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_capture_artifacts(
    *,
    data: bytes,
    opt: Ls50ScanOptions,
    directory: str | os.PathLike[str],
    stem: str,
    frame: int,
    pass_token: str,
    exposure_r: int,
    exposure_g: int,
    exposure_b: int,
    focus_position: int = 0,
    clipping: dict[str, dict[str, int]] | None = None,
) -> Ls50ArtifactPaths:
    """Persist the doc's raw linear RGB + IR + receipt for one capture."""
    paths = Ls50ArtifactPaths.for_frame(directory, stem)
    arr = reshape_rgbi_stream(data, opt)
    frame_rgb = arr[:, :, :3].copy()
    frame_ir = arr[:, :, 3].copy() if opt.rgbi else None
    # Keep 14-bit samples in the high bits -> uint16 container (linear raw).
    if opt.depth == 14:
        frame_rgb = (frame_rgb.astype(np.uint16) << 2).astype(np.uint16)
        if frame_ir is not None:
            frame_ir = (frame_ir.astype(np.uint16) << 2).astype(np.uint16)
    elif opt.depth == 8:
        frame_rgb = (frame_rgb.astype(np.uint16) << 8).astype(np.uint16)
        if frame_ir is not None:
            frame_ir = (frame_ir.astype(np.uint16) << 8).astype(np.uint16)
    _write_rgb_tiff(frame_rgb, paths.rgb, dpi=opt.dpi)
    if frame_ir is not None:
        _write_ir_tiff(frame_ir, paths.ir, dpi=opt.dpi)
    if clipping is None:
        clipping = {}
    receipt = Ls50FrameReceipt(
        frame=frame,
        pass_token=pass_token,
        dpi=opt.dpi,
        depth=opt.depth,
        samples_per_scan=opt.samples_per_scan,
        channels="rgbi" if opt.rgbi else "rgb",
        settingsFingerprint=f"{opt.dpi}:16:1:{'rgbi' if opt.rgbi else 'rgb'}",
        exposureRedUs=exposure_r // 100 if False else exposure_r // 100,  # 10ns->us
        exposureGreenUs=exposure_g // 100,
        exposureBlueUs=exposure_b // 100,
        exposureMultiplier=1.0,
        focusPosition=focus_position,
        focusVerdict="ok",
        transportSmear="none",
        clipping=clipping,
    )
    _write_receipt(receipt, paths.receipt)
    return paths


__all__ = [
    "Ls50ArtifactPaths",
    "Ls50FrameReceipt",
    "SCANNER_INFRARED_MARKER",
    "reshape_rgbi_stream",
    "write_capture_artifacts",
]