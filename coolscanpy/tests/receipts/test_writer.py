"""Tests for the split-source-bundle and full-negative-triplet writers.

Split from NegPy's tests/scanners/test_writer.py and test_writer_transactional.py:
write_split_source_bundle/write_full_negative_tiff stayed in
coolscanpy.receipts.writer (only scanning code calls them). write_tiff_16bit/
write_dng_linear moved to coolscanpy.io.encoders instead; see
tests/io/test_encoders.py.
"""

import json

import numpy as np
import pytest
import tifffile

from coolscanpy.session.result import ScanResult, SplitSourceCapture
from coolscanpy.receipts import writer
from coolscanpy.receipts.writer import write_full_negative_tiff, write_split_source_bundle


def test_split_source_bundle_commits_all_planes_with_manifest_evidence(tmp_path) -> None:
    rgb4x = np.arange(7 * 5 * 3, dtype=np.uint16).reshape(7, 5, 3)
    rgb1x_proxy = (rgb4x[:-1] + 100).copy()
    ir1x = np.arange(6 * 5, dtype=np.uint16).reshape(6, 5)
    aligned_ir = np.pad(ir1x, ((0, 1), (0, 0)), constant_values=123)
    ir_valid_mask = np.ones((7, 5), dtype=bool)
    ir_valid_mask[-1] = False

    manifest = write_split_source_bundle(
        SplitSourceCapture(
            rgb4x=rgb4x,
            rgb1x_proxy=rgb1x_proxy,
            ir1x=ir1x,
        ),
        aligned_ir=aligned_ir,
        ir_valid_mask=ir_valid_mask,
        output_dir=tmp_path,
        dpi=4000,
    )

    assert manifest["version"] == 1
    assert manifest["kind"] == "negpy.full-negative-split-source"
    assert len(manifest["content_sha256"]) == 64
    assert set(manifest["artifacts"]) == {
        "rgb4x",
        "rgb1x_proxy",
        "ir1x",
        "aligned_ir",
        "ir_valid_mask",
    }
    bundle_path = tmp_path / manifest["bundle_path"]
    assert (bundle_path / "manifest.json").is_file()
    for role, evidence in manifest["artifacts"].items():
        artifact_path = bundle_path / evidence["path"]
        assert artifact_path.is_file(), role
        assert len(evidence["sha256"]) == 64
        assert evidence["bytes"] == artifact_path.stat().st_size
        assert evidence["page_count"] == 1
        assert evidence["payload_within_file"] is True
        assert evidence["x_resolution"] == [4000, 1]
        assert evidence["y_resolution"] == [4000, 1]
        assert evidence["resolution_unit"] == "INCH"
    assert manifest["artifacts"]["rgb4x"]["shape"] == [7, 5, 3]
    assert manifest["artifacts"]["rgb4x"]["dtype"] == "uint16"
    assert manifest["artifacts"]["ir_valid_mask"]["shape"] == [7, 5]
    assert manifest["artifacts"]["ir_valid_mask"]["dtype"] == "uint8"


def test_split_source_bundle_repeat_is_content_addressed_and_idempotent(tmp_path) -> None:
    source = SplitSourceCapture(
        rgb4x=np.full((7, 5, 3), 1000, dtype=np.uint16),
        rgb1x_proxy=np.full((6, 5, 3), 1100, dtype=np.uint16),
        ir1x=np.full((6, 5), 1200, dtype=np.uint16),
    )
    aligned_ir = np.full((7, 5), 1300, dtype=np.uint16)
    valid = np.ones((7, 5), dtype=bool)

    first = write_split_source_bundle(
        source,
        aligned_ir=aligned_ir,
        ir_valid_mask=valid,
        output_dir=tmp_path,
        dpi=4000,
    )
    bundle_path = tmp_path / first["bundle_path"]
    mtimes = {path.name: path.stat().st_mtime_ns for path in bundle_path.iterdir()}

    second = write_split_source_bundle(
        source,
        aligned_ir=aligned_ir,
        ir_valid_mask=valid,
        output_dir=tmp_path,
        dpi=4000,
    )

    assert second == first
    assert [path.name for path in tmp_path.iterdir()] == [first["bundle_path"]]
    assert {path.name: path.stat().st_mtime_ns for path in bundle_path.iterdir()} == mtimes


def test_split_source_bundle_never_overwrites_a_conflicting_commit(tmp_path) -> None:
    source = SplitSourceCapture(
        rgb4x=np.full((7, 5, 3), 2000, dtype=np.uint16),
        rgb1x_proxy=np.full((6, 5, 3), 2100, dtype=np.uint16),
        ir1x=np.full((6, 5), 2200, dtype=np.uint16),
    )
    aligned_ir = np.full((7, 5), 2300, dtype=np.uint16)
    valid = np.ones((7, 5), dtype=bool)
    committed = write_split_source_bundle(
        source,
        aligned_ir=aligned_ir,
        ir_valid_mask=valid,
        output_dir=tmp_path,
        dpi=4000,
    )
    bundle_path = tmp_path / committed["bundle_path"]
    manifest_path = bundle_path / "manifest.json"
    conflicting = json.loads(manifest_path.read_text(encoding="utf-8"))
    conflicting["content_sha256"] = "0" * 64
    manifest_path.write_text(json.dumps(conflicting), encoding="utf-8")
    artifact_bytes = {path.name: path.read_bytes() for path in bundle_path.iterdir() if path.name != "manifest.json"}

    with pytest.raises(RuntimeError, match="conflicting content"):
        write_split_source_bundle(
            source,
            aligned_ir=aligned_ir,
            ir_valid_mask=valid,
            output_dir=tmp_path,
            dpi=4000,
        )

    assert json.loads(manifest_path.read_text(encoding="utf-8"))["content_sha256"] == "0" * 64
    assert {path.name: path.read_bytes() for path in bundle_path.iterdir() if path.name != "manifest.json"} == artifact_bytes


def test_split_source_bundle_refuses_a_tampered_committed_artifact(tmp_path) -> None:
    source = SplitSourceCapture(
        rgb4x=np.full((7, 5, 3), 3000, dtype=np.uint16),
        rgb1x_proxy=np.full((6, 5, 3), 3100, dtype=np.uint16),
        ir1x=np.full((6, 5), 3200, dtype=np.uint16),
    )
    aligned_ir = np.full((7, 5), 3300, dtype=np.uint16)
    valid = np.ones((7, 5), dtype=bool)
    committed = write_split_source_bundle(
        source,
        aligned_ir=aligned_ir,
        ir_valid_mask=valid,
        output_dir=tmp_path,
        dpi=4000,
    )
    bundle_path = tmp_path / committed["bundle_path"]
    rgb_path = bundle_path / committed["artifacts"]["rgb4x"]["path"]
    tifffile.imwrite(
        rgb_path,
        np.zeros((7, 5, 3), dtype=np.uint16),
        photometric="rgb",
        resolution=(4000, 4000),
        resolutionunit="INCH",
    )
    tampered_bytes = rgb_path.read_bytes()

    with pytest.raises(RuntimeError, match="artifact evidence"):
        write_split_source_bundle(
            source,
            aligned_ir=aligned_ir,
            ir_valid_mask=valid,
            output_dir=tmp_path,
            dpi=4000,
        )

    assert rgb_path.read_bytes() == tampered_bytes


def test_full_negative_writer_commits_rgb_sanitized_ir_and_validity_evidence(tmp_path) -> None:
    rgb = np.arange(7 * 5 * 3, dtype=np.uint16).reshape(7, 5, 3)
    ir = np.arange(7 * 5, dtype=np.uint16).reshape(7, 5)
    valid = np.ones((7, 5), dtype=bool)
    valid[0, 0] = False
    valid[-1] = False

    evidence = write_full_negative_tiff(
        ScanResult(rgb=rgb, ir=ir, dpi=4000, device_model="Nikon LS-5000"),
        ir_valid_mask=valid,
        path=tmp_path / "frame003.tif",
    )

    assert set(evidence) == {"rgb", "ir", "ir_valid_mask"}
    for role, artifact in evidence.items():
        artifact_path = tmp_path / artifact["path"]
        assert artifact_path.is_file(), role
        assert len(artifact["sha256"]) == 64
        assert artifact["bytes"] == artifact_path.stat().st_size
        assert artifact["x_resolution"] == [4000, 1]
        assert artifact["y_resolution"] == [4000, 1]
        assert artifact["resolution_unit"] == "INCH"
    np.testing.assert_array_equal(tifffile.imread(tmp_path / "frame003.tif"), rgb)
    saved_ir = tifffile.imread(tmp_path / "frame003_IR.tif")
    np.testing.assert_array_equal(saved_ir[valid], ir[valid])
    assert np.all(saved_ir[~valid] == np.iinfo(np.uint16).max)
    np.testing.assert_array_equal(
        tifffile.imread(tmp_path / "frame003_IR_VALID.tif"),
        valid.astype(np.uint8) * 255,
    )
    assert evidence["rgb"]["shape"] == [7, 5, 3]
    assert evidence["ir"]["shape"] == [7, 5]
    assert evidence["ir_valid_mask"]["dtype"] == "uint8"


def test_full_negative_evidence_failure_preserves_existing_triplet(monkeypatch, tmp_path) -> None:
    rgb_path = tmp_path / "frame003.tif"
    ir_path = tmp_path / "frame003_IR.tif"
    valid_path = tmp_path / "frame003_IR_VALID.tif"
    old_rgb = np.full((7, 5, 3), 1111, dtype=np.uint16)
    old_ir = np.full((7, 5), 2222, dtype=np.uint16)
    old_valid = np.full((7, 5), 255, dtype=np.uint8)
    tifffile.imwrite(rgb_path, old_rgb, photometric="rgb")
    tifffile.imwrite(ir_path, old_ir, photometric="minisblack")
    tifffile.imwrite(valid_path, old_valid, photometric="minisblack")

    real_inspect = writer.inspect_tiff_payload
    calls = 0

    def fail_third_inspection(path):
        nonlocal calls
        calls += 1
        if calls == 3:
            raise OSError("simulated validity evidence failure")
        return real_inspect(path)

    monkeypatch.setattr(writer, "inspect_tiff_payload", fail_third_inspection)
    new_rgb = np.full((7, 5, 3), 3333, dtype=np.uint16)
    new_ir = np.full((7, 5), 4444, dtype=np.uint16)
    result = ScanResult(rgb=new_rgb, ir=new_ir, dpi=4000, device_model="Nikon LS-5000")

    with pytest.raises(OSError, match="validity evidence failure"):
        write_full_negative_tiff(
            result,
            ir_valid_mask=np.ones((7, 5), dtype=bool),
            path=rgb_path,
        )

    np.testing.assert_array_equal(tifffile.imread(rgb_path), old_rgb)
    np.testing.assert_array_equal(tifffile.imread(ir_path), old_ir)
    np.testing.assert_array_equal(tifffile.imread(valid_path), old_valid)
    assert sorted(path.name for path in tmp_path.iterdir()) == [
        "frame003.tif",
        "frame003_IR.tif",
        "frame003_IR_VALID.tif",
    ]


@pytest.mark.parametrize("failed_replace", range(1, 7))
def test_full_negative_triplet_survives_each_commit_rename_failure(
    monkeypatch,
    tmp_path,
    failed_replace: int,
) -> None:
    rgb_path = tmp_path / "frame003.tif"
    ir_path = tmp_path / "frame003_IR.tif"
    valid_path = tmp_path / "frame003_IR_VALID.tif"
    old_rgb = np.full((7, 5, 3), 1111, dtype=np.uint16)
    old_ir = np.full((7, 5), 2222, dtype=np.uint16)
    old_valid = np.full((7, 5), 255, dtype=np.uint8)
    tifffile.imwrite(rgb_path, old_rgb, photometric="rgb")
    tifffile.imwrite(ir_path, old_ir, photometric="minisblack")
    tifffile.imwrite(valid_path, old_valid, photometric="minisblack")

    real_replace = writer.os.replace
    calls = 0

    def fail_selected_replace(src, dst) -> None:
        nonlocal calls
        calls += 1
        if calls == failed_replace:
            raise OSError(f"simulated triplet commit rename {failed_replace} failure")
        real_replace(src, dst)

    monkeypatch.setattr(writer.os, "replace", fail_selected_replace)
    result = ScanResult(
        rgb=np.full((7, 5, 3), 3333, dtype=np.uint16),
        ir=np.full((7, 5), 4444, dtype=np.uint16),
        dpi=4000,
        device_model="Nikon LS-5000",
    )

    with pytest.raises(OSError, match=f"triplet commit rename {failed_replace} failure"):
        write_full_negative_tiff(
            result,
            ir_valid_mask=np.ones((7, 5), dtype=bool),
            path=rgb_path,
        )

    np.testing.assert_array_equal(tifffile.imread(rgb_path), old_rgb)
    np.testing.assert_array_equal(tifffile.imread(ir_path), old_ir)
    np.testing.assert_array_equal(tifffile.imread(valid_path), old_valid)
    assert sorted(path.name for path in tmp_path.iterdir()) == [
        "frame003.tif",
        "frame003_IR.tif",
        "frame003_IR_VALID.tif",
    ]
