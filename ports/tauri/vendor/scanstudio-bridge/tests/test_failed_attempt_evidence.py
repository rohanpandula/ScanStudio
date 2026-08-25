"""Share-safe, immutable evidence for failed preview and scan binding attempts."""

from __future__ import annotations

import json
import stat
from pathlib import Path

import pytest

from coolscanpy.protocol.ls5000_single_pass.roll_index import IndexDecodeError
from scanstudio_bridge.failed_attempt_evidence import (
    EvidencePublicationError,
    publish_index_failure,
)


def _affine_error(residuals: tuple[float, ...]) -> IndexDecodeError:
    mean_absolute = sum(abs(value) for value in residuals) / len(residuals)
    maximum = max(abs(value) for value in residuals)
    return IndexDecodeError(
        "transport anchor residual is inconsistent with one affine preview traversal",
        error_id="transport-affine-residual",
        diagnostics={
            "kind": "affine",
            "anchors": [
                {
                    "ordinal": ordinal,
                    "input_row": ordinal * 10.0,
                    "observed_row": ordinal * 420.0 - residual * 42.0,
                    "fitted_row": ordinal * 420.0,
                    "residual_rows": residual,
                }
                for ordinal, residual in enumerate(residuals)
            ],
            "transform": {"slope": 42.0, "intercept": 0.0},
            "thresholds": {
                "maximum_mean_absolute_residual_rows": 1.0,
                "maximum_residual_rows": 2.0,
            },
            "mean_absolute_residual_rows": mean_absolute,
            "maximum_residual_rows": maximum,
        },
    )


def test_affine_failure_publication_matches_engine_source_schema_and_is_bounded(
    tmp_path: Path,
) -> None:
    evidence = publish_index_failure(
        _affine_error((3.005, 0.2, 0.2, 0.2, 0.137, 0.2)),
        base_dir=tmp_path,
        holder_capacity=40,
        evidence_id_factory=lambda: "evidence-42-affine",
    )

    assert evidence["schemaVersion"] == 1
    assert evidence["evidenceId"] == "evidence-42-affine"
    assert evidence["witness"]["kind"] == "affine"
    assert evidence["witness"]["holderCapacity"] == 40
    assert evidence["witness"]["meanAbsoluteResidualRows"] == pytest.approx(0.657)
    assert evidence["witness"]["maximumResidualRows"] == pytest.approx(3.005)
    assert len(json.dumps(evidence, separators=(",", ":")).encode()) <= 16 * 1024

    path = tmp_path / "failed-attempt-evidence" / "evidence-42-affine.json"
    assert json.loads(path.read_text(encoding="utf-8")) == evidence
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    serialized = json.dumps(evidence, sort_keys=True).lower()
    for forbidden in (
        "operationid",
        "sessionepoch",
        "builds",
        "device",
        "path",
        "serial",
        "raw",
        "pixel",
        "sha",
        "project",
    ):
        assert forbidden not in serialized


def test_publication_is_create_only_and_collision_keeps_original_bytes(
    tmp_path: Path,
) -> None:
    first = publish_index_failure(
        _affine_error((3.0, 0.0, 0.0)),
        base_dir=tmp_path,
        holder_capacity=6,
        evidence_id_factory=lambda: "same-evidence-id",
    )
    path = tmp_path / "failed-attempt-evidence" / "same-evidence-id.json"
    original = path.read_bytes()

    with pytest.raises(EvidencePublicationError, match="already exists"):
        publish_index_failure(
            _affine_error((9.0, 0.0, 0.0)),
            base_dir=tmp_path,
            holder_capacity=6,
            evidence_id_factory=lambda: "same-evidence-id",
        )

    assert path.read_bytes() == original
    assert json.loads(original)["evidenceId"] == first["evidenceId"]


def test_holder_bound_and_unknown_fields_fail_before_publication(tmp_path: Path) -> None:
    with pytest.raises(EvidencePublicationError, match="holder capacity"):
        publish_index_failure(
            _affine_error((3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)),
            base_dir=tmp_path,
            holder_capacity=6,
        )

    error = _affine_error((3.0, 0.0, 0.0))
    assert error.diagnostics is not None
    error.diagnostics["raw_path"] = "/private/capture.bin"
    with pytest.raises(EvidencePublicationError, match="invalid"):
        publish_index_failure(error, base_dir=tmp_path, holder_capacity=6)

    assert not (tmp_path / "failed-attempt-evidence").exists()
