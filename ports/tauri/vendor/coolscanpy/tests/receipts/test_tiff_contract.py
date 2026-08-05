"""Writer-side half of NegPy's tests/test_tiff_linear_scanner_contract.py.

The source test round-trips through NegPy's TiffLoader (reader) to prove the
private-tag contract holds end to end. Every one of its test functions reads
the TIFF back through TiffLoader, a NEGPY-only component, so none of them
port verbatim. This file instead covers the writer side alone (self-contained,
no reader involved): that write_tiff_16bit/write_full_negative_tiff correctly
stamp LINEAR_SCANNER_RGB_TAG on scanner-native output and never on an ordinary
untagged TIFF or the full-negative IR/validity sidecars. NegPy keeps the other
half (does TiffLoader correctly decode a pycoolscan-written TIFF).
"""

from __future__ import annotations

from typing import cast

import numpy as np
import tifffile

from coolscanpy.session.result import ScanResult
from coolscanpy.receipts.tiff_contract import (
    LINEAR_SCANNER_RGB_MARKER,
    LINEAR_SCANNER_RGB_TAG,
    has_linear_scanner_rgb_marker,
)
from coolscanpy.receipts.writer import write_full_negative_tiff
from coolscanpy.io.encoders import write_tiff_16bit


def test_write_tiff_16bit_stamps_the_linear_scanner_rgb_marker(tmp_path) -> None:
    rgb = np.arange(6 * 8 * 3, dtype=np.uint16).reshape(6, 8, 3)
    result = ScanResult(rgb=rgb, ir=None, dpi=4000, device_model="Nikon LS-5000")

    path = write_tiff_16bit(result, str(tmp_path / "frame001.tif"))

    with tifffile.TiffFile(path) as tif:
        page = cast(tifffile.TiffPage, tif.pages[0])
        assert page.tags[LINEAR_SCANNER_RGB_TAG].value == LINEAR_SCANNER_RGB_MARKER
        assert has_linear_scanner_rgb_marker(page.tags)


def test_ordinary_untagged_tiff_has_no_linear_scanner_rgb_marker(tmp_path) -> None:
    rgb = np.full((3, 4, 3), 32768, dtype=np.uint16)
    path = tmp_path / "ordinary.tif"
    tifffile.imwrite(path, rgb, photometric="rgb")

    with tifffile.TiffFile(path) as tif:
        page = cast(tifffile.TiffPage, tif.pages[0])
        assert page.tags.get(LINEAR_SCANNER_RGB_TAG) is None
        assert not has_linear_scanner_rgb_marker(page.tags)


def test_write_full_negative_tiff_stamps_rgb_only_not_ir_sidecars(tmp_path) -> None:
    rgb = np.arange(6 * 8 * 3, dtype=np.uint16).reshape(6, 8, 3) * np.uint16(313)
    ir = np.arange(6 * 8, dtype=np.uint16).reshape(6, 8) * np.uint16(997)
    valid = np.ones((6, 8), dtype=np.bool_)
    valid[0, 0] = False
    valid[-1, -1] = False
    rgb_path = tmp_path / "frame003.tif"

    write_full_negative_tiff(
        ScanResult(rgb=rgb, ir=ir, dpi=4000, device_model="Nikon LS-5000"),
        ir_valid_mask=valid,
        path=rgb_path,
    )

    with tifffile.TiffFile(rgb_path) as tif:
        page = cast(tifffile.TiffPage, tif.pages[0])
        assert has_linear_scanner_rgb_marker(page.tags)
    for sidecar in (tmp_path / "frame003_IR.tif", tmp_path / "frame003_IR_VALID.tif"):
        with tifffile.TiffFile(sidecar) as tif:
            page = cast(tifffile.TiffPage, tif.pages[0])
            assert not has_linear_scanner_rgb_marker(page.tags)
