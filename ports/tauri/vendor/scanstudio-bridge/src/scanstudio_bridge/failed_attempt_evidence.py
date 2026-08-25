"""Publish bounded, share-safe witnesses for refused transport attempts."""

from __future__ import annotations

import json
import os
import re
import uuid
from pathlib import Path
from typing import Callable

from coolscanpy.protocol.ls5000_single_pass.roll_index import (
    IndexDecodeError,
    replay_transport_failure_witness,
)

_MAX_BYTES = 16 * 1024
_EVIDENCE_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


class EvidencePublicationError(RuntimeError):
    """A witness was unsafe, invalid, too large, or could not be persisted."""


def _camel_witness(source: dict[str, object], holder_capacity: int) -> dict[str, object]:
    kind = source["kind"]
    if kind == "terminal_padding":
        mismatch = source["mismatch_location"]
        assert isinstance(mismatch, dict)
        return {
            "kind": "terminalPadding",
            "recordCount": source["record_count"],
            "byteCount": source["byte_count"],
            "parity": source["parity"],
            "housekeepingByteCount": source["housekeeping_byte_count"],
            "nonzeroRgbCount": source["nonzero_rgb_count"],
            "mismatchLocation": {
                "recordIndex": mismatch["record_index"],
                "byteOffset": mismatch["byte_offset"],
            },
        }
    anchors = source["anchors"]
    assert isinstance(anchors, list)
    transform = source["transform"]
    thresholds = source["thresholds"]
    assert isinstance(transform, dict) and isinstance(thresholds, dict)
    return {
        "kind": "affine",
        "holderCapacity": holder_capacity,
        "anchors": [
            {
                "ordinal": anchor["ordinal"],
                "inputRow": anchor["input_row"],
                "observedRow": anchor["observed_row"],
                "fittedRow": anchor["fitted_row"],
                "residualRows": anchor["residual_rows"],
            }
            for anchor in anchors
        ],
        "transform": {
            "slope": transform["slope"],
            "intercept": transform["intercept"],
        },
        "thresholds": {
            "maximumMeanAbsoluteResidualRows": thresholds[
                "maximum_mean_absolute_residual_rows"
            ],
            "maximumResidualRows": thresholds["maximum_residual_rows"],
        },
        "meanAbsoluteResidualRows": source["mean_absolute_residual_rows"],
        "maximumResidualRows": source["maximum_residual_rows"],
    }


def publish_index_failure(
    error: IndexDecodeError,
    *,
    base_dir: Path,
    holder_capacity: int,
    evidence_id_factory: Callable[[], str] = lambda: uuid.uuid4().hex,
) -> dict[str, object]:
    """Validate first, then create one private immutable JSON artifact."""
    source = error.diagnostics
    if error.error_id is None or not isinstance(source, dict):
        raise EvidencePublicationError("transport failure has no replayable witness")
    if isinstance(holder_capacity, bool) or not isinstance(holder_capacity, int):
        raise EvidencePublicationError("holder capacity is invalid")
    if not 1 <= holder_capacity <= 40:
        raise EvidencePublicationError("holder capacity is outside its bound")
    try:
        replayed_id = replay_transport_failure_witness(source)
    except (KeyError, TypeError, ValueError) as exc:
        raise EvidencePublicationError(f"transport failure witness is invalid: {exc}") from exc
    if replayed_id != error.error_id:
        raise EvidencePublicationError("transport failure witness does not match its error id")
    anchors = source.get("anchors")
    if isinstance(anchors, list) and len(anchors) > holder_capacity:
        raise EvidencePublicationError("witness exceeds holder capacity")

    evidence_id = evidence_id_factory()
    if not isinstance(evidence_id, str) or _EVIDENCE_ID.fullmatch(evidence_id) is None:
        raise EvidencePublicationError("evidence id is invalid")
    try:
        witness = _camel_witness(source, holder_capacity)
        artifact: dict[str, object] = {
            "schemaVersion": 1,
            "evidenceId": evidence_id,
            "witness": witness,
        }
        encoded = json.dumps(
            artifact, allow_nan=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
    except (KeyError, TypeError, ValueError) as exc:
        raise EvidencePublicationError(f"transport failure witness is invalid: {exc}") from exc
    if len(encoded) > _MAX_BYTES:
        raise EvidencePublicationError("diagnostic evidence exceeds its byte bound")

    directory = Path(base_dir) / "failed-attempt-evidence"
    path = directory / f"{evidence_id}.json"
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(directory, 0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o600)
    except FileExistsError as exc:
        raise EvidencePublicationError("diagnostic evidence already exists") from exc
    except OSError as exc:
        raise EvidencePublicationError("diagnostic evidence could not be created") from exc
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as exc:
        try:
            path.unlink()
        except OSError:
            pass
        raise EvidencePublicationError("diagnostic evidence could not be persisted") from exc
    return artifact
