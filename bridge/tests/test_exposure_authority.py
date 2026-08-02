from __future__ import annotations

import json
from pathlib import Path

import pytest

from scanstudio_bridge.exposure_authority import (
    ExposureAuthorityRefused,
    _build_exposure_authority,
    build_exposure_authority,
)


def _write_journal(root: Path, slot: int, authority: object) -> None:
    frame = root / "batch-slot03-slot03-test" / f"frame-{slot:03d}"
    frame.mkdir(parents=True)
    (frame / "journal.json").write_text(
        json.dumps({"active_exposure_authority": authority})
    )


def test_exposure_authority_is_best_effort_when_evidence_is_absent(
    tmp_path: Path,
) -> None:
    assert build_exposure_authority(attempts_root=None, slot=3) is None
    assert build_exposure_authority(attempts_root=tmp_path, slot=3) is None


def test_exposure_authority_forwards_the_completed_journal_block(
    tmp_path: Path,
) -> None:
    _write_journal(
        tmp_path,
        3,
        {
            "rgb_source": "nikon-parity-guarded-v2",
            "ir_source": "active-controller",
            "commanded_channels_raw_10ns": {
                "R": 107262,
                "G": 276334,
                "B": 336777,
                "IR": 311725,
            },
            "active_controller_channels_raw_10ns": {
                "R": 121500,
                "G": 276334,
                "B": 340200,
                "IR": 311725,
            },
            "device_bound_clamped_channels_raw_10ns": {"B": 340200},
            "device_exposure_bounds_raw_10ns": [50_000, 400_000],
        },
    )
    result = build_exposure_authority(attempts_root=tmp_path, slot=3)
    assert result is not None
    assert result.rgb_source == "nikon-parity-guarded-v2"
    assert result.commanded_channels_raw_10ns["IR"] == 311725
    assert result.device_bound_clamped_channels_raw_10ns == {"B": 340200}


def test_exposure_authority_rejects_malformed_block_without_escaping(
    tmp_path: Path,
) -> None:
    _write_journal(tmp_path, 3, {"rgb_source": "nikon-parity-guarded-v2"})
    with pytest.raises(ExposureAuthorityRefused, match="malformed"):
        _build_exposure_authority(attempts_root=tmp_path, slot=3)
    assert build_exposure_authority(attempts_root=tmp_path, slot=3) is None
