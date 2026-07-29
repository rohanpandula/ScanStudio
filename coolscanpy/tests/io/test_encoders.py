"""Tests for the low-level TIFF/DNG fs encoders.

Split from NegPy's tests/scanners/test_writer.py and test_writer_transactional.py:
write_tiff_16bit/write_dng_linear (and the fs-transaction helpers they use)
moved to coolscanpy.io.encoders per M1 (the SHARED writer.py split — these two
functions are also reused by NegPy's unrelated "flat master" DNG export, so
they were hoisted into a small, dependency-free module both sides can import
without a domain-type coupling). write_split_source_bundle/write_full_negative_tiff
stayed in coolscanpy.receipts.writer; see tests/receipts/test_writer.py.
"""

import os
import tempfile

import numpy as np
import pytest
import tifffile

from coolscanpy.session.result import ScanResult
from coolscanpy.io import encoders
from coolscanpy.io.encoders import write_dng_linear, write_tiff_16bit


class TestTiffWriter:
    def test_writes_16bit_tiff(self) -> None:
        rgb = np.random.randint(0, 65535, (200, 300, 3), dtype=np.uint16)
        result = ScanResult(rgb=rgb, ir=None, dpi=3600, device_model="TestScanner")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_tiff_16bit(result, os.path.join(tmpdir, "test_scan"))
            assert os.path.exists(path)
            assert path.endswith(".tif")

            # Round-trip readback
            readback = tifffile.imread(path)
            assert readback.shape == (200, 300, 3)
            assert readback.dtype == np.uint16

    def test_writes_ir_sidecar(self) -> None:
        rgb = np.random.randint(0, 65535, (100, 150, 3), dtype=np.uint16)
        ir = np.random.randint(0, 65535, (100, 150), dtype=np.uint16)
        result = ScanResult(rgb=rgb, ir=ir, dpi=3600, device_model="TestScanner")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_tiff_16bit(result, os.path.join(tmpdir, "test_ir"))
            ir_path = path.replace(".tif", "_IR.tif")
            assert os.path.exists(path)
            assert os.path.exists(ir_path)

            ir_readback = tifffile.imread(ir_path)
            assert ir_readback.shape == (100, 150)

    def test_adds_tif_extension(self) -> None:
        rgb = np.random.randint(0, 255, (50, 50, 3), dtype=np.uint8)
        result = ScanResult(rgb=rgb, ir=None, dpi=300, device_model="T")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_tiff_16bit(result, os.path.join(tmpdir, "noext"))
            assert path.endswith(".tif")

    def test_converts_non_uint16(self) -> None:
        rgb = np.random.randint(0, 255, (50, 50, 3), dtype=np.uint8)
        result = ScanResult(rgb=rgb, ir=None, dpi=300, device_model="T")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_tiff_16bit(result, os.path.join(tmpdir, "test8"))
            readback = tifffile.imread(path)
            assert readback.dtype == np.uint16


class TestDngWriter:
    def test_writes_linear_dng(self) -> None:
        rgb = np.random.randint(0, 65535, (200, 300, 3), dtype=np.uint16)
        result = ScanResult(rgb=rgb, ir=None, dpi=3600, device_model="TestScanner")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_dng_linear(result, os.path.join(tmpdir, "test_scan"))
            assert os.path.exists(path)
            assert path.endswith(".dng")

            readback = tifffile.imread(path)
            assert readback.shape == (200, 300, 3)
            assert readback.dtype == np.uint16
            np.testing.assert_array_equal(readback, rgb)

            with tifffile.TiffFile(path) as tf:
                tags = tf.pages[0].tags
                assert int(tags["PhotometricInterpretation"].value) == 34892  # LinearRaw
                assert tuple(tags["DNGVersion"].value) == (1, 4, 0, 0)
                assert int(tags["SamplesPerPixel"].value) == 3
                # 3 plain colour samples, no ExtraSamples (matches pidng); marking colour
                # planes as extra makes some raw processors mis-demosaic the file.
                assert tags.get("ExtraSamples") is None

    def test_writes_dng_with_ir(self) -> None:
        rgb = np.random.randint(0, 65535, (100, 150, 3), dtype=np.uint16)
        ir = np.random.randint(0, 65535, (100, 150), dtype=np.uint16)
        result = ScanResult(rgb=rgb, ir=ir, dpi=3600, device_model="TestScanner")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_dng_linear(result, os.path.join(tmpdir, "test_ir"))
            assert os.path.exists(path)

            readback = tifffile.imread(path)
            assert readback.shape == (100, 150, 4)
            np.testing.assert_array_equal(readback[:, :, :3], rgb)
            np.testing.assert_array_equal(readback[:, :, 3], ir)
            with tifffile.TiffFile(path) as tf:
                assert int(tf.pages[0].tags["SamplesPerPixel"].value) == 4

    def test_adds_dng_extension(self) -> None:
        rgb = np.random.randint(0, 65535, (50, 50, 3), dtype=np.uint16)
        result = ScanResult(rgb=rgb, ir=None, dpi=300, device_model="T")

        with tempfile.TemporaryDirectory() as tmpdir:
            path = write_dng_linear(result, os.path.join(tmpdir, "noext"))
            assert path.endswith(".dng")


def _result(with_ir: bool = True) -> ScanResult:
    rgb = np.random.randint(0, 65535, (20, 30, 3), dtype=np.uint16)
    ir = np.random.randint(0, 65535, (20, 30), dtype=np.uint16) if with_ir else None
    return ScanResult(rgb=rgb, ir=ir, dpi=1200, device_model="TestScanner")


def test_backup_name_stays_reserved_until_atomic_replace(tmp_path) -> None:
    target = tmp_path / "frame.tif"
    target.write_bytes(b"old scan")

    backup = encoders._unused_sibling_path(str(target))
    try:
        assert os.path.exists(backup)
        assert os.path.getsize(backup) == 0
    finally:
        encoders._unlink_if_present(backup)


class TestIrFailureAfterRgbSucceeds:
    """monkeypatch tifffile.imwrite to fail on the 2nd call (the IR write),
    simulating a disk/codec failure after the RGB payload already succeeded."""

    def test_no_orphan_rgb_left_when_ir_write_fails(self, monkeypatch) -> None:
        real_imwrite = tifffile.imwrite
        calls = {"n": 0}

        def flaky_imwrite(*args, **kwargs):
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError("simulated disk failure writing IR sidecar")
            return real_imwrite(*args, **kwargs)

        monkeypatch.setattr(tifffile, "imwrite", flaky_imwrite)

        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "frame001")
            result = _result(with_ir=True)

            with pytest.raises(Exception):
                write_tiff_16bit(result, path)

            # Archival invariant: no silent RGB-without-IR. The API already
            # surfaces a clear failure (the raise above); on top of that, no
            # orphan RGB may be left looking like a complete, valid scan.
            rgb_path = path + ".tif"
            ir_path = path + "_IR.tif"
            assert not os.path.exists(ir_path)
            assert not os.path.exists(rgb_path), (
                "IR write failed after RGB succeeded but the orphan RGB file was left on disk with no indication its IR channel is missing"
            )
            # No temp files left behind either.
            assert os.listdir(tmpdir) == []

    def test_existing_pair_survives_ir_commit_failure(self, monkeypatch, tmp_path) -> None:
        """Replacing a complete scan must not sacrifice it for a partial update."""
        rgb_path = tmp_path / "frame.tif"
        ir_path = tmp_path / "frame_IR.tif"
        old_rgb = np.full((7, 9, 3), 1111, dtype=np.uint16)
        old_ir = np.full((7, 9), 2222, dtype=np.uint16)
        tifffile.imwrite(rgb_path, old_rgb, photometric="rgb")
        tifffile.imwrite(ir_path, old_ir, photometric="minisblack")

        real_replace = encoders.os.replace
        failed = False

        def fail_first_ir_commit(src, dst) -> None:
            nonlocal failed
            if os.fspath(dst) == os.fspath(ir_path) and not failed:
                failed = True
                raise OSError("simulated IR commit failure")
            real_replace(src, dst)

        monkeypatch.setattr(encoders.os, "replace", fail_first_ir_commit)

        with pytest.raises(OSError, match="IR commit failure"):
            write_tiff_16bit(_result(with_ir=True), str(rgb_path))

        assert np.array_equal(tifffile.imread(rgb_path), old_rgb)
        assert np.array_equal(tifffile.imread(ir_path), old_ir)
        assert sorted(path.name for path in tmp_path.iterdir()) == ["frame.tif", "frame_IR.tif"]

    @pytest.mark.parametrize("failed_replace", (1, 2, 3, 4))
    def test_existing_pair_survives_failure_at_each_commit_rename(
        self,
        monkeypatch,
        tmp_path,
        failed_replace: int,
    ) -> None:
        rgb_path = tmp_path / "frame.tif"
        ir_path = tmp_path / "frame_IR.tif"
        old_rgb = np.full((7, 9, 3), 3333, dtype=np.uint16)
        old_ir = np.full((7, 9), 4444, dtype=np.uint16)
        tifffile.imwrite(rgb_path, old_rgb, photometric="rgb")
        tifffile.imwrite(ir_path, old_ir, photometric="minisblack")

        real_replace = encoders.os.replace
        calls = 0

        def fail_selected_replace(src, dst) -> None:
            nonlocal calls
            calls += 1
            if calls == failed_replace:
                raise OSError(f"simulated commit rename {failed_replace} failure")
            real_replace(src, dst)

        monkeypatch.setattr(encoders.os, "replace", fail_selected_replace)

        with pytest.raises(OSError, match=f"commit rename {failed_replace} failure"):
            write_tiff_16bit(_result(with_ir=True), str(rgb_path))

        assert np.array_equal(tifffile.imread(rgb_path), old_rgb)
        assert np.array_equal(tifffile.imread(ir_path), old_ir)
        assert sorted(path.name for path in tmp_path.iterdir()) == ["frame.tif", "frame_IR.tif"]

    def test_rgb_write_failure_leaves_nothing(self, monkeypatch) -> None:
        """Sanity companion: a failure on the *first* (RGB) write must also
        leave no partial file — the baseline the IR-failure case above is
        held to."""

        def failing_imwrite(*args, **kwargs):
            raise OSError("simulated disk failure writing RGB")

        monkeypatch.setattr(tifffile, "imwrite", failing_imwrite)

        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "frame002")
            result = _result(with_ir=True)

            with pytest.raises(Exception):
                write_tiff_16bit(result, path)

            assert os.listdir(tmpdir) == []


class TestStaleIrSidecar:
    """A stale `_IR.tif` from a previous IR-enabled write of the same target
    must not be silently left next to a fresh IR-less RGB write."""

    def test_stale_sidecar_removed_when_new_write_has_no_ir(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "frame003")
            rgb_path = path + ".tif"
            ir_path = path + "_IR.tif"

            # Leftover IR sidecar from an earlier, unrelated write.
            stale_ir = np.random.randint(0, 65535, (99, 77), dtype=np.uint16)
            tifffile.imwrite(ir_path, stale_ir, photometric="minisblack")
            assert os.path.exists(ir_path)

            result = _result(with_ir=False)
            returned_path = write_tiff_16bit(result, path)

            assert returned_path == rgb_path
            assert os.path.exists(rgb_path)
            assert not os.path.exists(ir_path), (
                "stale _IR.tif sidecar survived a fresh IR-less write of the same target — a downstream loader would misattribute it"
            )

    def test_fresh_ir_overwrites_stale_sidecar(self) -> None:
        """When the new write DOES have IR, it should simply overwrite the
        stale sidecar with its own (correctly paired) data."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "frame004")
            ir_path = path + "_IR.tif"

            stale_ir = np.zeros((5, 5), dtype=np.uint16)
            tifffile.imwrite(ir_path, stale_ir, photometric="minisblack")

            result = _result(with_ir=True)
            write_tiff_16bit(result, path)

            readback = tifffile.imread(ir_path)
            assert readback.shape == result.ir.shape
            assert np.array_equal(readback, result.ir)


def test_dpi_metadata_written(tmp_path):
    rgb = np.zeros((8, 6, 3), dtype=np.uint16)
    ir = np.zeros((8, 6), dtype=np.uint16)
    out = write_tiff_16bit(ScanResult(rgb=rgb, ir=ir, dpi=4000, device_model="t"), str(tmp_path / "f.tif"))
    for f in (out, str(tmp_path / "f_IR.tif")):
        with tifffile.TiffFile(f) as t:
            xres = t.pages[0].tags["XResolution"].value
            assert xres[0] / xres[1] == 4000, f"{f}: XResolution {xres}"
            assert t.pages[0].tags["ResolutionUnit"].value == 2  # INCH
