"""Process-isolated bridge to NegPy's proven LS-5000 RGBI4x capture worker.

The package owns and integrity-pins the USB worker. This adapter gives the
application a narrow, fail-closed process boundary around it:

* every launch uses an argv list (never a shell command),
* both the worker and bundled replay plan are hash-pinned before launch,
* preview attempts expose the scanner's addressable candidates without a
  count hint, while meter attempts capture one explicit scanner slot,
* selected full frames share one child/reservation and cross a durable
  frame-ready/parent-ACK boundary before the next frame starts, and
* a stop request is observed only at a safe frame boundary.  An active child
  is never signalled or killed by this adapter.

The worker's ``--preview-only`` operation persists the roll preview and 0x8e
table before any frame binding.  Exposure-count labels are not part of this
interface: the adapter never emits ``--expected-frame-count``.
"""

from __future__ import annotations

import ctypes
import errno
import hashlib
import json
import math
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, replace
from enum import StrEnum
from importlib.util import find_spec
from pathlib import Path
from statistics import median
from typing import Any, Protocol, Sequence

import numpy as np

from .bundle import (
    CANONICAL_MANIFEST_FILENAME,
    CAPTURE_BUNDLE_SHA256,
    CAPTURE_WORKER_SHA256,
    CaptureBundleIntegrityError,
    canonical_manifest_bytes,
    verify_capture_bundle,
)
from .continuation_plan import (
    CANONICAL_CONTINUATION_PLAN_FILENAME,
    CANONICAL_CONTINUATION_PLAN_SHA256,
    canonical_continuation_plan_bytes,
)
from .density import (
    DensityCalibration,
    NikonDensityEvidence,
    NikonDensityFrameOwnershipReceipt,
    NikonDensitySourceBinding,
    build_nikon_density_evidence,
)
from .meter import EXPOSURE_MAX, EXPOSURE_MIN
from .plan import (
    CANONICAL_FINE_READ_BYTES,
    CANONICAL_FINE_READ_COUNT,
    CANONICAL_PLAN_FILENAME,
    CANONICAL_PLAN_SHA256,
    canonical_plan_bytes,
)


METER_READ_COUNT = 15
METER_CAPTURE_BYTES = 3_264_000
POWER_CYCLE_RECOVERY = "power-cycle scanner before another attempt"
CAPTURE_HELPER_FLAG = "--ls5000-capture-helper"
PACKAGED_WORKER_MODULE = "coolscanpy.protocol.ls5000_single_pass.worker"
WORKER_BOOTSTRAP_SCHEMA_VERSION = 1
WORKER_BOOTSTRAP_FAILED = "failed-before-ready"
WORKER_BOOTSTRAP_STATUS_FILENAME = "worker-bootstrap.json"
REVIEWED_ROLL_FINGERPRINT_VERSION = 2
MANUAL_FRAME_APPROVAL_VERSION = 1
MAX_VISUAL_MEDIAN_HAMMING = 24
MAX_VISUAL_P90_HAMMING = 48
MAX_SELECTED_VISUAL_HAMMING = 48
MIN_VISUAL_LOG_SPAN = 0.5
MIN_DISCRIMINATIVE_FRAME_COUNT = 3
MAX_FRAME_START_MEDIAN_DELTA_ROWS = 16
MAX_FRAME_START_DELTA_ROWS = 32
MAX_NATIVE_ORIGIN_MEDIAN_DELTA = 128
MAX_NATIVE_ORIGIN_DELTA = 256
MAX_PREVIEW_HEIGHT_DELTA_ROWS = 32

# This child-side launcher is intentionally stdlib-only. It writes a durable
# `starting` status before importing the worker, and records a typed bootstrap
# failure only if the import or entrypoint lookup fails. It writes `ready`
# immediately before calling the worker's canonical ``main(argv)`` entrypoint,
# which is the first code path that can dispatch to the scanner. Do not turn
# this into a shell command or a PYTHONPATH setup: the outer interpreter stays
# isolated.
_PACKAGED_WORKER_BOOTSTRAP = r'''
import importlib
import json
import os
import sys
import tempfile

status_path, module_name, nonce, worker_argv_sha256, *worker_argv = sys.argv[1:]

def _write_status(payload):
    directory = os.path.dirname(status_path) or "."
    descriptor, temporary = tempfile.mkstemp(prefix=".worker-bootstrap-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, status_path)
        try:
            directory_descriptor = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        except OSError:
            pass
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

def _state():
    try:
        with open(status_path, encoding="utf-8") as stream:
            payload = json.load(stream)
    except (OSError, ValueError, TypeError):
        return None
    return payload.get("state") if isinstance(payload, dict) else None

binding = {"nonce": nonce, "worker_argv_sha256": worker_argv_sha256}
_write_status({"schema_version": 1, "state": "starting", **binding})
try:
    worker = importlib.import_module(module_name)
    main = getattr(worker, "main")
    if not callable(main):
        raise TypeError("packaged capture worker has no callable main(argv) entrypoint")
    _write_status({"schema_version": 1, "state": "ready", **binding})
    main(worker_argv)
except BaseException as error:
    if _state() == "starting":
        _write_status(
            {
                "schema_version": 1,
                "state": "failed-before-ready",
                **binding,
                "error_type": type(error).__name__,
                "error_message": str(error)[:2048],
            }
        )
    raise
'''


def _lower_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _validated_density_calibration(
    journal: dict[str, Any],
    *,
    expected_session_id: str | None = None,
) -> DensityCalibration:
    """Validate the worker's raw READ(0x8c) evidence and reservation binding."""

    calibration = DensityCalibration.from_dict(journal.get("nikon_density_calibration"))
    if journal.get("density_calibration_session_id") != calibration.session_id:
        raise ValueError(
            "density calibration record and journal reservation identity disagree"
        )
    if (
        expected_session_id is not None
        and calibration.session_id != expected_session_id
    ):
        raise ValueError("density calibration belongs to another reservation")
    return calibration


def _batch_frame_output(batch_directory: Path, selected_slot: object) -> Path:
    """Return one batch frame's own capture output, as the job names it.

    The single source of truth for the ``frame-NNN/capture.bin`` layout the
    parent writes into every batch job (``_batch_job_bytes``), hands to the
    child, and re-derives when validating what came back
    (``_batch_frame_paths``).
    """

    if type(selected_slot) is not int:
        raise AssertionError("validated batch frame has no selected slot")
    return batch_directory / f"frame-{selected_slot:03d}" / "capture.bin"


def _density_source_path(output_path: Path) -> Path:
    """Return the 97-dpi density source raster written beside ``output_path``.

    The worker persists the reservation's density source (``_live_index_
    artifact_paths``) next to whichever capture output was open when the
    preview traversal completed. For a cold batch that is the batch child's
    own first-frame output, so this derivation is exact. For a
    preview-and-hold reservation the traversal completed in the *preview*
    attempt, long before any frame directory existed -- that shape must
    resolve the source from the held attempt's own output instead, which is
    what ``PreparedCaptureBatch.density_source_path`` carries.
    """

    return output_path.with_name(f"{output_path.stem}-preview.bin")


def _validated_density_evidence(
    journal: dict[str, Any],
    *,
    source_path: Path,
) -> NikonDensityEvidence:
    """Rebuild one bounded session receipt from its hash-bound preview bytes.

    ``source_path`` is the reservation's own 97-dpi density source raster --
    always parent-derived, never read out of the journal under validation.
    See ``_density_source_path`` for why it cannot simply be derived from the
    frame output being validated.
    """

    receipt = journal.get("nikon_density_evidence")
    if type(receipt) is not dict:
        raise ValueError("Nikon density evidence receipt is missing or malformed")
    try:
        stat = source_path.lstat()
    except OSError as error:
        raise ValueError("Nikon density source artifact is missing") from error
    if source_path.is_symlink() or not source_path.is_file():
        raise ValueError("Nikon density source artifact is not a regular file")

    calibration_binding = receipt.get("calibration_binding")
    exposure_binding = receipt.get("exposure_binding")
    source_binding = receipt.get("source_binding")
    if not all(
        type(value) is dict
        for value in (calibration_binding, exposure_binding, source_binding)
    ):
        raise ValueError("Nikon density evidence bindings are malformed")
    calibration = DensityCalibration.from_dict(calibration_binding.get("calibration"))
    exposures = exposure_binding.get("density_f03_exposures_raw_10ns_rgb")
    if type(exposures) is not list:
        raise ValueError("Nikon density f03 exposures are malformed")
    parsed_source_binding = NikonDensitySourceBinding.from_dict(source_binding)
    expected_source_bytes = (
        parsed_source_binding.height * parsed_source_binding.row_stride_bytes
    )
    if stat.st_size != expected_source_bytes:
        raise ValueError("Nikon density source artifact has the wrong byte length")
    try:
        source_payload = source_path.read_bytes()
    except OSError as error:
        raise ValueError("Nikon density source artifact could not be read") from error
    evidence = build_nikon_density_evidence(
        source_payload,
        calibration=calibration,
        density_f03_exposures_raw_10ns=tuple(exposures),
        session_id=parsed_source_binding.session_id,
        capture_attempt_id=parsed_source_binding.capture_attempt_id,
        scan_identity=parsed_source_binding.scan_identity,
        source_native_height=parsed_source_binding.native_height,
        source_height=parsed_source_binding.height,
    )
    if evidence.to_dict() != receipt:
        raise ValueError("Nikon density evidence does not reproduce its receipt")
    return evidence


def _validated_density_frame_ownership(
    journal: dict[str, Any],
    *,
    output_path: Path,
    expected_batch_session_id: str,
    expected_calibration_session_id: str,
    expected_frame_index: int,
    expected_frame_total: int,
    expected_selected_slots: tuple[int, ...],
    expected_selected_slot: int,
    evidence: NikonDensityEvidence | None = None,
) -> NikonDensityFrameOwnershipReceipt:
    """Validate one frame's exact reservation-preview ownership receipt.

    Two distinct identities, deliberately not one: ``expected_batch_session_id``
    is this specific batch/round's own session id (a fresh one every held
    round -- see ``worker._density_frame_ownership_receipt``'s docstring and
    ``PreparedCaptureBatch``'s), checked against the journal's own
    ``batch_session`` block. ``expected_calibration_session_id`` is the
    reservation-wide identity the density receipt itself is bound to, which
    persists across every round of one feed-to-eject reservation. They
    coincide for a cold batch and diverge for a resumed one.
    """

    receipt = NikonDensityFrameOwnershipReceipt.from_dict(
        journal.get("nikon_density_frame_ownership")
    )
    expected_batch = {
        "frame_index": expected_frame_index,
        "frame_total": expected_frame_total,
        "selected_slots": list(expected_selected_slots),
        "session_id": expected_batch_session_id,
    }
    if journal.get("batch_session") != expected_batch:
        raise ValueError("density ownership batch journal identity is inconsistent")
    selection = journal.get("live_frame_selection")
    if type(selection) is not dict:
        raise ValueError("density ownership live frame selection is missing")
    roll_identity = selection.get("roll_identity")
    if type(roll_identity) is not dict:
        raise ValueError("density ownership roll identity is missing")
    expected = {
        "reservation_id": expected_calibration_session_id,
        "batch_session_id": expected_calibration_session_id,
        "preview_sha256": selection.get("preview_sha256"),
        "transport_table_sha256": selection.get("table_sha256"),
        "reviewed_fingerprint_sha256": roll_identity.get("reviewed_fingerprint_sha256"),
        "fresh_fingerprint_sha256": roll_identity.get("fresh_fingerprint_sha256"),
        "frame_capture_attempt_id": output_path.parent.name,
        "frame_index": expected_frame_index,
        "frame_total": expected_frame_total,
        "selected_slots": expected_selected_slots,
        "selected_slot": expected_selected_slot,
    }
    for field, value in expected.items():
        if getattr(receipt, field) != value:
            raise ValueError(f"density ownership {field} changed at capture boundary")
    if journal.get("session_reservation_retained") is not True:
        raise ValueError("density ownership reservation was not retained")
    if evidence is not None:
        receipt.validate_evidence(evidence)
    return receipt


def _canonical_json_sha256(payload: dict[str, Any]) -> str:
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class CaptureMode(StrEnum):
    """The safe operations currently exposed by the capture worker."""

    PREVIEW = "preview"
    METER_ONLY = "meter-only"
    FULL = "full"


class CaptureOutcome(StrEnum):
    """Application-level interpretation of a completed child process."""

    COMPLETE = "complete"
    SYNCHRONIZED_REFUSAL = "synchronized-refusal"
    BOOTSTRAP_FAILED = "bootstrap-failed"
    RECOVERY_REQUIRED = "recovery-required"


class BatchAckAction(StrEnum):
    """Parent decision written only after one frame is durably finalized."""

    CONTINUE = "continue"
    STOP = "stop"
    # Only legal as the terminal decision (see Roll.scan_many's
    # ``eject_after`` parameter): ends the batch exactly like STOP, but the
    # worker additionally replays the traced vendor end-of-session eject
    # sequence, still inside this batch's original reservation, before
    # releasing.
    EJECT = "eject"
    # Only legal as the terminal decision, and only when this batch itself
    # resumed a held preview (see Roll.scan_many's default -- neither
    # ``eject_after`` nor a safe-stop): ends this batch's own requested
    # frames exactly like STOP, but the worker does NOT release. Instead it
    # loops back into a fresh hold-wait -- same child, same reservation,
    # same retained frame table -- so a later ``resume_held_session`` can
    # capture more frames without a refeed. A cold (never-held) batch's
    # frame_handler must never return this; the worker itself refuses it
    # when no hold plumbing is available (see worker.py's
    # ``hold_job_path is None`` guard).
    CONTINUE_HOLD = "continue_hold"


class CaptureProcessError(RuntimeError):
    """The adapter refused before a trustworthy worker result was available."""


class CaptureBatchProcessError(CaptureProcessError):
    """A spawned batch failed after preserving its partial frame/release state."""

    def __init__(
        self,
        message: str,
        *,
        outcome: CaptureOutcome,
        paths: BatchSessionPaths,
        frames: Sequence[CaptureAttemptResult],
        returncode: int,
        session_journal: dict[str, Any] | None,
    ) -> None:
        super().__init__(message)
        self.outcome = outcome
        self.paths = paths
        self.frames = tuple(frames)
        self.returncode = returncode
        self.session_journal = session_journal

    @property
    def recovery_required(self) -> bool:
        return self.outcome is CaptureOutcome.RECOVERY_REQUIRED


class CaptureIntegrityError(CaptureProcessError):
    """A pinned executable, plan, or manifest failed verification."""


class CaptureStopped(CaptureProcessError):
    """A stop request prevented the next attempt from launching."""


class HeldSessionExpired(CaptureProcessError):
    """A held preview's child is no longer available to resume or release.

    The reservation this session was holding cannot be assumed to still be
    held -- the scanner may have auto-ejected, the child may have crashed,
    or a prior resume/release attempt may already have consumed it.  The
    caller must treat this exactly like a fresh reservation attempt that
    needs a real refeed, not retry the same held session.
    """


class _BatchFrameRefused(CaptureProcessError):
    """A bad frame handoff was safely answered with a bound STOP ACK."""

    def __init__(self, message: str, *, slot: int) -> None:
        super().__init__(message)
        self.slot = slot


class _BatchTerminalReceiptObserved(Exception):
    """The child published a terminal session receipt before ``poll()`` noticed."""


@dataclass(frozen=True)
class ReviewedRollFingerprint:
    """Exact reviewed artifacts plus a reread-tolerant physical-roll signature."""

    source_preview_sha256: str
    source_table_sha256: str
    preview_shape: tuple[int, int, int]
    frame_start_rows: tuple[int, ...]
    frame_native_origins: tuple[int, ...]
    frame_visual_hashes: tuple[str, ...]
    frame_visual_log_spans: tuple[float, ...]
    schema_version: int = REVIEWED_ROLL_FINGERPRINT_VERSION

    def __post_init__(self) -> None:
        if self.schema_version != REVIEWED_ROLL_FINGERPRINT_VERSION:
            raise ValueError("reviewed roll fingerprint schema is unsupported")
        if not _lower_sha256(self.source_preview_sha256) or not _lower_sha256(
            self.source_table_sha256
        ):
            raise ValueError("reviewed roll source identities must be SHA-256 digests")
        if (
            not isinstance(self.preview_shape, tuple)
            or len(self.preview_shape) != 3
            or any(type(value) is not int or value < 1 for value in self.preview_shape)
            or self.preview_shape[2] != 3
        ):
            raise ValueError(
                "reviewed roll preview shape must be a positive HxWx3 tuple"
            )
        count = len(self.frame_start_rows)
        if not 1 <= count <= 40:
            raise ValueError("reviewed roll fingerprint must describe 1..40 slots")
        if (
            len(self.frame_native_origins) != count
            or len(self.frame_visual_hashes) != count
            or len(self.frame_visual_log_spans) != count
        ):
            raise ValueError(
                "reviewed roll fingerprint frame fields must have equal length"
            )
        if any(type(value) is not int or value < 0 for value in self.frame_start_rows):
            raise ValueError("reviewed roll frame starts must be nonnegative integers")
        if any(
            first >= second
            for first, second in zip(self.frame_start_rows, self.frame_start_rows[1:])
        ):
            raise ValueError("reviewed roll frame starts must be strictly increasing")
        if any(
            type(value) is not int or value < 0 for value in self.frame_native_origins
        ):
            raise ValueError(
                "reviewed roll native origins must be nonnegative integers"
            )
        if any(
            first >= second
            for first, second in zip(
                self.frame_native_origins,
                self.frame_native_origins[1:],
            )
        ):
            raise ValueError("reviewed roll native origins must be strictly increasing")
        if any(not _lower_sha256(value) for value in self.frame_visual_hashes):
            raise ValueError(
                "reviewed roll visual hashes must be SHA-256-sized hex values"
            )
        if any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or float(value) < 0.0
            for value in self.frame_visual_log_spans
        ):
            raise ValueError(
                "reviewed roll visual log spans must be finite nonnegative numbers"
            )

    def binding_payload(self) -> dict[str, Any]:
        return {
            "frame_native_origins": list(self.frame_native_origins),
            "frame_start_rows": list(self.frame_start_rows),
            "frame_visual_hashes": list(self.frame_visual_hashes),
            "frame_visual_log_spans": list(self.frame_visual_log_spans),
            "preview_shape": list(self.preview_shape),
            "schema_version": self.schema_version,
            "source_preview_sha256": self.source_preview_sha256,
            "source_table_sha256": self.source_table_sha256,
        }

    @property
    def binding_sha256(self) -> str:
        return _canonical_json_sha256(self.binding_payload())

    def to_payload(self) -> dict[str, Any]:
        return {
            **self.binding_payload(),
            "binding_sha256": self.binding_sha256,
        }

    @classmethod
    def from_payload(cls, payload: object) -> ReviewedRollFingerprint:
        if not isinstance(payload, dict) or set(payload) != {
            "binding_sha256",
            "frame_native_origins",
            "frame_start_rows",
            "frame_visual_hashes",
            "frame_visual_log_spans",
            "preview_shape",
            "schema_version",
            "source_preview_sha256",
            "source_table_sha256",
        }:
            raise ValueError("reviewed roll fingerprint payload is malformed")
        shape = payload.get("preview_shape")
        starts = payload.get("frame_start_rows")
        origins = payload.get("frame_native_origins")
        visual = payload.get("frame_visual_hashes")
        spans = payload.get("frame_visual_log_spans")
        if not all(
            isinstance(value, list) for value in (shape, starts, origins, visual, spans)
        ):
            raise ValueError("reviewed roll fingerprint arrays are malformed")
        value = cls(
            source_preview_sha256=payload.get("source_preview_sha256"),  # type: ignore[arg-type]
            source_table_sha256=payload.get("source_table_sha256"),  # type: ignore[arg-type]
            preview_shape=tuple(shape),  # type: ignore[arg-type]
            frame_start_rows=tuple(starts),  # type: ignore[arg-type]
            frame_native_origins=tuple(origins),  # type: ignore[arg-type]
            frame_visual_hashes=tuple(visual),  # type: ignore[arg-type]
            frame_visual_log_spans=tuple(spans),  # type: ignore[arg-type]
            schema_version=payload.get("schema_version"),  # type: ignore[arg-type]
        )
        if payload.get("binding_sha256") != value.binding_sha256:
            raise ValueError("reviewed roll fingerprint binding digest changed")
        return value


@dataclass(frozen=True)
class ManualFrameApproval:
    """Operator approval bound to one reviewed thumbnail and transport choice."""

    reviewed_fingerprint_sha256: str
    slot: int
    boundary_offset_rows: int
    thumbnail_sha256: str
    reviewed_lookup_row: int
    reviewed_native_origin: int
    review_reasons: tuple[str, ...]
    schema_version: int = MANUAL_FRAME_APPROVAL_VERSION

    def __post_init__(self) -> None:
        if self.schema_version != MANUAL_FRAME_APPROVAL_VERSION:
            raise ValueError("manual frame approval schema is unsupported")
        if not _lower_sha256(self.reviewed_fingerprint_sha256):
            raise ValueError("manual frame approval fingerprint identity is invalid")
        if type(self.slot) is not int or not 1 <= self.slot <= 40:
            raise ValueError("manual frame approval slot must be in 1..40")
        if type(self.boundary_offset_rows) is not int:
            raise TypeError("manual frame approval boundary offset must be an integer")
        minimum_offset = 0 if self.slot == 1 else -144
        if not minimum_offset <= self.boundary_offset_rows <= 144:
            raise ValueError(
                "manual frame approval boundary offset is outside 97-dpi limits"
            )
        if not _lower_sha256(self.thumbnail_sha256):
            raise ValueError("manual frame approval thumbnail identity is invalid")
        if type(self.reviewed_lookup_row) is not int or self.reviewed_lookup_row < 0:
            raise ValueError("manual frame approval lookup row is invalid")
        if (
            type(self.reviewed_native_origin) is not int
            or self.reviewed_native_origin < 0
        ):
            raise ValueError("manual frame approval native origin is invalid")
        if (
            not isinstance(self.review_reasons, tuple)
            or not self.review_reasons
            or any(type(value) is not str or not value for value in self.review_reasons)
        ):
            raise ValueError("manual frame approval requires explicit review reasons")

    def binding_payload(self) -> dict[str, Any]:
        return {
            "boundary_offset_rows": self.boundary_offset_rows,
            "review_reasons": list(self.review_reasons),
            "reviewed_fingerprint_sha256": self.reviewed_fingerprint_sha256,
            "reviewed_lookup_row": self.reviewed_lookup_row,
            "reviewed_native_origin": self.reviewed_native_origin,
            "schema_version": self.schema_version,
            "slot": self.slot,
            "thumbnail_sha256": self.thumbnail_sha256,
        }

    @property
    def binding_sha256(self) -> str:
        return _canonical_json_sha256(self.binding_payload())

    def to_payload(self) -> dict[str, Any]:
        return {
            **self.binding_payload(),
            "binding_sha256": self.binding_sha256,
        }

    @classmethod
    def from_payload(cls, payload: object) -> ManualFrameApproval:
        if not isinstance(payload, dict) or set(payload) != {
            "binding_sha256",
            "boundary_offset_rows",
            "review_reasons",
            "reviewed_fingerprint_sha256",
            "reviewed_lookup_row",
            "reviewed_native_origin",
            "schema_version",
            "slot",
            "thumbnail_sha256",
        }:
            raise ValueError("manual frame approval payload is malformed")
        reasons = payload.get("review_reasons")
        if not isinstance(reasons, list):
            raise ValueError("manual frame approval reasons are malformed")
        value = cls(
            reviewed_fingerprint_sha256=payload.get("reviewed_fingerprint_sha256"),  # type: ignore[arg-type]
            slot=payload.get("slot"),  # type: ignore[arg-type]
            boundary_offset_rows=payload.get("boundary_offset_rows"),  # type: ignore[arg-type]
            thumbnail_sha256=payload.get("thumbnail_sha256"),  # type: ignore[arg-type]
            reviewed_lookup_row=payload.get("reviewed_lookup_row"),  # type: ignore[arg-type]
            reviewed_native_origin=payload.get("reviewed_native_origin"),  # type: ignore[arg-type]
            review_reasons=tuple(reasons),
            schema_version=payload.get("schema_version"),  # type: ignore[arg-type]
        )
        if payload.get("binding_sha256") != value.binding_sha256:
            raise ValueError("manual frame approval binding digest changed")
        return value


@dataclass(frozen=True)
class RollFingerprintComparison:
    """Auditable result of comparing a fresh traversal to reviewed evidence."""

    matches: bool
    reason: str
    compared_frames: int
    preview_height_delta_rows: int | None
    visual_median_hamming: float | None
    visual_p90_hamming: int | None
    frame_start_median_delta_rows: float | None
    frame_start_max_delta_rows: int | None
    native_origin_median_delta: float | None
    native_origin_max_delta: int | None
    discriminative_frames: int
    minimum_discriminative_frames: int
    minimum_visual_log_span: float

    def to_payload(self) -> dict[str, Any]:
        return {
            "compared_frames": self.compared_frames,
            "discriminative_frames": self.discriminative_frames,
            "frame_start_max_delta_rows": self.frame_start_max_delta_rows,
            "frame_start_median_delta_rows": self.frame_start_median_delta_rows,
            "matches": self.matches,
            "minimum_discriminative_frames": self.minimum_discriminative_frames,
            "minimum_visual_log_span": self.minimum_visual_log_span,
            "native_origin_max_delta": self.native_origin_max_delta,
            "native_origin_median_delta": self.native_origin_median_delta,
            "preview_height_delta_rows": self.preview_height_delta_rows,
            "reason": self.reason,
            "visual_median_hamming": self.visual_median_hamming,
            "visual_p90_hamming": self.visual_p90_hamming,
        }


@dataclass(frozen=True)
class SelectedRollFingerprintComparison:
    """A selected slot's own visual proof, independent of roll aggregates."""

    matches: bool
    reason: str
    slot: int
    visual_hamming: int
    maximum_visual_hamming: int
    reviewed_visual_log_span: float
    fresh_visual_log_span: float
    minimum_visual_log_span: float

    def to_payload(self) -> dict[str, Any]:
        return {
            "fresh_visual_log_span": self.fresh_visual_log_span,
            "matches": self.matches,
            "maximum_visual_hamming": self.maximum_visual_hamming,
            "minimum_visual_log_span": self.minimum_visual_log_span,
            "reason": self.reason,
            "reviewed_visual_log_span": self.reviewed_visual_log_span,
            "slot": self.slot,
            "visual_hamming": self.visual_hamming,
        }


MIN_FINGERPRINT_FRAME_ROWS = 16


def _roll_frame_visual_signature(frame: np.ndarray) -> tuple[str, float]:
    """Return a robust hash and calibrated information span for one slot."""

    array = np.asarray(frame)
    if (
        array.dtype != np.uint16
        or array.ndim != 3
        or array.shape[2] != 3
        or array.shape[0] < 16
        or array.shape[1] < 16
    ):
        raise ValueError("roll fingerprint frames must be uint16 HxWx3 images")
    luminance = np.log1p(array.astype(np.float64)).mean(axis=2)
    y_edges = np.linspace(0, len(luminance), 17, dtype=np.int64)
    x_edges = np.linspace(0, luminance.shape[1], 17, dtype=np.int64)
    grid = np.empty((16, 16), dtype=np.float64)
    for row in range(16):
        for column in range(16):
            block = luminance[
                y_edges[row] : y_edges[row + 1],
                x_edges[column] : x_edges[column + 1],
            ]
            if block.size == 0:
                raise ValueError("roll fingerprint frame is too small for its grid")
            grid[row, column] = float(block.mean())
    bits = np.packbits(
        (grid > float(np.median(grid))).reshape(-1),
        bitorder="big",
    )
    low, high = np.percentile(grid, (5.0, 95.0))
    return bits.tobytes().hex(), float(high - low)


def _roll_frame_visual_hash(frame: np.ndarray) -> str:
    """Return the gain/noise-tolerant 256-bit part of a slot signature."""

    return _roll_frame_visual_signature(frame)[0]


def build_reviewed_roll_fingerprint(
    rgb: np.ndarray,
    *,
    frame_intervals: Sequence[tuple[int, int]],
    frame_native_origins: Sequence[int],
    source_preview_sha256: str,
    source_table_sha256: str,
) -> ReviewedRollFingerprint:
    """Bind exact preview artifacts to a robust per-slot physical signature."""

    array = np.asarray(rgb)
    intervals = tuple(frame_intervals)
    origins = tuple(frame_native_origins)
    if len(intervals) != len(origins):
        raise ValueError("roll fingerprint intervals and native origins differ")
    starts: list[int] = []
    kept_origins: list[int] = []
    visual_hashes: list[str] = []
    visual_log_spans: list[float] = []
    for slot, interval in enumerate(intervals, start=1):
        if (
            not isinstance(interval, tuple)
            or len(interval) != 2
            or any(type(value) is not int for value in interval)
        ):
            raise TypeError(f"roll fingerprint interval {slot} is malformed")
        start, end = interval
        if not 0 <= start < end <= len(array):
            raise ValueError(f"roll fingerprint interval {slot} is outside the preview")
        if end - start < MIN_FINGERPRINT_FRAME_ROWS:
            # A trailing sliver (strip end past the last gap) is physically
            # real but carries too few rows to sign. Skip it on every
            # traversal so reviewed and fresh fingerprints stay parallel.
            continue
        starts.append(start)
        kept_origins.append(origins[slot - 1])
        visual_hash, visual_log_span = _roll_frame_visual_signature(array[start:end])
        visual_hashes.append(visual_hash)
        visual_log_spans.append(visual_log_span)
    if not starts:
        raise ValueError(
            "roll fingerprint requires at least one frame interval of "
            f"{MIN_FINGERPRINT_FRAME_ROWS}+ preview rows"
        )
    return ReviewedRollFingerprint(
        source_preview_sha256=source_preview_sha256,
        source_table_sha256=source_table_sha256,
        preview_shape=tuple(int(value) for value in array.shape),
        frame_start_rows=tuple(starts),
        frame_native_origins=tuple(kept_origins),
        frame_visual_hashes=tuple(visual_hashes),
        frame_visual_log_spans=tuple(visual_log_spans),
    )


def compare_reviewed_roll_fingerprints(
    reviewed: ReviewedRollFingerprint,
    fresh: ReviewedRollFingerprint,
) -> RollFingerprintComparison:
    """Compare two traversals without requiring analog bytes to be identical."""

    if not isinstance(reviewed, ReviewedRollFingerprint) or not isinstance(
        fresh, ReviewedRollFingerprint
    ):
        raise TypeError("roll fingerprint comparison requires reviewed fingerprints")

    def incompatible(reason: str) -> RollFingerprintComparison:
        return RollFingerprintComparison(
            matches=False,
            reason=reason,
            compared_frames=0,
            preview_height_delta_rows=None,
            visual_median_hamming=None,
            visual_p90_hamming=None,
            frame_start_median_delta_rows=None,
            frame_start_max_delta_rows=None,
            native_origin_median_delta=None,
            native_origin_max_delta=None,
            discriminative_frames=0,
            minimum_discriminative_frames=min(
                MIN_DISCRIMINATIVE_FRAME_COUNT,
                len(reviewed.frame_visual_hashes),
            ),
            minimum_visual_log_span=MIN_VISUAL_LOG_SPAN,
        )

    if reviewed.preview_shape[1:] != fresh.preview_shape[1:]:
        return incompatible("preview-geometry-mismatch")
    preview_height_delta = abs(reviewed.preview_shape[0] - fresh.preview_shape[0])
    if preview_height_delta > MAX_PREVIEW_HEIGHT_DELTA_ROWS:
        return incompatible("preview-height-mismatch")
    if len(reviewed.frame_visual_hashes) != len(fresh.frame_visual_hashes):
        return incompatible("slot-count-mismatch")

    visual = sorted(
        (int(expected, 16) ^ int(observed, 16)).bit_count()
        for expected, observed, expected_span, observed_span in zip(
            reviewed.frame_visual_hashes,
            fresh.frame_visual_hashes,
            reviewed.frame_visual_log_spans,
            fresh.frame_visual_log_spans,
            strict=True,
        )
        if expected_span >= MIN_VISUAL_LOG_SPAN and observed_span >= MIN_VISUAL_LOG_SPAN
    )
    discriminative_frames = len(visual)
    minimum_discriminative_frames = min(
        MIN_DISCRIMINATIVE_FRAME_COUNT,
        len(reviewed.frame_visual_hashes),
    )

    starts = sorted(
        abs(expected - observed)
        for expected, observed in zip(
            reviewed.frame_start_rows,
            fresh.frame_start_rows,
            strict=True,
        )
    )
    origins = sorted(
        abs(expected - observed)
        for expected, observed in zip(
            reviewed.frame_native_origins,
            fresh.frame_native_origins,
            strict=True,
        )
    )
    visual_median = float(median(visual)) if visual else None
    visual_p90 = visual[max(0, (9 * len(visual) + 9) // 10 - 1)] if visual else None
    start_median = float(median(starts))
    start_max = starts[-1]
    origin_median = float(median(origins))
    origin_max = origins[-1]
    if discriminative_frames < minimum_discriminative_frames:
        reason = "visual-signature-indeterminate"
    elif visual_median is None or visual_p90 is None:
        reason = "visual-signature-indeterminate"
    elif (
        visual_median > MAX_VISUAL_MEDIAN_HAMMING or visual_p90 > MAX_VISUAL_P90_HAMMING
    ):
        reason = "visual-content-mismatch"
    elif (
        start_median > MAX_FRAME_START_MEDIAN_DELTA_ROWS
        or start_max > MAX_FRAME_START_DELTA_ROWS
    ):
        reason = "frame-lattice-mismatch"
    elif (
        origin_median > MAX_NATIVE_ORIGIN_MEDIAN_DELTA
        or origin_max > MAX_NATIVE_ORIGIN_DELTA
    ):
        reason = "transport-origin-mismatch"
    else:
        reason = "matched"
    return RollFingerprintComparison(
        matches=reason == "matched",
        reason=reason,
        compared_frames=len(visual),
        preview_height_delta_rows=preview_height_delta,
        visual_median_hamming=visual_median,
        visual_p90_hamming=visual_p90,
        frame_start_median_delta_rows=start_median,
        frame_start_max_delta_rows=start_max,
        native_origin_median_delta=origin_median,
        native_origin_max_delta=origin_max,
        discriminative_frames=discriminative_frames,
        minimum_discriminative_frames=minimum_discriminative_frames,
        minimum_visual_log_span=MIN_VISUAL_LOG_SPAN,
    )


def compare_selected_roll_fingerprint(
    reviewed: ReviewedRollFingerprint,
    fresh: ReviewedRollFingerprint,
    *,
    slot: int,
) -> SelectedRollFingerprintComparison:
    """Require a selected slot to match even when roll aggregates tolerate it."""

    if not isinstance(reviewed, ReviewedRollFingerprint) or not isinstance(
        fresh,
        ReviewedRollFingerprint,
    ):
        raise TypeError(
            "selected fingerprint comparison requires reviewed fingerprints"
        )
    if type(slot) is not int or not 1 <= slot <= 40:
        raise ValueError("selected fingerprint slot must be in 1..40")
    if len(reviewed.frame_visual_hashes) != len(fresh.frame_visual_hashes):
        raise ValueError("selected fingerprint slot counts differ")
    if slot > len(reviewed.frame_visual_hashes):
        raise ValueError("selected fingerprint slot is outside the reviewed roll")
    index = slot - 1
    visual_hamming = (
        int(reviewed.frame_visual_hashes[index], 16)
        ^ int(fresh.frame_visual_hashes[index], 16)
    ).bit_count()
    reviewed_span = float(reviewed.frame_visual_log_spans[index])
    fresh_span = float(fresh.frame_visual_log_spans[index])
    if reviewed_span < MIN_VISUAL_LOG_SPAN or fresh_span < MIN_VISUAL_LOG_SPAN:
        reason = "selected-visual-signature-indeterminate"
    elif visual_hamming > MAX_SELECTED_VISUAL_HAMMING:
        reason = "selected-visual-content-mismatch"
    else:
        reason = "matched"
    return SelectedRollFingerprintComparison(
        matches=reason == "matched",
        reason=reason,
        slot=slot,
        visual_hamming=visual_hamming,
        maximum_visual_hamming=MAX_SELECTED_VISUAL_HAMMING,
        reviewed_visual_log_span=reviewed_span,
        fresh_visual_log_span=fresh_span,
        minimum_visual_log_span=MIN_VISUAL_LOG_SPAN,
    )


@dataclass(frozen=True)
class CaptureRequest:
    """One explicit scanner-addressable slot and capture mode.

    Roll exposure counts intentionally do not appear here.  A 36-exposure roll
    can contain a 37th image, and the preview UI may show blank or unusable tail
    slots up to the scanner's capacity.  Selection policy belongs above this
    process boundary.
    """

    mode: CaptureMode
    selected_slot: int | None = None
    boundary_offset_rows: int = 0
    manual_review_approval: ManualFrameApproval | None = None
    expected_usb_bus: int | None = None
    expected_usb_address: int | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.mode, CaptureMode):
            raise TypeError("mode must be a CaptureMode")
        if isinstance(self.boundary_offset_rows, bool) or not isinstance(
            self.boundary_offset_rows, int
        ):
            raise TypeError("boundary offset must be an integer row count")
        topology = (self.expected_usb_bus, self.expected_usb_address)
        if (topology[0] is None) != (topology[1] is None):
            raise ValueError("expected USB bus and address are inseparable")
        if topology[0] is not None:
            if (
                isinstance(topology[0], bool)
                or not isinstance(topology[0], int)
                or not 0 <= topology[0] <= 999
            ):
                raise ValueError("expected USB bus must be an integer in 0..999")
            if (
                isinstance(topology[1], bool)
                or not isinstance(topology[1], int)
                or not 1 <= topology[1] <= 127
            ):
                raise ValueError("expected USB address must be an integer in 1..127")
        if self.mode is CaptureMode.PREVIEW:
            if self.selected_slot is not None:
                raise ValueError("preview-only requests do not select a scanner slot")
            if self.boundary_offset_rows != 0:
                raise ValueError("preview boundary offset must be zero")
            if self.manual_review_approval is not None:
                raise ValueError(
                    "preview requests cannot carry a manual review approval"
                )
            return
        if (
            isinstance(self.selected_slot, bool)
            or not isinstance(self.selected_slot, int)
            or not 1 <= self.selected_slot <= 40
        ):
            raise ValueError("selected scanner slot must be an integer in 1..40")
        minimum_offset = 0 if self.selected_slot == 1 else -144
        if not minimum_offset <= self.boundary_offset_rows <= 144:
            raise ValueError(
                f"slot {self.selected_slot} boundary offset must be in "
                f"{minimum_offset}..144 rows"
            )
        approval = self.manual_review_approval
        if approval is not None:
            if not isinstance(approval, ManualFrameApproval):
                raise TypeError("manual review approval has the wrong type")
            if (
                approval.slot != self.selected_slot
                or approval.boundary_offset_rows != self.boundary_offset_rows
            ):
                raise ValueError(
                    "manual review approval does not match the requested frame"
                )


@dataclass(frozen=True)
class CaptureBatchRequest:
    """One ordered set of full frames for a future shared USB reservation."""

    frames: tuple[CaptureRequest, ...]
    reviewed_fingerprint: ReviewedRollFingerprint
    expected_usb_bus: int
    expected_usb_address: int
    exposure_override_10ns: tuple[int, int, int] | None = None
    # Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): the exact operator-
    # picked boundary rows from a manual-placement preview session, carried
    # across the process boundary so the batch child can replay
    # manual_frames.build_manual_detection fresh against its own live re-read
    # bytes -- never trusted as a serialized detection result (see worker.py's
    # _derive_live_frame_selection docstring). None for an ordinary,
    # automatically-detected session -- see Roll.scan_many, which derives
    # this from its own reviewed session rather than accepting it from a
    # caller.
    manual_boundary_rows: tuple[int, ...] | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.frames, tuple):
            raise TypeError("batch frames must be an immutable tuple")
        if not self.frames:
            raise ValueError("batch must contain at least one frame")
        if not all(isinstance(frame, CaptureRequest) for frame in self.frames):
            raise TypeError("every batch frame must be a CaptureRequest")
        if any(frame.mode is not CaptureMode.FULL for frame in self.frames):
            raise ValueError("batch sessions currently support full captures only")
        if not isinstance(self.reviewed_fingerprint, ReviewedRollFingerprint):
            raise TypeError("batch requires one reviewed roll fingerprint")
        if (
            isinstance(self.expected_usb_bus, bool)
            or not isinstance(self.expected_usb_bus, int)
            or not 0 <= self.expected_usb_bus <= 999
        ):
            raise ValueError("batch expected USB bus must be an integer in 0..999")
        if (
            isinstance(self.expected_usb_address, bool)
            or not isinstance(self.expected_usb_address, int)
            or not 1 <= self.expected_usb_address <= 127
        ):
            raise ValueError("batch expected USB address must be an integer in 1..127")
        for frame in self.frames:
            approval = frame.manual_review_approval
            if (
                approval is not None
                and approval.reviewed_fingerprint_sha256
                != self.reviewed_fingerprint.binding_sha256
            ):
                raise ValueError(
                    "manual review approval belongs to another roll preview"
                )
        slots = self.selected_slots
        if tuple(sorted(set(slots))) != slots:
            raise ValueError(
                "batch scanner slots must be unique and strictly increasing"
            )
        if self.exposure_override_10ns is not None:
            override = self.exposure_override_10ns
            if (
                isinstance(override, (str, bytes))
                or not isinstance(override, (tuple, list))
                or len(override) != 3
            ):
                raise ValueError(
                    "exposure_override_10ns must be a (red, green, blue) "
                    "3-tuple of raw 10ns tick counts"
                )
            for channel, raw in zip(("red", "green", "blue"), override):
                if isinstance(raw, bool) or not isinstance(raw, int):
                    raise ValueError(
                        f"exposure_override_10ns {channel} tick count must "
                        f"be an int, got {raw!r}"
                    )
                if not EXPOSURE_MIN <= raw <= EXPOSURE_MAX:
                    raise ValueError(
                        f"exposure_override_10ns {channel} tick count {raw} "
                        f"is outside the allowed range "
                        f"[{EXPOSURE_MIN}, {EXPOSURE_MAX}]"
                    )

    @property
    def selected_slots(self) -> tuple[int, ...]:
        """Return statically validated scanner slots without optional typing."""

        return tuple(
            frame.selected_slot
            for frame in self.frames
            if frame.selected_slot is not None
        )


@dataclass(frozen=True)
class AttemptPaths:
    """All durable paths owned by one never-overwritten worker attempt."""

    directory: Path
    output: Path
    journal: Path
    plan: Path
    manifest: Path
    bootstrap_status: Path
    stdout: Path
    stderr: Path
    bootstrap_nonce: str = ""


@dataclass(frozen=True)
class BatchSessionPaths:
    """Durable, never-overwritten inputs for one batch child."""

    directory: Path
    job: Path
    first_plan: Path
    continuation_plan: Path
    manifest: Path
    bootstrap_status: Path
    session_journal: Path
    stdout: Path
    stderr: Path
    bootstrap_nonce: str = ""


@dataclass(frozen=True)
class PreparedCaptureBatch:
    """Hardware-free description of exactly one worker process.

    ``session_id`` and ``calibration_session_id`` coincide for a cold batch
    (calibration runs inside that same batch) but diverge for a
    preview-and-hold resume: ``session_id`` is this specific batch/round's
    own identity (a fresh one every hold round, by design -- see
    ``worker._density_frame_ownership_receipt``'s docstring), while
    ``calibration_session_id`` is the reservation-wide identity the held
    preview's density calibration was actually bound to, which persists
    across every round of the same feed-to-eject reservation. Validators
    that check the worker's density receipts must compare against
    ``calibration_session_id``, not ``session_id`` -- confusing the two
    here is what let a resumed batch's first frame reach the child
    correctly but still fail this package's own post-hoc validation.

    ``density_source_path`` is that same distinction expressed as a path.
    The reservation's 97-dpi density source raster is written wherever the
    traversal that produced it was running: inside a cold batch's own first
    frame directory, but inside the *held preview's attempt directory* for a
    preview-and-hold reservation, which completed its traversal before any
    frame directory existed. Deriving it from the frame under validation is
    therefore correct only for a cold batch -- see ``_density_source_path``.
    """

    request: CaptureBatchRequest
    paths: BatchSessionPaths
    argv: tuple[str, ...]
    job_sha256: str
    session_id: str
    calibration_session_id: str
    density_source_path: Path


@dataclass(frozen=True)
class CaptureAttemptResult:
    """Validated child result, including a conservative recovery decision."""

    outcome: CaptureOutcome
    request: CaptureRequest
    paths: AttemptPaths
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    journal: dict[str, Any] | None
    journal_error: str | None = None
    batch_session_id: str | None = None
    batch_frame_index: int | None = None
    batch_frame_total: int | None = None
    batch_selected_slots: tuple[int, ...] = ()
    # Where this attempt's *reservation* wrote its 97-dpi density source
    # raster. ``None`` means "beside this attempt's own output", which is
    # exactly right for a standalone attempt, a held preview, and a cold
    # batch's first frame -- every shape whose own traversal produced it. A
    # batch frame resumed from a held preview inherits a raster captured in
    # the held attempt's directory instead, and is handed that path
    # explicitly (see ``PreparedCaptureBatch.density_source_path``).
    density_source_path: Path | None = None

    @property
    def recovery_required(self) -> bool:
        return self.outcome is CaptureOutcome.RECOVERY_REQUIRED

    @property
    def density_calibration(self) -> DensityCalibration | None:
        """Return the validated calibration carried by this accepted journal."""

        if self.journal is None or "nikon_density_calibration" not in self.journal:
            return None
        return _validated_density_calibration(
            self.journal,
            # Not self.batch_session_id: that is this batch/round's own
            # session id, which diverges from the calibration's
            # reservation-wide identity for a resumed batch (see
            # PreparedCaptureBatch's docstring). The journal's own
            # top-level field is the reservation-wide one.
            expected_session_id=self.journal.get("density_calibration_session_id"),
        )

    @property
    def density_evidence(self) -> NikonDensityEvidence | None:
        """Return the verified reservation-preview bundle when captured here."""

        if self.journal is None or "nikon_density_evidence" not in self.journal:
            return None
        return _validated_density_evidence(
            self.journal,
            source_path=self.reservation_density_source_path,
        )

    @property
    def reservation_density_source_path(self) -> Path:
        """Return where this attempt's reservation kept its density source."""

        if self.density_source_path is not None:
            return self.density_source_path
        return _density_source_path(self.paths.output)

    @property
    def density_ownership(self) -> NikonDensityFrameOwnershipReceipt | None:
        """Return exact frame ownership, or fail closed on any identity drift."""

        if self.journal is None or "nikon_density_frame_ownership" not in self.journal:
            return None
        if (
            self.batch_session_id is None
            or self.batch_frame_index is None
            or self.batch_frame_total is None
            or self.request.selected_slot is None
        ):
            raise ValueError("density frame ownership has no accepted batch identity")
        return _validated_density_frame_ownership(
            self.journal,
            output_path=self.paths.output,
            expected_batch_session_id=self.batch_session_id,
            expected_calibration_session_id=(
                self.journal.get("density_calibration_session_id")
            ),
            expected_frame_index=self.batch_frame_index,
            expected_frame_total=self.batch_frame_total,
            expected_selected_slots=self.batch_selected_slots,
            expected_selected_slot=self.request.selected_slot,
            evidence=self.density_evidence,
        )


@dataclass(frozen=True)
class CaptureBatchResult:
    """One child process, its finalized frames, and final release receipt."""

    outcome: CaptureOutcome
    request: CaptureBatchRequest
    paths: BatchSessionPaths
    frames: tuple[CaptureAttemptResult, ...]
    returncode: int
    stopped: bool
    session_journal: dict[str, Any]
    stdout: str
    stderr: str
    # True only when the terminal frame_handler decision was
    # BatchAckAction.EJECT: the worker replayed the traced vendor eject
    # sequence before releasing, instead of releasing directly. Mutually
    # exclusive with `stopped` by construction (frame_handler never returns
    # EJECT once the stop event is set -- see Roll._scan_many).
    ejected: bool = False
    # Set only when the terminal frame_handler decision was
    # BatchAckAction.CONTINUE_HOLD: the same child that ran this batch did
    # NOT release -- it is still running, still holding the reservation,
    # parked at a fresh hold-wait boundary. Mutually exclusive with
    # `stopped`/`ejected` by construction. The caller's next
    # ``resume_held_session``/``release_held_session``/``eject_held_session``
    # call consumes this exactly like the original ``begin_held_preview``
    # session -- see ``CaptureProcessAdapter._resolve_held_after_batch``.
    held_again: HeldPreviewSession | None = None

    @property
    def density_evidence(self) -> NikonDensityEvidence | None:
        """Return the one reservation-preview bundle for owned batch frames."""

        found: list[NikonDensityEvidence] = []
        for frame in self.frames:
            item = frame.density_evidence
            if item is not None:
                found.append(item)
        evidence = tuple(found)
        if not evidence:
            return None
        first = evidence[0]
        if any(item != first for item in evidence[1:]):
            raise ValueError("batch frames disagree on Nikon density evidence")
        receipt = self.session_journal.get("nikon_density_evidence")
        if first.to_dict() != receipt:
            raise ValueError("batch density evidence disagrees with session receipt")
        return first

    @property
    def density_ownership(self) -> tuple[NikonDensityFrameOwnershipReceipt, ...]:
        """Return all frame receipts after enforcing one shared preview identity."""

        receipts: list[NikonDensityFrameOwnershipReceipt] = []
        for frame in self.frames:
            receipt = frame.density_ownership
            if receipt is None:
                raise ValueError("batch frame has no Nikon density ownership receipt")
            receipts.append(receipt)
        if not receipts:
            return ()
        first_transport_identity = receipts[0].transport_identity_sha256
        first_preview_identity = receipts[0].preview_identity_sha256
        if any(
            receipt.transport_identity_sha256 != first_transport_identity
            or receipt.preview_identity_sha256 != first_preview_identity
            for receipt in receipts[1:]
        ):
            raise ValueError("batch frames disagree on Nikon density ownership")
        evidence = self.density_evidence
        if evidence is None:
            raise ValueError("owned batch has no Nikon density preview evidence")
        for receipt in receipts:
            receipt.validate_evidence(evidence)
        return tuple(receipts)


@dataclass(frozen=True)
class HeldPreviewSession:
    """A still-running preview-and-hold child, paused at the post-preview
    transaction boundary instead of releasing.

    ``preview_attempt`` mirrors exactly what ``run_attempt`` would have
    returned for the same request -- the caller (``Roll.preview()``) reads
    it identically either way.  A session is single-use: exactly one of
    ``resume_held_session``/``release_held_session`` may be called on it,
    ever; each publishes its own hold-ack file, which fails closed
    (``FileExistsError``) on a second attempt.
    """

    preview_attempt: CaptureAttemptResult
    process: RunningBatchProcess
    directory: Path
    plan: Path
    continuation_plan: Path
    manifest: Path
    hold_job_path: Path
    hold_ack_path: Path
    hold_session_id: str
    stdout_path: Path
    stderr_path: Path
    # Where this reservation's 97-dpi density source raster actually lives.
    # ``None`` means "beside this session's own preview attempt output",
    # which is the truth for every session ``begin_held_preview`` returns:
    # that attempt is the traversal that captured it. A session handed back
    # by ``_resolve_held_after_batch`` (round two and later of the same
    # feed-to-eject reservation) has no preview attempt of its own -- its
    # ``preview_attempt`` is a synthesized view of the last completed batch
    # frame -- so that path is carried forward explicitly instead.
    density_source_path: Path | None = None

    @property
    def reservation_density_source_path(self) -> Path:
        """Return this reservation's own density source raster path."""

        if self.density_source_path is not None:
            return self.density_source_path
        return _density_source_path(self.preview_attempt.paths.output)

    @property
    def usable(self) -> bool:
        """Whether this session is actually resumable/releasable.

        False when the launch itself failed before reaching the hold
        boundary (``preview_attempt.outcome`` is not ``COMPLETE``) --
        ``Roll.preview()`` never stores an unusable session.
        """

        return self.preview_attempt.outcome is CaptureOutcome.COMPLETE


class _HeldPreviewLaunchFailed(Exception):
    """The held-preview child exited before reaching the hold boundary."""

    def __init__(self, returncode: int) -> None:
        super().__init__(
            f"held preview child exited {returncode} before reaching the "
            "hold boundary"
        )
        self.returncode = returncode


class ProcessRunner(Protocol):
    """Injectable child runner; tests can implement this without hardware."""

    def __call__(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
    ) -> subprocess.CompletedProcess[str]: ...


class RunningBatchProcess(Protocol):
    """The non-signalled subset of ``subprocess.Popen`` used by the adapter."""

    def poll(self) -> int | None: ...

    def wait(self, timeout: float | None = None) -> int: ...


class BatchProcessSpawner(Protocol):
    def __call__(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: Any,
        stderr: Any,
    ) -> RunningBatchProcess: ...


class BatchFrameHandler(Protocol):
    def __call__(self, result: CaptureAttemptResult) -> BatchAckAction: ...


def _run_subprocess(
    argv: Sequence[str],
    *,
    cwd: Path,
) -> subprocess.CompletedProcess[str]:
    """Run the worker in its own process group and collect its text output.

    ``start_new_session`` keeps an application-level SIGINT/SIGTERM from being
    forwarded to the scanner child.  The parent may record a stop request, but
    this function waits for the current worker attempt to finish naturally.
    """

    return subprocess.run(
        list(argv),
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        shell=False,
        start_new_session=True,
    )


def _spawn_batch_subprocess(
    argv: Sequence[str],
    *,
    cwd: Path,
    stdout: Any,
    stderr: Any,
) -> RunningBatchProcess:
    """Start one isolated child without exposing any signal/kill seam."""

    return subprocess.Popen(
        list(argv),
        cwd=cwd,
        stdout=stdout,
        stderr=stderr,
        shell=False,
        start_new_session=True,
    )


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_exclusive(path: Path, payload: bytes) -> None:
    with path.open("xb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def _rename_exclusive(source: Path, destination: Path) -> None:
    """Atomically publish ``source`` without replacing ``destination``.

    The former hard-link publication can block indefinitely in a protected
    macOS folder.  Both supported direct-scanner platforms expose an atomic
    no-replace rename, so use that primitive instead.  Windows ``os.rename``
    already refuses an existing destination.  Unknown platforms fail closed
    rather than risk overwriting a parent decision.
    """

    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    if sys.platform == "darwin":
        library = ctypes.CDLL(None, use_errno=True)
        rename = library.renamex_np
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        rename.restype = ctypes.c_int
        result = rename(source_bytes, destination_bytes, 0x00000004)
    elif sys.platform.startswith("linux"):
        library = ctypes.CDLL(None, use_errno=True)
        rename = library.renameat2
        rename.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        rename.restype = ctypes.c_int
        result = rename(-100, source_bytes, -100, destination_bytes, 0x00000001)
    elif os.name == "nt":
        os.rename(source, destination)
        return
    else:
        raise OSError(
            errno.ENOTSUP,
            "atomic exclusive rename is unavailable on this platform",
            str(destination),
        )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(
            error_number,
            os.strerror(error_number),
            str(destination),
        )


def _publish_exclusive(path: Path, payload: bytes) -> None:
    """Atomically publish a complete never-overwritten handshake file."""

    temporary = path.with_suffix(path.suffix + ".tmp")
    _write_exclusive(temporary, payload)
    try:
        _rename_exclusive(temporary, path)
        try:
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError:
            # The ACK is already atomically visible and the live child may
            # consume it immediately.  Reporting failure after publication
            # could allow an unobserved next frame, so durability sync is
            # best-effort at this point.
            pass
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            if not path.exists():
                raise


def _is_sha256(value: object) -> bool:
    return _lower_sha256(value)


def _worker_argv_sha256(argv: Sequence[str]) -> str:
    """Bind a bootstrap receipt to the exact worker arguments it launched."""

    if any(not isinstance(argument, str) for argument in argv):
        raise TypeError("worker argv must contain only strings")
    encoded = json.dumps(
        list(argv),
        ensure_ascii=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _read_verified_bootstrap_failure(
    *,
    status_path: Path,
    journal_path: Path,
    returncode: int,
    nonce: str,
    worker_argv_sha256: str,
) -> str | None:
    """Return a typed pre-dispatch error only for an exact child receipt.

    Any ambiguity is deliberately ignored.  In particular, a journal (even a
    malformed one), a zero exit, a symlinked or oversized marker, a marker for
    another argv, and a marker that reached ``ready`` all remain the existing
    fail-closed recovery path.
    """

    if returncode == 0 or os.path.lexists(journal_path):
        return None
    if (
        len(nonce) != 64
        or any(character not in "0123456789abcdef" for character in nonce)
        or not _lower_sha256(worker_argv_sha256)
    ):
        return None

    descriptor: int | None = None
    try:
        initial_info = status_path.lstat()
        if not stat.S_ISREG(initial_info.st_mode) or not 1 <= initial_info.st_size <= 4096:
            return None
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(status_path, flags)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= 4096:
            return None
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            raw = stream.read(4097)
    except OSError:
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if not 1 <= len(raw) <= 4096:
        return None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    required = {
        "schema_version",
        "state",
        "nonce",
        "worker_argv_sha256",
        "error_type",
        "error_message",
    }
    if not isinstance(payload, dict) or set(payload) != required:
        return None
    error_type = payload.get("error_type")
    error_message = payload.get("error_message")
    if (
        payload.get("schema_version") != WORKER_BOOTSTRAP_SCHEMA_VERSION
        or payload.get("state") != WORKER_BOOTSTRAP_FAILED
        or payload.get("nonce") != nonce
        or payload.get("worker_argv_sha256") != worker_argv_sha256
        or not isinstance(error_type, str)
        or not 1 <= len(error_type) <= 128
        or not error_type.isidentifier()
        or not isinstance(error_message, str)
        or len(error_message) > 2048
    ):
        return None
    details = error_message or "no further details"
    return (
        "CAPTURE_WORKER_BOOTSTRAP_FAILED: bundled capture worker failed before "
        f"scanner dispatch ({error_type}): {details}"
    )


class CaptureProcessAdapter:
    """Launch one hash-pinned worker process per scanner attempt.

    Calls are serialized because there is one physical transport.  Calling
    :meth:`request_stop` while a child is active only marks the adapter; the
    active attempt finishes, and the next attempt raises :class:`CaptureStopped`.
    """

    def __init__(
        self,
        *,
        worker_path: Path,
        attempts_root: Path,
        expected_worker_sha256: str,
        manifest_path: Path | None = None,
        python_executable: str = sys.executable,
        runner: ProcessRunner = _run_subprocess,
        launcher: Sequence[str] | None = None,
        bootstrap_module: str | None = None,
        verify_worker_source: bool = True,
        expected_bundle_sha256: str | None = None,
        manifest_payload: bytes | None = None,
        batch_spawner: BatchProcessSpawner = _spawn_batch_subprocess,
        batch_poll_seconds: float = 0.1,
    ) -> None:
        if not _is_sha256(expected_worker_sha256):
            raise ValueError("expected worker SHA-256 is not a lowercase digest")
        self._worker_path = Path(worker_path).expanduser().resolve()
        self._attempts_root = Path(attempts_root).expanduser().resolve()
        self._manifest_path = (
            self._worker_path.with_name("replay-first-rgbi4-manifest.json")
            if manifest_path is None
            else Path(manifest_path).expanduser().resolve()
        )
        self._python_executable = str(python_executable)
        self._launcher = (
            (self._python_executable, str(self._worker_path))
            if launcher is None
            else tuple(str(item) for item in launcher)
        )
        if not self._launcher:
            raise ValueError("capture worker launcher cannot be empty")
        if bootstrap_module is not None and (
            not isinstance(bootstrap_module, str) or not bootstrap_module
        ):
            raise ValueError("capture worker bootstrap module must be a non-empty string")
        self._bootstrap_module = bootstrap_module
        self._verify_worker_source = bool(verify_worker_source)
        self._expected_worker_sha256 = expected_worker_sha256
        if expected_bundle_sha256 is not None and not _is_sha256(
            expected_bundle_sha256
        ):
            raise ValueError(
                "expected capture bundle SHA-256 is not a lowercase digest"
            )
        self._expected_bundle_sha256 = expected_bundle_sha256
        self._manifest_payload = (
            None if manifest_payload is None else bytes(manifest_payload)
        )
        self._runner = runner
        if batch_poll_seconds < 0:
            raise ValueError("batch_poll_seconds cannot be negative")
        self._batch_spawner = batch_spawner
        self._batch_poll_seconds = float(batch_poll_seconds)
        self._stop_requested = threading.Event()
        self._stop_gate = threading.Lock()
        self._attempt_lock = threading.Lock()

    @classmethod
    def packaged(
        cls,
        attempts_root: Path,
        *,
        runner: ProcessRunner = _run_subprocess,
    ) -> CaptureProcessAdapter:
        """Bind the adapter to NegPy's verified package-owned worker bundle.

        Source checkouts and installed wheels launch an isolated ``python -m``
        child and hash every scanner-facing source first.  Frozen builds
        relaunch the signed app executable with an internal helper flag; the
        helper dispatch occurs before desktop initialization.
        """

        frozen = bool(getattr(sys, "frozen", False))
        try:
            verify_capture_bundle(require_python_sources=not frozen)
            manifest_payload = canonical_manifest_bytes()
        except (CaptureBundleIntegrityError, OSError, ValueError) as error:
            raise CaptureIntegrityError(
                f"packaged capture bundle failed validation: {error}"
            ) from error
        spec = find_spec(PACKAGED_WORKER_MODULE)
        if spec is None or spec.origin is None:
            raise CaptureIntegrityError("packaged capture worker module is missing")
        worker_path = Path(spec.origin).resolve()
        launcher = (sys.executable, CAPTURE_HELPER_FLAG) if frozen else (sys.executable,)
        return cls(
            worker_path=worker_path,
            attempts_root=attempts_root,
            expected_worker_sha256=CAPTURE_WORKER_SHA256,
            manifest_path=worker_path.with_name(CANONICAL_MANIFEST_FILENAME),
            runner=runner,
            launcher=launcher,
            bootstrap_module=None if frozen else PACKAGED_WORKER_MODULE,
            verify_worker_source=not frozen,
            expected_bundle_sha256=CAPTURE_BUNDLE_SHA256,
            manifest_payload=manifest_payload,
        )

    def request_stop(self) -> None:
        """Stop before the next attempt without touching an active child."""

        with self._stop_gate:
            self._stop_requested.set()

    def clear_stop(self) -> None:
        """Allow launches again after the caller has acknowledged a stop."""

        with self._stop_gate:
            self._stop_requested.clear()

    def prepare_batch_session(
        self,
        request: CaptureBatchRequest,
    ) -> PreparedCaptureBatch:
        """Materialize one child/session contract without launching hardware."""

        if not isinstance(request, CaptureBatchRequest):
            raise TypeError("request must be a CaptureBatchRequest")
        with self._attempt_lock:
            if self._stop_requested.is_set():
                raise CaptureStopped(
                    "capture stopped between sessions; no batch was prepared"
                )
            return self._prepare_batch_session_locked(request)

    def _prepare_batch_session_locked(
        self,
        request: CaptureBatchRequest,
    ) -> PreparedCaptureBatch:
        paths = self._prepare_batch_session_paths(request)
        self._verify_worker()
        self._materialize_pinned_plan(paths.first_plan)
        self._materialize_pinned_continuation_plan(paths.continuation_plan)
        self._materialize_pinned_manifest(paths.manifest)
        session_id = paths.directory.name
        payload = self._batch_job_bytes(request, session_id=session_id)
        _write_exclusive(paths.job, payload)
        job_sha256 = hashlib.sha256(payload).hexdigest()
        argv = self._build_batch_argv(paths, expected_job_sha256=job_sha256)
        return PreparedCaptureBatch(
            request=request,
            paths=paths,
            argv=argv,
            job_sha256=job_sha256,
            session_id=session_id,
            # Cold launch: calibration runs inside this same batch, seeded
            # from this batch's own session id (mirrors worker.py's own
            # `calibration_session_id = batch_job.session_id if batch_job
            # is not None else ...`) -- the two coincide here by
            # construction.
            calibration_session_id=session_id,
            # Cold launch: the whole-roll traversal that produces the
            # density source runs inside this batch child, interleaved with
            # its own first frame, so the raster lands beside that frame's
            # output (worker.py binds `artifact_paths` to `output_path`,
            # which main() sets to the first frame spec's output).
            density_source_path=_density_source_path(
                _batch_frame_output(paths.directory, request.frames[0].selected_slot)
            ),
        )

    def run_batch_session(
        self,
        request: CaptureBatchRequest,
        *,
        frame_handler: BatchFrameHandler,
    ) -> CaptureBatchResult:
        """Run one child and ACK only frames the parent finished consuming.

        ``frame_handler`` is the parent-owned finalization boundary.  It must
        validate, decode, promote, and optionally delete the scratch stream
        before returning.  Only then is an ACK written, which is the child's
        permission to begin the next frame.  A stop request changes that ACK
        to ``stop``; it never signals the active scanner child.
        """

        if not isinstance(request, CaptureBatchRequest):
            raise TypeError("request must be a CaptureBatchRequest")
        if not callable(frame_handler):
            raise TypeError("frame_handler must be callable")
        with self._attempt_lock:
            if self._stop_requested.is_set():
                raise CaptureStopped(
                    "capture stopped between sessions; no batch was launched"
                )
            prepared = self._prepare_batch_session_locked(request)
            if self._stop_requested.is_set():
                raise CaptureStopped("capture stopped before batch worker launch")
            return self._run_prepared_batch(prepared, frame_handler)

    def _run_prepared_batch(
        self,
        prepared: PreparedCaptureBatch,
        frame_handler: BatchFrameHandler,
    ) -> CaptureBatchResult:
        paths = prepared.paths
        process: RunningBatchProcess | None = None
        try:
            with (
                paths.stdout.open("xb") as stdout_handle,
                paths.stderr.open("xb") as stderr_handle,
            ):
                # Linearize the final stop check with process creation.  If a
                # stop wins this lock no child launches; if Popen wins, that
                # stop applies at the first durable frame boundary.
                with self._stop_gate:
                    if self._stop_requested.is_set():
                        raise CaptureStopped(
                            "capture stopped before batch worker launch"
                        )
                    process = self._batch_spawner(
                        prepared.argv,
                        cwd=paths.directory,
                        stdout=stdout_handle,
                        stderr=stderr_handle,
                    )
        except OSError as error:
            raise CaptureProcessError(
                f"could not launch batch capture worker: {error}"
            ) from error
        return self._drive_prepared_batch(prepared, process, frame_handler)

    def _drive_prepared_batch(
        self,
        prepared: PreparedCaptureBatch,
        process: RunningBatchProcess,
        frame_handler: BatchFrameHandler,
    ) -> CaptureBatchResult:
        """Drive one already-running batch child through its frames, ACKing
        only what the parent has finished consuming, until a durable
        release receipt is observed.

        Shared by a freshly spawned batch (``_run_prepared_batch``, which
        only adds the spawn step above) and a resumed held preview
        (``resume_held_session``, which reuses the still-running child
        ``begin_held_preview`` already spawned) -- the frame loop, ACK
        handshake, and terminal journal reconciliation are identical
        either way; only how ``process`` came to exist differs.

        A terminal ``BatchAckAction.CONTINUE_HOLD`` is a fourth outcome
        alongside stopped/ejected/complete: the child does not exit, so
        this method must not join it (that would hang forever waiting for
        an exit that is not coming) -- see the ``held_after`` branch below
        and ``_resolve_held_after_batch``.
        """

        paths = prepared.paths
        handled: list[CaptureAttemptResult] = []
        stopped = False
        ejected = False
        held_after = False
        stopped_unhandled_slot: int | None = None
        handler_error: BaseException | None = None
        monitor_error: BaseException | None = None
        returncode: int | None = None
        try:
            try:
                for frame_index, frame_request in enumerate(
                    prepared.request.frames,
                    start=1,
                ):
                    frame_result = self._wait_for_batch_frame(
                        process,
                        prepared,
                        frame_request,
                        frame_index=frame_index,
                    )
                    ownership_error: BaseException | None = None
                    if handled:
                        try:
                            first_ownership = handled[0].density_ownership
                            current_ownership = frame_result.density_ownership
                            if (
                                first_ownership is None
                                or current_ownership is None
                                or current_ownership.transport_identity_sha256
                                != first_ownership.transport_identity_sha256
                                or current_ownership.preview_identity_sha256
                                != first_ownership.preview_identity_sha256
                            ):
                                raise CaptureProcessError(
                                    "batch frame density preview/transport identity changed"
                                )
                        except BaseException as error:
                            ownership_error = error
                    if ownership_error is not None:
                        handler_error = ownership_error
                        action = BatchAckAction.STOP
                    else:
                        try:
                            action = frame_handler(frame_result)
                            if not isinstance(action, BatchAckAction):
                                raise TypeError(
                                    "frame_handler must return BatchAckAction"
                                )
                        except BaseException as error:
                            handler_error = error
                            action = BatchAckAction.STOP
                    handled.append(frame_result)
                    # Linearize Stop against publishing CONTINUE.  A stop
                    # that wins this lock changes the current boundary to
                    # STOP; one arriving after publication applies to the
                    # newly active frame instead.
                    with self._stop_gate:
                        if self._stop_requested.is_set():
                            action = BatchAckAction.STOP
                        self._write_batch_ack(
                            frame_result,
                            prepared,
                            action=action,
                        )
                    if action is BatchAckAction.STOP:
                        stopped = True
                        break
                    if action is BatchAckAction.EJECT:
                        ejected = True
                        break
                    if action is BatchAckAction.CONTINUE_HOLD:
                        held_after = True
                        break
            except _BatchTerminalReceiptObserved:
                # A terminal journal is only a wake-up here.  The parent
                # still joins the child below, then validates the complete
                # cleanup/release receipt before returning anything to the
                # UI.  This avoids depending exclusively on Popen.poll(),
                # which can lag behind an already-exited frozen helper.
                pass
            except BaseException as error:
                monitor_error = error
                if isinstance(error, _BatchFrameRefused):
                    stopped = True
                    stopped_unhandled_slot = error.slot
            finally:
                # Never signal or abandon a child that may own the USB
                # reservation.  With no valid ACK it will time out, clean
                # up, and release; the parent must remain here to observe
                # that receipt.
                #
                # A clean CONTINUE_HOLD exit is the one case that must NOT
                # join here: that child is not exiting at all -- it looped
                # back into a fresh hold-wait, still holding the
                # reservation -- so waiting for it would block forever.
                if not (held_after and monitor_error is None):
                    returncode, wait_error = self._wait_for_batch_exit(process)
                    if monitor_error is None:
                        monitor_error = wait_error
        except OSError as error:
            monitor_error = monitor_error or error

        if held_after and monitor_error is None:
            return self._resolve_held_after_batch(prepared, process, handled)

        if returncode is None:
            raise CaptureProcessError(
                "batch capture worker did not leave a completed child process"
            ) from monitor_error

        bootstrap_error = self._verified_bootstrap_failure(
            paths=paths,
            argv=prepared.argv,
            journal_path=paths.session_journal,
            returncode=returncode,
        )
        if bootstrap_error is not None:
            raise CaptureBatchProcessError(
                bootstrap_error,
                outcome=CaptureOutcome.BOOTSTRAP_FAILED,
                paths=paths,
                frames=handled,
                returncode=returncode,
                session_journal=None,
            ) from monitor_error

        try:
            session_journal = self._load_and_validate_batch_session_journal(
                prepared,
                returncode=returncode,
                handled=handled,
                stopped=stopped,
                stopped_unhandled_slot=stopped_unhandled_slot,
                ejected=ejected,
            )
        except BaseException as error:
            cause = error if monitor_error is None else monitor_error
            raise CaptureBatchProcessError(
                f"batch child finished without a trustworthy release receipt: {error}",
                outcome=CaptureOutcome.RECOVERY_REQUIRED,
                paths=paths,
                frames=handled,
                returncode=returncode,
                session_journal=None,
            ) from cause
        receipt_outcome = (
            CaptureOutcome.SYNCHRONIZED_REFUSAL
            if session_journal.get("recovery_required") == "none"
            else CaptureOutcome.RECOVERY_REQUIRED
        )
        outcome = CaptureOutcome.COMPLETE if returncode == 0 else receipt_outcome
        try:
            stdout = paths.stdout.read_text(encoding="utf-8", errors="replace")
            stderr = paths.stderr.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            stdout = ""
            stderr = ""
            if monitor_error is None:
                monitor_error = error
        if monitor_error is not None:
            if isinstance(monitor_error, (KeyboardInterrupt, SystemExit)):
                raise monitor_error
            raise CaptureBatchProcessError(
                "batch adapter failed after launch; child cleanup and release "
                f"completed before returning: {monitor_error}",
                outcome=receipt_outcome,
                paths=paths,
                frames=handled,
                returncode=returncode,
                session_journal=session_journal,
            ) from monitor_error
        if handler_error is not None:
            raise CaptureBatchProcessError(
                f"batch frame finalization failed after safe stop: {handler_error}",
                outcome=receipt_outcome,
                paths=paths,
                frames=handled,
                returncode=returncode,
                session_journal=session_journal,
            ) from handler_error
        return CaptureBatchResult(
            outcome=outcome,
            request=prepared.request,
            paths=paths,
            frames=tuple(handled),
            returncode=returncode,
            stopped=stopped,
            session_journal=session_journal,
            stdout=stdout,
            stderr=stderr,
            ejected=ejected,
            held_again=None,
        )

    def _resolve_held_after_batch(
        self,
        prepared: PreparedCaptureBatch,
        process: RunningBatchProcess,
        handled: Sequence[CaptureAttemptResult],
    ) -> CaptureBatchResult:
        """The terminal frame ack was CONTINUE_HOLD: this same still-running
        child persisted this batch's results, did not release, and is
        looping back into a fresh hold-wait -- reusing the exact
        preview-and-hold transaction boundary ``begin_held_preview``'s
        caller already resumes/releases/ejects, just reached from "after a
        batch" instead of "after the preview."

        Polls the batch session journal (never ``process.wait()``, which
        would block forever for a child that is not exiting) for that fresh
        hold-wait's own published rendezvous (``hold_resume``), validates it
        fail-closed exactly like ``_wait_for_held_preview_ready`` validates
        the original one, and returns a ``HeldPreviewSession`` the caller's
        next ``resume_held_session``/``release_held_session``/
        ``eject_held_session`` call redeems exactly like the original --
        those three methods are unmodified and do not know or care whether
        the session they were handed came from a preview or from a prior
        batch's own CONTINUE_HOLD.

        Every refusal below happens at the same moment
        ``begin_held_preview``'s do -- the child is alive, parked at a hold
        boundary, holding the reservation -- and raises instead of returning
        the only handle that could release it. So, exactly like
        ``begin_held_preview``, the child is best-effort released on the way
        out (``_release_unreturnable_held_child``); without that, a refused
        journal orphaned a live child on the scanner until
        ``wait_for_hold_decision``'s own half-hour timeout expired.
        """

        session_journal_path = prepared.paths.session_journal
        while True:
            if session_journal_path.is_file():
                try:
                    payload = json.loads(
                        session_journal_path.read_text(encoding="utf-8")
                    )
                except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                    payload = None
                if isinstance(payload, dict) and payload.get("status") == "held":
                    try:
                        session_journal = self._validate_held_after_batch_journal(
                            prepared, payload, handled=handled
                        )
                    except BaseException as error:
                        rendezvous = payload.get("hold_resume")
                        rendezvous = (
                            rendezvous if isinstance(rendezvous, dict) else {}
                        )
                        # Read straight off the refused payload, not off the
                        # validated journal there isn't one of: a refusal
                        # for any *other* reason still names a perfectly
                        # good rendezvous, and a refusal for a malformed
                        # rendezvous leaves no way to address the child at
                        # all -- which _release_unreturnable_held_child
                        # records rather than guesses at.
                        ack_path = rendezvous.get("hold_ack_path")
                        self._release_unreturnable_held_child(
                            process,
                            hold_ack_path=(
                                Path(ack_path)
                                if isinstance(ack_path, str) and ack_path
                                else None
                            ),
                            hold_session_id=rendezvous.get("hold_session_id"),
                            error=error,
                        )
                        raise
                    resume = session_journal["hold_resume"]
                    # A held-after-batch session's "preview attempt" is
                    # synthetic: nothing here is a preview, but
                    # HeldPreviewSession.usable only ever reads its
                    # .outcome, and release_held_session/eject_held_session
                    # only ever read its .paths.journal (as the release/
                    # eject terminal-receipt destination) -- never anything
                    # else about it. A completed batch frame's own paths
                    # are a safe, already-validated template; its journal
                    # is swapped for a fresh, dedicated, never-before-used
                    # file this round's own hold_resume just minted, so
                    # release/eject never mutates an already-finalized
                    # per-frame journal (that file is an immutable
                    # parent/child handoff -- see run_live_capture's own
                    # comment on frame_journal_finalized).
                    last = handled[-1]
                    held_again = HeldPreviewSession(
                        preview_attempt=replace(
                            last,
                            outcome=CaptureOutcome.COMPLETE,
                            paths=replace(
                                last.paths,
                                journal=Path(resume["hold_release_journal_path"]),
                            ),
                        ),
                        process=process,
                        directory=prepared.paths.directory,
                        plan=prepared.paths.first_plan,
                        continuation_plan=prepared.paths.continuation_plan,
                        manifest=prepared.paths.manifest,
                        hold_job_path=Path(resume["hold_job_path"]),
                        hold_ack_path=Path(resume["hold_ack_path"]),
                        hold_session_id=resume["hold_session_id"],
                        stdout_path=prepared.paths.stdout,
                        stderr_path=prepared.paths.stderr,
                        # Same reservation, same 97-dpi density source: this
                        # round captured no preview of its own, and neither
                        # will the next. Carried forward explicitly because
                        # the synthesized preview_attempt above is a batch
                        # frame, so the "beside my own output" fallback would
                        # point at a frame directory that has no raster in it.
                        density_source_path=prepared.density_source_path,
                    )
                    return CaptureBatchResult(
                        outcome=CaptureOutcome.COMPLETE,
                        request=prepared.request,
                        paths=prepared.paths,
                        frames=tuple(handled),
                        returncode=0,
                        stopped=False,
                        session_journal=session_journal,
                        stdout="",
                        stderr="",
                        ejected=False,
                        held_again=held_again,
                    )
            returncode = process.poll()
            if returncode is not None:
                raise CaptureProcessError(
                    f"batch child exited {returncode} instead of reaching a "
                    "fresh hold-wait after a CONTINUE_HOLD terminal ack"
                )
            if self._batch_poll_seconds:
                time.sleep(self._batch_poll_seconds)

    def _validate_held_after_batch_journal(
        self,
        prepared: PreparedCaptureBatch,
        payload: dict[str, Any],
        *,
        handled: Sequence[CaptureAttemptResult],
    ) -> dict[str, Any]:
        """Fail-closed validation for a CONTINUE_HOLD terminal ack's session
        journal: the reservation must be reported as still held (never
        released), still bound to this exact batch/session identity, and
        carrying a well-formed rendezvous (``hold_resume``) for the next
        hold-wait round. Deliberately a narrower sibling of
        ``_load_and_validate_batch_session_journal``, not a reuse of it --
        that method's own *release* invariants (``unit_released`` True,
        ``unit_release_attempts`` == 1, a status drawn from
        complete/stopped/ejected) describe a released reservation, the
        opposite of what "held" means here.

        Its *identity* invariants have no such justification, and are
        checked here too. A reservation that is about to be handed back for
        another round has to prove the same things about itself that one
        being released does -- reservation-wide calibration identity, code
        and wire-resource identity, USB topology, per-slot approvals -- or
        the hold boundary is the one place in a feed where an identity can
        drift unobserved, which is precisely the class of defect the
        2026-08-06 live session kept finding."""

        invariants: dict[str, object] = {
            "session_id": prepared.session_id,
            # Not session_id: reservation-wide, and the whole point of a
            # multi-round feed (see PreparedCaptureBatch's docstring).
            "density_calibration_session_id": prepared.calibration_session_id,
            "batch_job_sha256": prepared.job_sha256,
            "selected_slots": list(prepared.request.selected_slots),
            "capture_engine_sha256": self._expected_worker_sha256,
            "capture_bundle_sha256": (
                self._expected_bundle_sha256 or CAPTURE_BUNDLE_SHA256
            ),
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
            "manual_review_approval_sha256_by_slot": {
                str(frame.selected_slot): (
                    None
                    if frame.manual_review_approval is None
                    else frame.manual_review_approval.binding_sha256
                )
                for frame in prepared.request.frames
            },
            "reviewed_roll_fingerprint_sha256": (
                prepared.request.reviewed_fingerprint.binding_sha256
            ),
            "expected_usb_bus": prepared.request.expected_usb_bus,
            "expected_usb_address": prepared.request.expected_usb_address,
        }
        for key, expected in invariants.items():
            if payload.get(key) != expected:
                raise CaptureProcessError(
                    f"held-after-batch session journal {key}="
                    f"{payload.get(key)!r}, expected {expected!r}"
                )
        if payload.get("unit_released") is not False:
            raise CaptureProcessError(
                "held-after-batch session journal must report the "
                "reservation still held"
            )
        if payload.get("recovery_required") not in (None, "none"):
            raise CaptureProcessError(
                "held-after-batch session journal must not request recovery"
            )
        completed = payload.get("completed_slots")
        expected_completed = [result.request.selected_slot for result in handled]
        if completed != expected_completed:
            raise CaptureProcessError(
                f"held-after-batch session journal completed_slots={completed!r} "
                f"does not match the observed frame prefix {expected_completed!r}"
            )
        resume = payload.get("hold_resume")
        if (
            not isinstance(resume, dict)
            or set(resume)
            != {
                "hold_session_id",
                "hold_job_path",
                "hold_ack_path",
                "hold_release_journal_path",
            }
            or not isinstance(resume["hold_session_id"], str)
            or not 32 <= len(resume["hold_session_id"]) <= 128
            or not isinstance(resume["hold_job_path"], str)
            or not isinstance(resume["hold_ack_path"], str)
            or not isinstance(resume["hold_release_journal_path"], str)
        ):
            raise CaptureProcessError(
                "held-after-batch session journal has no valid hold_resume "
                "rendezvous"
            )
        return payload

    # -- held preview: hold a reservation across the preview/scan boundary --

    def begin_held_preview(self, request: CaptureRequest) -> HeldPreviewSession:
        """Like ``run_attempt`` for a preview request, but the worker
        persists the preview and then pauses at this transaction boundary
        instead of releasing.

        Reuses the exact spawn-then-poll-a-journal-file shape
        ``run_batch_session``/``_wait_for_batch_frame`` already use to hold
        a session between batch frames: a long-lived child is spawned via
        the same ``batch_spawner`` (not the one-shot ``runner``), and this
        call returns once its journal reaches the ``awaiting-hold-job``
        status -- the child keeps running, still holding the reservation.
        ``resume_held_session``/``release_held_session`` are the only two
        ways to make further progress with the returned session.

        Raising and returning a session are the only two outcomes, and a
        raise never leaves a child holding: if this call refuses a child
        that already reached the hold boundary, it best-effort releases and
        reaps that child on the way out (see
        ``_release_unreturnable_held_child``).  It has to happen here --
        the caller is being handed an exception instead of the session, so
        it has no handle to release anything with.
        """

        if not isinstance(request, CaptureRequest):
            raise TypeError("request must be a CaptureRequest")
        if request.mode is not CaptureMode.PREVIEW:
            raise ValueError("begin_held_preview only accepts a preview request")
        with self._attempt_lock:
            if self._stop_requested.is_set():
                raise CaptureStopped(
                    "capture stopped between attempts; no worker was launched"
                )
            paths = self._prepare_attempt_paths(request)
            self._verify_worker()
            self._materialize_pinned_plan(paths.plan)
            self._materialize_pinned_manifest(paths.manifest)
            continuation_plan_path = (
                paths.directory / CANONICAL_CONTINUATION_PLAN_FILENAME
            )
            self._materialize_pinned_continuation_plan(continuation_plan_path)
            hold_job_path = paths.directory / "hold-job.json"
            hold_ack_path = paths.directory / "hold-ack.json"
            argv = self._build_held_preview_argv(
                paths,
                continuation_plan_path=continuation_plan_path,
                hold_job_path=hold_job_path,
                expected_usb_bus=request.expected_usb_bus,
                expected_usb_address=request.expected_usb_address,
            )
            if self._stop_requested.is_set():
                raise CaptureStopped("capture stopped before worker launch")
            process: RunningBatchProcess | None = None
            try:
                with paths.stdout.open("xb") as stdout_handle, paths.stderr.open(
                    "xb"
                ) as stderr_handle:
                    with self._stop_gate:
                        if self._stop_requested.is_set():
                            raise CaptureStopped(
                                "capture stopped before worker launch"
                            )
                        process = self._batch_spawner(
                            argv,
                            cwd=paths.directory,
                            stdout=stdout_handle,
                            stderr=stderr_handle,
                        )
            except OSError as error:
                raise CaptureProcessError(
                    f"could not launch capture worker: {error}"
                ) from error

            hold_session_id: str | None = None
            try:
                journal, hold_session_id = self._wait_for_held_preview_ready(
                    process, paths
                )
                stdout = paths.stdout.read_text(encoding="utf-8", errors="replace")
                stderr = paths.stderr.read_text(encoding="utf-8", errors="replace")
                attempt = CaptureAttemptResult(
                    outcome=CaptureOutcome.COMPLETE,
                    request=request,
                    paths=paths,
                    argv=argv,
                    returncode=0,
                    stdout=stdout,
                    stderr=stderr,
                    journal=journal,
                )
                return HeldPreviewSession(
                    preview_attempt=attempt,
                    process=process,
                    directory=paths.directory,
                    plan=paths.plan,
                    continuation_plan=continuation_plan_path,
                    manifest=paths.manifest,
                    hold_job_path=hold_job_path,
                    hold_ack_path=hold_ack_path,
                    hold_session_id=hold_session_id,
                    stdout_path=paths.stdout,
                    stderr_path=paths.stderr,
                )
            except _HeldPreviewLaunchFailed:
                # The preview itself failed before ever reaching the hold
                # boundary: interpret it exactly like an ordinary failed
                # run_attempt(CaptureMode.PREVIEW) so Roll.preview() raises
                # its usual FeederParked/PyCoolscanError, never a partially
                # held session.  Only _wait_for_held_preview_ready raises
                # this, and only while the child is already gone, so there
                # is nothing here to release -- just reap it.
                returncode, _wait_error = self._wait_for_batch_exit(process)
                stdout = paths.stdout.read_text(encoding="utf-8", errors="replace")
                stderr = paths.stderr.read_text(encoding="utf-8", errors="replace")
                attempt = self._interpret_held_preview_launch_failure(
                    request=request,
                    paths=paths,
                    argv=argv,
                    returncode=returncode,
                    stdout=stdout,
                    stderr=stderr,
                )
                return HeldPreviewSession(
                    preview_attempt=attempt,
                    process=process,
                    directory=paths.directory,
                    plan=paths.plan,
                    continuation_plan=continuation_plan_path,
                    manifest=paths.manifest,
                    hold_job_path=hold_job_path,
                    hold_ack_path=hold_ack_path,
                    hold_session_id="",
                    stdout_path=paths.stdout,
                    stderr_path=paths.stderr,
                )
            except BaseException as error:
                # Everything else that can raise above does so with the
                # child still alive at the hold boundary, still blocked in
                # wait_for_hold_decision, still holding the scanner's
                # reservation -- and this call is about to raise instead of
                # returning the only handle that could ever release it.
                # Nothing downstream can clean that up (Roll.preview()'s own
                # orphan fix needs a returned session to track), so the
                # release belongs here, before the raise leaves this method.
                self._release_unreturnable_held_child(
                    process,
                    hold_ack_path=hold_ack_path,
                    # The validated id when the wait got that far, and the
                    # journal's own already-rejected value when the wait is
                    # what refused -- either way something the worker can
                    # act on, which is what unblocks the child.
                    hold_session_id=(
                        self._rejected_hold_session_id(paths)
                        if hold_session_id is None
                        else hold_session_id
                    ),
                    error=error,
                )
                raise

    def _build_held_preview_argv(
        self,
        paths: AttemptPaths,
        *,
        continuation_plan_path: Path,
        hold_job_path: Path,
        expected_usb_bus: int | None = None,
        expected_usb_address: int | None = None,
    ) -> tuple[str, ...]:
        """Build a held-preview launch the same way every other launch is
        built: through ``_worker_launcher``, with the packaged bundle
        identity asserted on the child's own command line.

        This method used to prepend ``self._launcher`` directly and omit
        ``--expected-capture-bundle-sha256``, unlike ``_build_argv`` and
        ``_build_batch_argv``. For the packaged adapter -- where
        ``_launcher`` is ``(sys.executable,)`` and the stdlib bootstrap is
        what turns that into a real worker invocation -- the result was
        ``python --plan ...``, which no interpreter accepts, so a
        source/wheel install could not start a held preview at all; and
        because the argv then failed ``_verified_bootstrap_failure``'s own
        prefix check, the failure could not even be reported as a bootstrap
        failure. A frozen build (``_bootstrap_module is None``) was
        unaffected either way, and every test adapter builds without a
        bootstrap module, which is why the suite never saw it.
        """

        worker_argv = [
            "--plan",
            str(paths.plan),
            "--manifest",
            str(paths.manifest),
            "--continuation-plan",
            str(continuation_plan_path),
            "--hold-job",
            str(hold_job_path),
            "--output",
            str(paths.output),
            "--journal",
            str(paths.journal),
            "--live",
            "--preview-and-hold",
        ]
        if expected_usb_bus is not None:
            assert expected_usb_address is not None
            worker_argv.extend(
                (
                    "--expected-usb-bus",
                    str(expected_usb_bus),
                    "--expected-usb-address",
                    str(expected_usb_address),
                )
            )
        if self._expected_bundle_sha256 is not None:
            worker_argv.extend(
                ("--expected-capture-bundle-sha256", self._expected_bundle_sha256)
            )
        return tuple(
            (
                *self._worker_launcher(
                    bootstrap_status=paths.bootstrap_status,
                    bootstrap_nonce=paths.bootstrap_nonce,
                    worker_argv=worker_argv,
                ),
                *worker_argv,
            )
        )

    def _wait_for_held_preview_ready(
        self,
        process: RunningBatchProcess,
        paths: AttemptPaths,
    ) -> tuple[dict[str, Any], str]:
        """Poll the attempt journal until the child reaches the
        ``awaiting-hold-job`` transaction boundary, mirroring
        ``_wait_for_batch_frame``'s own polling shape.  Raises
        ``_HeldPreviewLaunchFailed`` if the child exits first.

        Every ``CaptureIntegrityError`` below is raised at the opposite
        moment -- the child is alive, parked at the hold boundary, holding
        the reservation -- so the caller owes that child a release before
        letting the refusal out.  ``begin_held_preview`` is the only caller
        and does exactly that.
        """

        while True:
            if paths.journal.is_file():
                try:
                    payload = json.loads(paths.journal.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                    payload = None
                if (
                    isinstance(payload, dict)
                    and payload.get("status") == "awaiting-hold-job"
                ):
                    hold_session_id = payload.get("hold_session_id")
                    if (
                        not isinstance(hold_session_id, str)
                        or not 32 <= len(hold_session_id) <= 128
                    ):
                        raise CaptureIntegrityError(
                            "held preview journal has no valid hold_session_id"
                        )
                    if payload.get("capture_mode") != "preview-and-hold":
                        raise CaptureIntegrityError(
                            "held preview journal has the wrong capture_mode"
                        )
                    if payload.get("output") != str(paths.output.resolve()):
                        raise CaptureIntegrityError(
                            "held preview journal output path does not match "
                            "this attempt"
                        )
                    if payload.get("plan_sha256") != CANONICAL_PLAN_SHA256:
                        raise CaptureIntegrityError(
                            "held preview journal is not bound to the "
                            "canonical plan"
                        )
                    return payload, hold_session_id
            returncode = process.poll()
            if returncode is not None:
                raise _HeldPreviewLaunchFailed(returncode)
            if self._batch_poll_seconds:
                time.sleep(self._batch_poll_seconds)

    def _interpret_held_preview_launch_failure(
        self,
        *,
        request: CaptureRequest,
        paths: AttemptPaths,
        argv: tuple[str, ...],
        returncode: int,
        stdout: str,
        stderr: str,
    ) -> CaptureAttemptResult:
        """Interpret a preview-and-hold child that exited before reaching
        the hold boundary -- i.e., the preview itself failed.

        Conservatively requires recovery unless the journal cleanly reports
        a synchronized refusal, mirroring ``_interpret_result``'s own
        fail-closed default for an untrustworthy or missing journal.  This
        does not reuse ``_load_and_validate_journal`` because that method's
        ``capture_mode`` invariant is exact-matched per ``CaptureMode`` and
        does not know about ``"preview-and-hold"``; duplicating its handful
        of field checks here keeps that shared, heavily-tested validator's
        contract for every other caller completely unchanged.

        A verified pre-dispatch bootstrap receipt is checked first, exactly
        as ``_interpret_result`` does for every other launch shape --
        otherwise a held preview whose child failed before importing the
        worker is reported as RECOVERY_REQUIRED, telling the operator to
        power-cycle a scanner that was never touched, instead of the
        BOOTSTRAP_FAILED ``Roll.preview()`` already knows how to translate.
        """

        bootstrap_error = self._verified_bootstrap_failure(
            paths=paths,
            argv=argv,
            journal_path=paths.journal,
            returncode=returncode,
        )
        if bootstrap_error is not None:
            return CaptureAttemptResult(
                outcome=CaptureOutcome.BOOTSTRAP_FAILED,
                request=request,
                paths=paths,
                argv=argv,
                returncode=returncode,
                stdout=stdout,
                stderr=stderr,
                journal=None,
                journal_error=bootstrap_error,
            )
        try:
            payload = json.loads(paths.journal.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("worker journal must be a JSON object")
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            return CaptureAttemptResult(
                outcome=CaptureOutcome.RECOVERY_REQUIRED,
                request=request,
                paths=paths,
                argv=argv,
                returncode=returncode,
                stdout=stdout,
                stderr=stderr,
                journal=None,
                journal_error=str(error),
            )
        recovery = payload.get("recovery_required")
        outcome = (
            CaptureOutcome.SYNCHRONIZED_REFUSAL
            if payload.get("status") in ("failed", "interrupted")
            and recovery == "none"
            else CaptureOutcome.RECOVERY_REQUIRED
        )
        return CaptureAttemptResult(
            outcome=outcome,
            request=request,
            paths=paths,
            argv=argv,
            returncode=returncode,
            stdout=stdout,
            stderr=stderr,
            journal=payload,
        )

    def _release_unreturnable_held_child(
        self,
        process: RunningBatchProcess,
        *,
        hold_ack_path: Path | None,
        hold_session_id: Any,
        error: BaseException,
    ) -> None:
        """Best-effort release and reap of a child parked at a hold boundary
        that this adapter can no longer hand back.

        Shared by both refusal paths that leave a live child holding the
        reservation with nothing returned to release it with:
        ``begin_held_preview`` refusing the original preview/hold journal,
        and ``_resolve_held_after_batch`` refusing a CONTINUE_HOLD round's
        own held-after-batch journal.  Both raise instead of returning a
        session, so neither caller has a handle afterwards.

        Mirrors ``_release_held_session_locked`` -- publish a release
        decision, then wait the child out rather than signalling or
        abandoning it -- but deliberately never raises and never validates
        the release receipt.  ``error`` is the refusal already on its way
        out and must stay the exception the caller sees; what happened here
        is recorded on it as a note instead of replacing it.  A best-effort
        release that quietly fails is still strictly better than leaving the
        child alive and holding the scanner with no handle anywhere.

        ``hold_session_id`` is the validated id when the caller got that
        far, and whatever the child itself published (possibly ``None``)
        when validating that id is what refused.  A mismatched decision is
        not accepted by the worker -- it fails the wait closed as a
        ``SynchronizedProtocolError``, whose synchronized-cleanup path does
        still release the unit -- so publishing it unblocks a child that
        would otherwise sit on the reservation until
        ``wait_for_hold_decision``'s own half-hour timeout expired.
        ``hold_ack_path`` is ``None`` only when the refused journal did not
        name a usable rendezvous at all, which is the one case where there
        is no way to address the child; that is recorded rather than
        guessed at.

        The child is waited out only once it has actually been unblocked --
        either it was already gone, or a decision it will act on is now
        published. ``_wait_for_batch_exit`` deliberately never gives up, so
        waiting on a child still parked in ``wait_for_hold_decision`` with
        no decision to read would block this thread for that wait's full
        half-hour timeout rather than letting the refusal out.
        """

        told = "reached the hold boundary"
        unblocked = False
        try:
            if process.poll() is None:
                if hold_ack_path is None:
                    told = (
                        "could not be told to release (its journal named no "
                        "usable hold rendezvous)"
                    )
                else:
                    try:
                        self._publish_hold_ack_at(
                            hold_ack_path,
                            hold_session_id=hold_session_id,
                            action="release",
                        )
                        told = "was told to release"
                        unblocked = True
                    except FileExistsError:
                        told = "already had a hold decision published"
                        unblocked = True
                    except BaseException as publish_error:
                        told = f"could not be told to release ({publish_error})"
            else:
                told = "was already gone"
                unblocked = True
            if not unblocked:
                error.add_note(
                    f"held preview child {told}; it was left running rather "
                    "than waited on, and the scanner reservation must be "
                    "assumed still held until it times out"
                )
                return
            returncode, wait_error = self._wait_for_batch_exit(process)
        except BaseException as cleanup_error:
            error.add_note(
                f"held preview child {told} but could not be let go cleanly "
                f"({cleanup_error}); assume the scanner reservation is still held"
            )
            return
        note = f"held preview child {told} and exited {returncode}"
        if wait_error is not None:
            note += f" (reap deferred {wait_error!r})"
        error.add_note(note)

    def _rejected_hold_session_id(self, paths: AttemptPaths) -> Any:
        """Read back whatever the held child called its hold session, for a
        release decision published after that value was refused.  Returns
        ``None`` when the journal cannot be read at all -- a decision the
        worker will reject either way, which is the point: it unblocks the
        wait instead of leaving the reservation held."""

        try:
            payload = json.loads(paths.journal.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict):
            return None
        return payload.get("hold_session_id")

    def _publish_hold_ack(self, held: HeldPreviewSession, *, action: str) -> None:
        self._publish_hold_ack_at(
            held.hold_ack_path,
            hold_session_id=held.hold_session_id,
            action=action,
        )

    def _publish_hold_ack_at(
        self,
        hold_ack_path: Path,
        *,
        hold_session_id: Any,
        action: str,
    ) -> None:
        payload = {
            "action": action,
            "hold_session_id": hold_session_id,
            "schema_version": 1,
        }
        _publish_exclusive(
            hold_ack_path,
            (
                json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode("utf-8"),
        )

    def resume_held_session(
        self,
        held: HeldPreviewSession,
        request: CaptureBatchRequest,
        *,
        frame_handler: BatchFrameHandler,
    ) -> CaptureBatchResult:
        """Resume a still-held preview directly into its own reservation's
        fine scan -- no RESERVE_UNIT, no repeated command 64, no repeated
        preview.  Reuses ``_drive_prepared_batch`` (``run_batch_session``'s
        own frame loop/ACK handshake/terminal-journal reconciliation)
        unchanged; only the launch is skipped, because this child already
        completed it before pausing.
        """

        if not isinstance(request, CaptureBatchRequest):
            raise TypeError("request must be a CaptureBatchRequest")
        if not callable(frame_handler):
            raise TypeError("frame_handler must be callable")
        if not held.usable:
            raise HeldSessionExpired(
                "this held session's own preview attempt did not complete; "
                "it was never resumable"
            )
        with self._attempt_lock:
            if held.process.poll() is not None:
                raise HeldSessionExpired(
                    "the held preview's child is no longer running; the "
                    "reservation cannot be assumed to still be held"
                )
            if self._stop_requested.is_set():
                self._release_held_session_locked(held)
                raise CaptureStopped(
                    "capture stopped between sessions; the held preview was "
                    "released instead of resumed"
                )
            job_path = held.hold_job_path
            session_journal_path = held.directory / "session-journal.json"
            payload = self._batch_job_bytes(request, session_id=held.hold_session_id)
            # held.hold_session_id is this round's own (fresh, per-round)
            # identity, not the reservation-wide one this held preview's
            # density calibration is actually bound to -- see
            # PreparedCaptureBatch's own docstring. The preview attempt's
            # journal has carried the real one since preview completed
            # (worker.py writes it unconditionally, not only in batch mode).
            calibration_session_id = (
                None
                if held.preview_attempt.journal is None
                else held.preview_attempt.journal.get("density_calibration_session_id")
            )
            if not isinstance(calibration_session_id, str) or not calibration_session_id:
                self._release_held_session_locked(held)
                raise CaptureProcessError(
                    "held preview journal has no density calibration identity "
                    "to resume against"
                )
            try:
                _write_exclusive(job_path, payload)
            except OSError as error:
                self._release_held_session_locked(held)
                raise CaptureProcessError(
                    f"could not publish resumed batch job: {error}"
                ) from error
            prepared = PreparedCaptureBatch(
                request=request,
                paths=BatchSessionPaths(
                    directory=held.directory,
                    job=job_path,
                    first_plan=held.plan,
                    continuation_plan=held.continuation_plan,
                    manifest=held.manifest,
                    # No new child launches on a resume -- this is still
                    # the same already-running process begin_held_preview
                    # originally bootstrapped. Reused, not fresh, so a
                    # later bootstrap-failure check on this same argv
                    # (also reused, below) still resolves against the
                    # correct on-disk status file/nonce.
                    bootstrap_status=held.preview_attempt.paths.bootstrap_status,
                    session_journal=session_journal_path,
                    stdout=held.stdout_path,
                    stderr=held.stderr_path,
                    bootstrap_nonce=held.preview_attempt.paths.bootstrap_nonce,
                ),
                argv=held.preview_attempt.argv,
                job_sha256=hashlib.sha256(payload).hexdigest(),
                session_id=held.hold_session_id,
                calibration_session_id=calibration_session_id,
                # The reservation-wide density source raster, same
                # distinction as calibration_session_id above expressed as a
                # path: this resume captures no preview of its own, so the
                # raster it owns is the one the held preview persisted in
                # its own attempt directory -- never one beside this batch's
                # frame outputs, which is where a cold batch's is and where
                # this validator looked before (live failure 2026-08-06,
                # attempt 11: "Nikon density source artifact is missing").
                density_source_path=held.reservation_density_source_path,
            )
            try:
                self._publish_hold_ack(held, action="scan")
            except OSError as error:
                raise CaptureProcessError(
                    f"could not publish resume decision: {error}"
                ) from error
            return self._drive_prepared_batch(prepared, held.process, frame_handler)

    def release_held_session(self, held: HeldPreviewSession) -> dict[str, Any]:
        """Tell a still-held preview's child to release and exit, then wait
        for it and validate the release actually happened.

        Fail-closed: an already-dead child, or one that refuses to
        cooperate, still gets fully reaped (never signalled/abandoned)
        before this raises -- mirroring ``run_batch_session``'s own
        cleanup discipline.
        """

        if not held.usable:
            return {}
        with self._attempt_lock:
            return self._release_held_session_locked(held)

    def _release_held_session_locked(
        self,
        held: HeldPreviewSession,
    ) -> dict[str, Any]:
        if held.process.poll() is None:
            try:
                self._publish_hold_ack(held, action="release")
            except FileExistsError:
                # A resume already published its own (scan) ack first; this
                # release lost the race and is a no-op -- the resume path
                # owns the child's fate now.
                pass
            except OSError as error:
                raise CaptureProcessError(
                    f"could not publish release decision: {error}"
                ) from error
        returncode, wait_error = self._wait_for_batch_exit(held.process)
        journal_path = held.preview_attempt.paths.journal
        try:
            journal = json.loads(journal_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CaptureProcessError(
                f"held preview left no trustworthy release receipt: {error}"
            ) from (wait_error if wait_error is not None else error)
        if wait_error is not None:
            raise CaptureProcessError(
                f"held preview release wait failed: {wait_error}"
            ) from wait_error
        if not isinstance(journal, dict):
            raise CaptureProcessError(
                "held preview release journal must be an object"
            )
        if returncode != 0:
            raise CaptureProcessError(
                f"held preview child exited {returncode} during release"
            )
        for key, expected in (
            ("status", "complete"),
            ("capture_mode", "preview-and-hold"),
            ("hold_outcome", "released"),
            ("unit_released", True),
        ):
            if journal.get(key) != expected:
                raise CaptureProcessError(
                    f"held preview release journal {key}={journal.get(key)!r}, "
                    f"expected {expected!r}"
                )
        return journal

    def eject_held_session(self, held: HeldPreviewSession) -> dict[str, Any]:
        """Tell a still-held preview's child to replay the traced vendor
        end-of-session eject sequence before releasing and exiting, then
        wait for it and validate the eject actually happened.

        This is the "operator saw the preview, decided not to scan, and
        wants the strip back" case. It is deliberately the sibling of
        :meth:`release_held_session`, not a parameterization of it: the two
        publish different hold-ack actions (``"eject"`` vs ``"release"``)
        and validate a different terminal ``hold_outcome``.

        Fail-closed exactly like ``release_held_session``: an already-dead
        child, or one that refuses to cooperate, still gets fully reaped
        (never signalled/abandoned) before this raises. A suspected
        transport wedge (``worker.EjectWedgeSuspected``) raises with the
        worker's own recorded ``recovery_required`` in the message --
        callers that need to distinguish a wedge from an ordinary failure
        should match on ``POWER_CYCLE_RECOVERY`` in the raised message, the
        same idiom ``Roll`` already uses elsewhere for translating worker
        diagnoses into typed public exceptions.
        """

        if not held.usable:
            return {}
        with self._attempt_lock:
            return self._eject_held_session_locked(held)

    def _eject_held_session_locked(
        self,
        held: HeldPreviewSession,
    ) -> dict[str, Any]:
        if held.process.poll() is None:
            try:
                self._publish_hold_ack(held, action="eject")
            except FileExistsError:
                # A resume or a competing release/eject already published
                # its own ack first; this one lost the race and is a no-op.
                pass
            except OSError as error:
                raise CaptureProcessError(
                    f"could not publish eject decision: {error}"
                ) from error
        returncode, wait_error = self._wait_for_batch_exit(held.process)
        journal_path = held.preview_attempt.paths.journal
        try:
            journal = json.loads(journal_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CaptureProcessError(
                f"held preview left no trustworthy eject receipt: {error}"
            ) from (wait_error if wait_error is not None else error)
        if wait_error is not None:
            raise CaptureProcessError(
                f"held preview eject wait failed: {wait_error}"
            ) from wait_error
        if not isinstance(journal, dict):
            raise CaptureProcessError(
                "held preview eject journal must be an object"
            )
        if returncode != 0:
            recovery = journal.get("recovery_required") or "unknown"
            detail = journal.get("error") or "no error recorded"
            raise CaptureProcessError(
                f"held preview child exited {returncode} during eject "
                f"(recovery_required={recovery!r}): {detail}"
            )
        for key, expected in (
            ("status", "complete"),
            ("capture_mode", "preview-and-hold"),
            ("hold_outcome", "ejected"),
            ("unit_released", True),
        ):
            if journal.get(key) != expected:
                raise CaptureProcessError(
                    f"held preview eject journal {key}={journal.get(key)!r}, "
                    f"expected {expected!r}"
                )
        return journal

    def _wait_for_batch_exit(
        self,
        process: RunningBatchProcess,
    ) -> tuple[int, BaseException | None]:
        """Defer interruption until the scanner child has cleaned up."""

        deferred: BaseException | None = None
        while True:
            try:
                return process.wait(), deferred
            except BaseException as error:
                if deferred is None:
                    deferred = error
                try:
                    returncode = process.poll()
                except BaseException:
                    returncode = None
                if returncode is not None:
                    return returncode, deferred
                if self._batch_poll_seconds:
                    time.sleep(self._batch_poll_seconds)

    def run_attempt(self, request: CaptureRequest) -> CaptureAttemptResult:
        """Run and validate one worker attempt synchronously."""

        if not isinstance(request, CaptureRequest):
            raise TypeError("request must be a CaptureRequest")
        with self._attempt_lock:
            if self._stop_requested.is_set():
                raise CaptureStopped(
                    "capture stopped between attempts; no worker was launched"
                )
            paths = self._prepare_attempt_paths(request)
            self._verify_worker()
            self._materialize_pinned_plan(paths.plan)
            self._materialize_pinned_manifest(paths.manifest)
            argv = self._build_argv(request, paths)
            # This is deliberately the final stop check.  Once runner() starts,
            # request_stop() cannot interrupt or signal the active worker.
            if self._stop_requested.is_set():
                raise CaptureStopped("capture stopped before worker launch")
            try:
                completed = self._runner(argv, cwd=paths.directory)
            except OSError as error:
                raise CaptureProcessError(
                    f"could not launch capture worker: {error}"
                ) from error

            stdout = completed.stdout or ""
            stderr = completed.stderr or ""
            _write_exclusive(paths.stdout, stdout.encode("utf-8", errors="replace"))
            _write_exclusive(paths.stderr, stderr.encode("utf-8", errors="replace"))
            return self._interpret_result(
                request=request,
                paths=paths,
                argv=argv,
                returncode=completed.returncode,
                stdout=stdout,
                stderr=stderr,
            )

    def _prepare_attempt_paths(self, request: CaptureRequest) -> AttemptPaths:
        self._attempts_root.mkdir(parents=True, exist_ok=True)
        slot_suffix = (
            "" if request.selected_slot is None else f"-slot{request.selected_slot:02d}"
        )
        prefix = f"{request.mode.value}{slot_suffix}-"
        directory = Path(
            tempfile.mkdtemp(prefix=prefix, dir=self._attempts_root)
        ).resolve()
        return AttemptPaths(
            directory=directory,
            output=directory / "capture.bin",
            journal=directory / "journal.json",
            plan=directory / CANONICAL_PLAN_FILENAME,
            manifest=directory / CANONICAL_MANIFEST_FILENAME,
            bootstrap_status=directory / WORKER_BOOTSTRAP_STATUS_FILENAME,
            stdout=directory / "stdout.txt",
            stderr=directory / "stderr.txt",
            bootstrap_nonce=secrets.token_hex(32),
        )

    def _prepare_batch_session_paths(
        self,
        request: CaptureBatchRequest,
    ) -> BatchSessionPaths:
        self._attempts_root.mkdir(parents=True, exist_ok=True)
        first, last = request.selected_slots[0], request.selected_slots[-1]
        prefix = f"batch-slot{first:02d}-slot{last:02d}-"
        directory = Path(
            tempfile.mkdtemp(prefix=prefix, dir=self._attempts_root)
        ).resolve()
        return BatchSessionPaths(
            directory=directory,
            job=directory / "batch-job.json",
            first_plan=directory / CANONICAL_PLAN_FILENAME,
            continuation_plan=(directory / CANONICAL_CONTINUATION_PLAN_FILENAME),
            manifest=directory / CANONICAL_MANIFEST_FILENAME,
            bootstrap_status=directory / WORKER_BOOTSTRAP_STATUS_FILENAME,
            session_journal=directory / "session-journal.json",
            stdout=directory / "stdout.txt",
            stderr=directory / "stderr.txt",
            bootstrap_nonce=secrets.token_hex(32),
        )

    def _verify_worker(self) -> None:
        if self._expected_bundle_sha256 is not None:
            try:
                actual_bundle = verify_capture_bundle(
                    require_python_sources=self._verify_worker_source
                )
            except (CaptureBundleIntegrityError, OSError, ValueError) as error:
                raise CaptureIntegrityError(
                    f"capture bundle failed validation before launch: {error}"
                ) from error
            if actual_bundle != self._expected_bundle_sha256:
                raise CaptureIntegrityError(
                    "capture bundle identity changed before launch"
                )
        if not self._verify_worker_source:
            return
        if not self._worker_path.is_file():
            raise CaptureIntegrityError(
                f"capture worker is not a regular file: {self._worker_path}"
            )
        actual = _sha256_file(self._worker_path)
        if actual != self._expected_worker_sha256:
            raise CaptureIntegrityError(
                f"capture worker SHA-256 mismatch: expected {self._expected_worker_sha256}, got {actual}"
            )

    def _materialize_pinned_plan(self, destination: Path) -> None:
        try:
            payload = canonical_plan_bytes()
        except (OSError, ValueError) as error:
            raise CaptureIntegrityError(
                f"bundled capture plan failed validation: {error}"
            ) from error
        if hashlib.sha256(payload).hexdigest() != CANONICAL_PLAN_SHA256:
            raise CaptureIntegrityError(
                "bundled capture plan SHA-256 changed after validation"
            )
        _write_exclusive(destination, payload)
        actual = _sha256_file(destination)
        if actual != CANONICAL_PLAN_SHA256:
            raise CaptureIntegrityError(f"materialized plan SHA-256 mismatch: {actual}")

    def _materialize_pinned_continuation_plan(self, destination: Path) -> None:
        try:
            payload = canonical_continuation_plan_bytes()
        except (OSError, ValueError) as error:
            raise CaptureIntegrityError(
                f"bundled continuation plan failed validation: {error}"
            ) from error
        if hashlib.sha256(payload).hexdigest() != CANONICAL_CONTINUATION_PLAN_SHA256:
            raise CaptureIntegrityError(
                "bundled continuation plan SHA-256 changed after validation"
            )
        _write_exclusive(destination, payload)
        actual = _sha256_file(destination)
        if actual != CANONICAL_CONTINUATION_PLAN_SHA256:
            raise CaptureIntegrityError(
                f"materialized continuation plan SHA-256 mismatch: {actual}"
            )

    def _materialize_pinned_manifest(self, destination: Path) -> None:
        try:
            payload = (
                self._manifest_path.read_bytes()
                if self._manifest_payload is None
                else self._manifest_payload
            )
            manifest = json.loads(payload)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CaptureIntegrityError(
                f"capture manifest could not be read: {error}"
            ) from error
        if not isinstance(manifest, dict):
            raise CaptureIntegrityError("capture manifest must be a JSON object")
        if manifest.get("plan_sha256") != CANONICAL_PLAN_SHA256:
            raise CaptureIntegrityError(
                "capture manifest is not bound to the packaged canonical plan"
            )
        _write_exclusive(destination, payload)

    def _worker_launcher(
        self,
        *,
        bootstrap_status: Path,
        bootstrap_nonce: str,
        worker_argv: Sequence[str],
    ) -> tuple[str, ...]:
        """Return the only launch prefix allowed for this worker attempt.

        Source and wheel builds use the stdlib bootstrap under the bundled
        interpreter's isolated mode. Frozen builds retain their signed helper
        dispatch, which cannot safely be wrapped as a Python module process.
        """
        if self._bootstrap_module is None:
            return self._launcher
        worker_argv_sha256 = _worker_argv_sha256(worker_argv)
        return (
            *self._launcher,
            "-I",
            "-B",
            "-c",
            _PACKAGED_WORKER_BOOTSTRAP,
            str(bootstrap_status),
            self._bootstrap_module,
            bootstrap_nonce,
            worker_argv_sha256,
        )

    def _verified_bootstrap_failure(
        self,
        *,
        paths: AttemptPaths | BatchSessionPaths,
        argv: Sequence[str],
        journal_path: Path,
        returncode: int,
    ) -> str | None:
        """Validate a launcher receipt against this exact parent-owned argv."""

        if self._bootstrap_module is None:
            return None
        prefix = (
            *self._launcher,
            "-I",
            "-B",
            "-c",
            _PACKAGED_WORKER_BOOTSTRAP,
            str(paths.bootstrap_status),
            self._bootstrap_module,
            paths.bootstrap_nonce,
        )
        digest_index = len(prefix)
        if tuple(argv[:digest_index]) != prefix or len(argv) <= digest_index:
            return None
        expected_digest = _worker_argv_sha256(argv[digest_index + 1 :])
        if argv[digest_index] != expected_digest:
            return None
        return _read_verified_bootstrap_failure(
            status_path=paths.bootstrap_status,
            journal_path=journal_path,
            returncode=returncode,
            nonce=paths.bootstrap_nonce,
            worker_argv_sha256=expected_digest,
        )

    def _build_argv(
        self, request: CaptureRequest, paths: AttemptPaths
    ) -> tuple[str, ...]:
        worker_argv = [
            "--plan",
            str(paths.plan),
            "--manifest",
            str(paths.manifest),
            "--output",
            str(paths.output),
            "--journal",
            str(paths.journal),
            "--boundary-offset-rows",
            str(request.boundary_offset_rows),
            "--live",
        ]
        if request.mode is CaptureMode.PREVIEW:
            worker_argv.append("--preview-only")
        elif request.mode is CaptureMode.METER_ONLY:
            worker_argv.extend(("--frame", str(request.selected_slot), "--meter-only"))
        else:
            worker_argv.extend(
                (
                    "--frame",
                    str(request.selected_slot),
                    "--reads",
                    str(CANONICAL_FINE_READ_COUNT),
                    "--confirm-full-capture",
                )
            )
        if request.expected_usb_bus is not None:
            assert request.expected_usb_address is not None
            worker_argv.extend(("--expected-usb-bus", str(request.expected_usb_bus)))
            worker_argv.extend(("--expected-usb-address", str(request.expected_usb_address)))
        if self._expected_bundle_sha256 is not None:
            worker_argv.extend(
                ("--expected-capture-bundle-sha256", self._expected_bundle_sha256)
            )
        if "--expected-frame-count" in worker_argv:
            raise AssertionError(
                "exposure-count hints must never cross the capture boundary"
            )
        return tuple(
            (
                *self._worker_launcher(
                    bootstrap_status=paths.bootstrap_status,
                    bootstrap_nonce=paths.bootstrap_nonce,
                    worker_argv=worker_argv,
                ),
                *worker_argv,
            )
        )

    def _batch_job_bytes(
        self,
        request: CaptureBatchRequest,
        *,
        session_id: str,
    ) -> bytes:
        frames = [
            {
                "ack": f"frame-{frame.selected_slot:03d}/parent-ack.json",
                "boundary_offset_rows": frame.boundary_offset_rows,
                "journal": f"frame-{frame.selected_slot:03d}/journal.json",
                "manual_review_approval": (
                    None
                    if frame.manual_review_approval is None
                    else frame.manual_review_approval.to_payload()
                ),
                "output": f"frame-{frame.selected_slot:03d}/capture.bin",
                "slot": frame.selected_slot,
            }
            for frame in request.frames
        ]
        job = {
            "apply_all_boundary_offsets_before_first_frame": True,
            "capture_plan_sha256": CANONICAL_PLAN_SHA256,
            "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
            "expected_usb_address": request.expected_usb_address,
            "expected_usb_bus": request.expected_usb_bus,
            "exposure_override_10ns": (
                None
                if request.exposure_override_10ns is None
                else list(request.exposure_override_10ns)
            ),
            "frames": frames,
            # Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): same optional,
            # always-present, nullable-array shape as exposure_override_10ns
            # above -- see CaptureBatchRequest.manual_boundary_rows.
            "manual_boundary_rows": (
                None
                if request.manual_boundary_rows is None
                else list(request.manual_boundary_rows)
            ),
            "parent_ack_required_after_every_frame": True,
            "release_once_after_last_frame": True,
            "reviewed_roll_fingerprint": request.reviewed_fingerprint.to_payload(),
            "schema_version": 3,
            "session_id": session_id,
            "session_contract": "one-process-one-reservation",
        }
        return (json.dumps(job, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )

    def _build_batch_argv(
        self,
        paths: BatchSessionPaths,
        *,
        expected_job_sha256: str,
    ) -> tuple[str, ...]:
        worker_argv = [
            "--batch-job",
            str(paths.job),
            "--expected-batch-job-sha256",
            expected_job_sha256,
            "--plan",
            str(paths.first_plan),
            "--continuation-plan",
            str(paths.continuation_plan),
            "--manifest",
            str(paths.manifest),
            "--session-journal",
            str(paths.session_journal),
            "--live",
        ]
        if self._expected_bundle_sha256 is not None:
            worker_argv.extend(
                ("--expected-capture-bundle-sha256", self._expected_bundle_sha256)
            )
        return tuple(
            (
                *self._worker_launcher(
                    bootstrap_status=paths.bootstrap_status,
                    bootstrap_nonce=paths.bootstrap_nonce,
                    worker_argv=worker_argv,
                ),
                *worker_argv,
            )
        )

    def _batch_frame_paths(
        self,
        prepared: PreparedCaptureBatch,
        request: CaptureRequest,
    ) -> AttemptPaths:
        output = _batch_frame_output(
            prepared.paths.directory, request.selected_slot
        )
        directory = output.parent
        return AttemptPaths(
            directory=directory,
            output=output,
            journal=directory / "journal.json",
            plan=prepared.paths.first_plan,
            manifest=prepared.paths.manifest,
            bootstrap_status=prepared.paths.bootstrap_status,
            stdout=prepared.paths.stdout,
            stderr=prepared.paths.stderr,
            bootstrap_nonce=prepared.paths.bootstrap_nonce,
        )

    def _wait_for_batch_frame(
        self,
        process: RunningBatchProcess,
        prepared: PreparedCaptureBatch,
        request: CaptureRequest,
        *,
        frame_index: int,
    ) -> CaptureAttemptResult:
        paths = self._batch_frame_paths(prepared, request)
        while True:
            if paths.journal.is_file():
                try:
                    payload = json.loads(paths.journal.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                    payload = None
                if (
                    isinstance(payload, dict)
                    and payload.get("status") == "frame-complete"
                ):
                    try:
                        return self._validate_batch_frame_result(
                            prepared,
                            request,
                            paths,
                            payload,
                            frame_index=frame_index,
                        )
                    except Exception as error:
                        self._write_identifiable_batch_stop(
                            prepared,
                            request,
                            paths,
                            payload,
                            frame_index=frame_index,
                        )
                        slot = request.selected_slot
                        if slot is None:
                            raise AssertionError(
                                "validated batch request lost its slot"
                            )
                        raise _BatchFrameRefused(
                            f"batch frame {frame_index} was refused and safely "
                            f"stopped: {error}",
                            slot=slot,
                        ) from error
            if self._terminal_batch_receipt_is_published(prepared):
                raise _BatchTerminalReceiptObserved
            returncode = process.poll()
            if returncode is not None:
                raise CaptureProcessError(
                    f"batch worker exited {returncode} before frame "
                    f"{frame_index} became ready for parent finalization"
                )
            if self._batch_poll_seconds:
                time.sleep(self._batch_poll_seconds)

    @staticmethod
    def _terminal_batch_receipt_is_published(
        prepared: PreparedCaptureBatch,
    ) -> bool:
        """Return whether this exact child published a terminal failure notice.

        This deliberately does not accept the receipt as valid or release the
        caller.  It only moves the monitor to its mandatory child-join path;
        ``_load_and_validate_batch_session_journal`` remains the authority for
        cleanup, release, recovery, and provenance after the child is reaped.
        """

        try:
            payload = json.loads(
                prepared.paths.session_journal.read_text(encoding="utf-8")
            )
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return False
        return bool(
            isinstance(payload, dict)
            and payload.get("status") in ("failed", "interrupted")
            and payload.get("session_id") == prepared.session_id
            and payload.get("batch_job_sha256") == prepared.job_sha256
        )

    def _validate_batch_frame_result(
        self,
        prepared: PreparedCaptureBatch,
        request: CaptureRequest,
        paths: AttemptPaths,
        payload: dict[str, Any],
        *,
        frame_index: int,
    ) -> CaptureAttemptResult:
        expected_bytes = CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
        selected_slots = prepared.request.selected_slots
        expected_batch = {
            "frame_index": frame_index,
            "frame_total": len(selected_slots),
            "selected_slots": list(selected_slots),
            "session_id": prepared.session_id,
        }
        invariants: dict[str, object] = {
            "status": "frame-complete",
            "frame_complete": True,
            "session_reservation_retained": True,
            "unit_released": False,
            "batch_session": expected_batch,
            "capture_mode": "full",
            "requested_frame": request.selected_slot,
            "requested_boundary_offset_rows": request.boundary_offset_rows,
            "expected_reads": CANONICAL_FINE_READ_COUNT,
            "completed_reads": CANONICAL_FINE_READ_COUNT,
            "expected_bytes": expected_bytes,
            "completed_bytes": expected_bytes,
            "disk_bytes": expected_bytes,
            "output": str(paths.output.resolve()),
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
            "capture_engine_sha256": self._expected_worker_sha256,
            "manual_review_approval": (
                None
                if request.manual_review_approval is None
                else request.manual_review_approval.to_payload()
            ),
            "reviewed_roll_fingerprint_sha256": (
                prepared.request.reviewed_fingerprint.binding_sha256
            ),
            "expected_usb_bus": prepared.request.expected_usb_bus,
            "expected_usb_address": prepared.request.expected_usb_address,
        }
        if self._expected_bundle_sha256 is not None:
            invariants["capture_bundle_sha256"] = self._expected_bundle_sha256
        for key, expected in invariants.items():
            if payload.get(key) != expected:
                raise CaptureProcessError(
                    f"batch frame {frame_index} journal {key}="
                    f"{payload.get(key)!r}, expected {expected!r}"
                )
        try:
            _validated_density_calibration(
                payload,
                expected_session_id=prepared.calibration_session_id,
            )
        except ValueError as error:
            raise CaptureProcessError(
                f"batch frame {frame_index} density calibration is invalid: {error}"
            ) from error
        selection = payload.get("live_frame_selection")
        if (
            not isinstance(selection, dict)
            or selection.get("frame") != request.selected_slot
        ):
            raise CaptureProcessError(
                f"batch frame {frame_index} live frame selection is malformed"
            )
        roll_identity = selection.get("roll_identity")
        if not isinstance(roll_identity, dict) or set(roll_identity) != {
            "comparison",
            "fresh_fingerprint_sha256",
            "reviewed_fingerprint_sha256",
            "selected_slot_comparison",
        }:
            raise CaptureProcessError(
                f"batch frame {frame_index} roll identity evidence is malformed"
            )
        reviewed_sha = prepared.request.reviewed_fingerprint.binding_sha256
        if roll_identity.get("reviewed_fingerprint_sha256") != reviewed_sha:
            raise CaptureProcessError(
                f"batch frame {frame_index} reviewed roll identity changed"
            )
        if not _lower_sha256(roll_identity.get("fresh_fingerprint_sha256")):
            raise CaptureProcessError(
                f"batch frame {frame_index} fresh roll identity is malformed"
            )
        comparison = roll_identity.get("comparison")
        if (
            not isinstance(comparison, dict)
            or comparison.get("matches") is not True
            or comparison.get("reason") != "matched"
            or type(comparison.get("compared_frames")) is not int
            or comparison["compared_frames"] < 1
            or type(comparison.get("discriminative_frames")) is not int
            or type(comparison.get("minimum_discriminative_frames")) is not int
            or not 1 <= comparison["compared_frames"] <= 40
            or comparison["minimum_discriminative_frames"]
            != min(
                MIN_DISCRIMINATIVE_FRAME_COUNT,
                comparison["compared_frames"],
            )
            or not 1
            <= comparison["minimum_discriminative_frames"]
            <= comparison["discriminative_frames"]
            <= comparison["compared_frames"]
            or comparison.get("minimum_visual_log_span") != MIN_VISUAL_LOG_SPAN
            or not isinstance(comparison.get("visual_median_hamming"), (int, float))
            or comparison["visual_median_hamming"] > MAX_VISUAL_MEDIAN_HAMMING
            or type(comparison.get("visual_p90_hamming")) is not int
            or comparison["visual_p90_hamming"] > MAX_VISUAL_P90_HAMMING
            or not isinstance(
                comparison.get("frame_start_median_delta_rows"),
                (int, float),
            )
            or comparison["frame_start_median_delta_rows"]
            > MAX_FRAME_START_MEDIAN_DELTA_ROWS
            or type(comparison.get("frame_start_max_delta_rows")) is not int
            or comparison["frame_start_max_delta_rows"] > MAX_FRAME_START_DELTA_ROWS
            or not isinstance(
                comparison.get("native_origin_median_delta"),
                (int, float),
            )
            or comparison["native_origin_median_delta"] > MAX_NATIVE_ORIGIN_MEDIAN_DELTA
            or type(comparison.get("native_origin_max_delta")) is not int
            or comparison["native_origin_max_delta"] > MAX_NATIVE_ORIGIN_DELTA
            or type(comparison.get("preview_height_delta_rows")) is not int
            or comparison["preview_height_delta_rows"] > MAX_PREVIEW_HEIGHT_DELTA_ROWS
        ):
            raise CaptureProcessError(
                f"batch frame {frame_index} roll fingerprint comparison did not match"
            )
        selected_comparison = roll_identity.get("selected_slot_comparison")
        if (
            not isinstance(selected_comparison, dict)
            or selected_comparison.get("matches") is not True
            or selected_comparison.get("reason") != "matched"
            or selected_comparison.get("slot") != request.selected_slot
            or type(selected_comparison.get("visual_hamming")) is not int
            or type(selected_comparison.get("maximum_visual_hamming")) is not int
            or selected_comparison["maximum_visual_hamming"]
            != MAX_SELECTED_VISUAL_HAMMING
            or not 0
            <= selected_comparison["visual_hamming"]
            <= selected_comparison["maximum_visual_hamming"]
            or not all(
                isinstance(selected_comparison.get(key), (int, float))
                and not isinstance(selected_comparison.get(key), bool)
                and math.isfinite(float(selected_comparison[key]))
                for key in (
                    "fresh_visual_log_span",
                    "minimum_visual_log_span",
                    "reviewed_visual_log_span",
                )
            )
            or selected_comparison["fresh_visual_log_span"]
            < selected_comparison["minimum_visual_log_span"]
            or selected_comparison["minimum_visual_log_span"] != MIN_VISUAL_LOG_SPAN
            or selected_comparison["reviewed_visual_log_span"]
            < selected_comparison["minimum_visual_log_span"]
        ):
            raise CaptureProcessError(
                f"batch frame {frame_index} selected-slot roll fingerprint did not match"
            )
        if payload.get("recovery_required") not in (None, "none"):
            raise CaptureProcessError(
                f"batch frame {frame_index} requested scanner recovery"
            )
        nonce = payload.get("ack_nonce")
        if (
            not isinstance(nonce, str)
            or not 1 <= len(nonce) <= 128
            or any(
                character
                not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
                for character in nonce
            )
        ):
            raise CaptureProcessError(
                f"batch frame {frame_index} has no valid parent ACK nonce"
            )
        if not _is_sha256(payload.get("output_sha256")):
            raise CaptureProcessError(
                f"batch frame {frame_index} output SHA-256 is malformed"
            )
        if not paths.output.is_file() or paths.output.stat().st_size != expected_bytes:
            raise CaptureProcessError(
                f"batch frame {frame_index} output is missing or incomplete"
            )
        try:
            density_evidence = (
                _validated_density_evidence(
                    payload,
                    source_path=prepared.density_source_path,
                )
                if frame_index == 1
                else None
            )
            _validated_density_frame_ownership(
                payload,
                output_path=paths.output,
                expected_batch_session_id=prepared.session_id,
                expected_calibration_session_id=prepared.calibration_session_id,
                expected_frame_index=frame_index,
                expected_frame_total=len(selected_slots),
                expected_selected_slots=selected_slots,
                expected_selected_slot=request.selected_slot,
                evidence=density_evidence,
            )
        except ValueError as error:
            raise CaptureProcessError(
                f"batch frame {frame_index} density ownership is invalid: {error}"
            ) from error
        return CaptureAttemptResult(
            outcome=CaptureOutcome.COMPLETE,
            request=request,
            paths=paths,
            argv=prepared.argv,
            returncode=0,
            stdout="",
            stderr="",
            journal=payload,
            batch_session_id=prepared.session_id,
            batch_frame_index=frame_index,
            batch_frame_total=len(selected_slots),
            batch_selected_slots=selected_slots,
            # So ``CaptureAttemptResult.density_evidence`` -- which Roll's
            # own frame handler reads on every frame -- resolves the same
            # reservation raster this method just validated against, rather
            # than re-deriving a frame-local path that only a cold batch has.
            density_source_path=prepared.density_source_path,
        )

    def _write_batch_ack(
        self,
        result: CaptureAttemptResult,
        prepared: PreparedCaptureBatch,
        *,
        action: BatchAckAction,
    ) -> None:
        if result.journal is None:
            raise CaptureProcessError("cannot ACK a batch frame without a journal")
        slot = result.request.selected_slot
        if slot is None or result.batch_frame_index is None:
            raise CaptureProcessError("cannot ACK a batch frame without identity")
        ack_path = result.paths.directory / "parent-ack.json"
        payload = {
            "ack_nonce": result.journal["ack_nonce"],
            "action": action.value,
            "frame_index": result.batch_frame_index,
            "schema_version": 1,
            "session_id": prepared.session_id,
            "slot": slot,
        }
        _publish_exclusive(
            ack_path,
            (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode(
                "utf-8"
            ),
        )

    def _write_identifiable_batch_stop(
        self,
        prepared: PreparedCaptureBatch,
        request: CaptureRequest,
        paths: AttemptPaths,
        payload: dict[str, Any],
        *,
        frame_index: int,
    ) -> None:
        """Stop a bad frame promptly when its handshake identity is exact."""

        slot = request.selected_slot
        if slot is None:
            raise CaptureProcessError("batch STOP has no selected slot")
        expected_batch = {
            "frame_index": frame_index,
            "frame_total": len(prepared.request.frames),
            "selected_slots": list(prepared.request.selected_slots),
            "session_id": prepared.session_id,
        }
        if payload.get("status") != "frame-complete":
            raise CaptureProcessError("batch STOP source is not frame-complete")
        if payload.get("batch_session") != expected_batch:
            raise CaptureProcessError(
                "bad batch frame has no trustworthy session identity for STOP"
            )
        if payload.get("requested_frame") != slot:
            raise CaptureProcessError(
                "bad batch frame has no trustworthy slot identity for STOP"
            )
        nonce = payload.get("ack_nonce")
        if (
            not isinstance(nonce, str)
            or not 1 <= len(nonce) <= 128
            or any(
                character
                not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
                for character in nonce
            )
        ):
            raise CaptureProcessError(
                "bad batch frame has no trustworthy nonce for STOP"
            )
        ack = {
            "ack_nonce": nonce,
            "action": BatchAckAction.STOP.value,
            "frame_index": frame_index,
            "schema_version": 1,
            "session_id": prepared.session_id,
            "slot": slot,
        }
        _publish_exclusive(
            paths.directory / "parent-ack.json",
            (json.dumps(ack, sort_keys=True, separators=(",", ":")) + "\n").encode(
                "utf-8"
            ),
        )

    def _load_and_validate_batch_session_journal(
        self,
        prepared: PreparedCaptureBatch,
        *,
        returncode: int,
        handled: Sequence[CaptureAttemptResult],
        stopped: bool,
        stopped_unhandled_slot: int | None = None,
        ejected: bool = False,
    ) -> dict[str, Any]:
        try:
            payload = json.loads(
                prepared.paths.session_journal.read_text(encoding="utf-8")
            )
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CaptureProcessError(
                f"batch worker left no trustworthy session journal: {error}"
            ) from error
        if not isinstance(payload, dict):
            raise CaptureProcessError("batch session journal must be an object")
        expected_status = "ejected" if ejected else ("stopped" if stopped else "complete")
        expected_completed = [result.request.selected_slot for result in handled]
        if stopped_unhandled_slot is not None:
            expected_completed.append(stopped_unhandled_slot)
        invariants: dict[str, object] = {
            "session_id": prepared.session_id,
            # Not prepared.session_id: the calibration identity is
            # reservation-wide and diverges from this batch/round's own
            # session id for a resumed batch -- see PreparedCaptureBatch's
            # docstring.
            "density_calibration_session_id": prepared.calibration_session_id,
            "selected_slots": list(prepared.request.selected_slots),
            "batch_job_sha256": prepared.job_sha256,
            "capture_engine_sha256": self._expected_worker_sha256,
            "capture_bundle_sha256": (
                self._expected_bundle_sha256 or CAPTURE_BUNDLE_SHA256
            ),
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
            "manual_review_approval_sha256_by_slot": {
                str(frame.selected_slot): (
                    None
                    if frame.manual_review_approval is None
                    else frame.manual_review_approval.binding_sha256
                )
                for frame in prepared.request.frames
            },
            "reviewed_roll_fingerprint_sha256": (
                prepared.request.reviewed_fingerprint.binding_sha256
            ),
            "expected_usb_bus": prepared.request.expected_usb_bus,
            "expected_usb_address": prepared.request.expected_usb_address,
        }
        for key, expected in invariants.items():
            if payload.get(key) != expected:
                raise CaptureProcessError(
                    f"batch session journal {key}={payload.get(key)!r}, "
                    f"expected {expected!r}"
                )
        completed = payload.get("completed_slots")
        selected = list(prepared.request.selected_slots)
        if (
            not isinstance(completed, list)
            or any(
                isinstance(slot, bool) or not isinstance(slot, int)
                for slot in completed
            )
            or completed != selected[: len(completed)]
            or completed != expected_completed
        ):
            raise CaptureProcessError(
                f"batch session journal completed_slots={completed!r} does not "
                f"match the observed frame prefix {expected_completed!r}"
            )
        status = payload.get("status")
        release_attempts = payload.get("unit_release_attempts")
        unit_released = payload.get("unit_released")
        reservation_acquired = payload.get("reservation_acquired")
        recovery = payload.get("recovery_required")
        actual_usb_bus = payload.get("actual_usb_bus")
        actual_usb_address = payload.get("actual_usb_address")
        if "actual_usb_bus" not in payload or "actual_usb_address" not in payload:
            raise CaptureProcessError(
                "batch session journal has no actual USB topology receipt"
            )
        if (actual_usb_bus is None) != (actual_usb_address is None):
            raise CaptureProcessError(
                "batch session journal actual USB topology is incomplete"
            )
        if actual_usb_bus is not None and (
            isinstance(actual_usb_bus, bool)
            or not isinstance(actual_usb_bus, int)
            or isinstance(actual_usb_address, bool)
            or not isinstance(actual_usb_address, int)
            or actual_usb_bus != prepared.request.expected_usb_bus
            or actual_usb_address != prepared.request.expected_usb_address
        ):
            raise CaptureProcessError(
                "batch session journal actual_usb_bus="
                f"{actual_usb_bus!r}, actual_usb_address={actual_usb_address!r} "
                "does not match the expected USB topology"
            )
        if recovery not in ("none", POWER_CYCLE_RECOVERY):
            raise CaptureProcessError(
                f"batch session journal has unknown recovery state {recovery!r}"
            )
        if not isinstance(reservation_acquired, bool):
            raise CaptureProcessError(
                "batch session journal has no reservation-acquired receipt"
            )
        if reservation_acquired and actual_usb_bus is None:
            raise CaptureProcessError(
                "reserved batch session has no exact actual USB topology"
            )
        if returncode == 0:
            try:
                _validated_density_calibration(
                    payload,
                    expected_session_id=prepared.calibration_session_id,
                )
            except ValueError as error:
                raise CaptureProcessError(
                    f"batch session density calibration is invalid: {error}"
                ) from error
            if status != expected_status or completed != expected_completed:
                raise CaptureProcessError(
                    "completed batch session has the wrong status or frame prefix"
                )
            if (
                reservation_acquired is not True
                or release_attempts != 1
                or unit_released is not True
                or recovery != "none"
            ):
                raise CaptureProcessError(
                    "completed batch session has no successful single-release receipt"
                )
        else:
            if status not in ("failed", "interrupted"):
                raise CaptureProcessError(
                    f"failed batch session has unexpected status {status!r}"
                )
            if isinstance(release_attempts, bool) or release_attempts not in (0, 1):
                raise CaptureProcessError(
                    "failed batch session has an invalid release-attempt count"
                )
            if reservation_acquired is False:
                if completed or release_attempts != 0 or unit_released is not False:
                    raise CaptureProcessError(
                        "failed pre-reservation batch receipt is inconsistent"
                    )
                return payload
            if (
                unit_released is True
                and (release_attempts != 1 or recovery != "none")
                # An eject that suspected a transport wedge (worker.py's
                # EjectWedgeSuspected) can still cleanly release the SCSI
                # reservation -- RELEASE_UNIT and physical eject motion are
                # independent facts, and a clean release must never be read
                # as "no recovery needed" for a wedge specifically. Only
                # this one exact combination is tolerated; any other
                # recovery value together with unit_released=True still
                # fails closed below.
                and not (ejected and release_attempts == 1 and recovery == POWER_CYCLE_RECOVERY)
            ):
                raise CaptureProcessError(
                    "failed batch release receipt is internally inconsistent"
                )
            if unit_released is not True and recovery != POWER_CYCLE_RECOVERY:
                raise CaptureProcessError(
                    "failed batch without confirmed release must require recovery"
                )
        return payload

    def _interpret_result(
        self,
        *,
        request: CaptureRequest,
        paths: AttemptPaths,
        argv: tuple[str, ...],
        returncode: int,
        stdout: str,
        stderr: str,
    ) -> CaptureAttemptResult:
        bootstrap_error = self._verified_bootstrap_failure(
            paths=paths,
            argv=argv,
            journal_path=paths.journal,
            returncode=returncode,
        )
        if bootstrap_error is not None:
            return CaptureAttemptResult(
                outcome=CaptureOutcome.BOOTSTRAP_FAILED,
                request=request,
                paths=paths,
                argv=argv,
                returncode=returncode,
                stdout=stdout,
                stderr=stderr,
                journal=None,
                journal_error=bootstrap_error,
            )
        try:
            journal = self._load_and_validate_journal(paths, request, returncode)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            # A child was launched but did not leave trustworthy synchronization
            # evidence.  Conservatively require recovery instead of guessing.
            return CaptureAttemptResult(
                outcome=CaptureOutcome.RECOVERY_REQUIRED,
                request=request,
                paths=paths,
                argv=argv,
                returncode=returncode,
                stdout=stdout,
                stderr=stderr,
                journal=None,
                journal_error=str(error),
            )

        if returncode == 0:
            outcome = CaptureOutcome.COMPLETE
        elif journal["recovery_required"] == "none":
            outcome = CaptureOutcome.SYNCHRONIZED_REFUSAL
        else:
            outcome = CaptureOutcome.RECOVERY_REQUIRED
        return CaptureAttemptResult(
            outcome=outcome,
            request=request,
            paths=paths,
            argv=argv,
            returncode=returncode,
            stdout=stdout,
            stderr=stderr,
            journal=journal,
        )

    def _load_and_validate_journal(
        self,
        paths: AttemptPaths,
        request: CaptureRequest,
        returncode: int,
    ) -> dict[str, Any]:
        payload = json.loads(paths.journal.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("worker journal must be a JSON object")

        mode = {
            CaptureMode.PREVIEW: "preview-only",
            CaptureMode.METER_ONLY: "meter-only",
            CaptureMode.FULL: "full",
        }[request.mode]
        expected_reads = {
            CaptureMode.PREVIEW: 0,
            CaptureMode.METER_ONLY: METER_READ_COUNT,
            CaptureMode.FULL: CANONICAL_FINE_READ_COUNT,
        }[request.mode]
        expected_bytes = {
            CaptureMode.PREVIEW: 0,
            CaptureMode.METER_ONLY: METER_CAPTURE_BYTES,
            CaptureMode.FULL: CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
        }[request.mode]
        invariants: dict[str, object] = {
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "capture_engine_sha256": self._expected_worker_sha256,
            "output": str(paths.output.resolve()),
            "capture_mode": mode,
            "requested_frame": request.selected_slot,
            "expected_frame_count": None,
            "expected_usb_bus": request.expected_usb_bus,
            "expected_usb_address": request.expected_usb_address,
            "expected_reads": expected_reads,
            "expected_bytes": expected_bytes,
            "requested_boundary_offset_rows": request.boundary_offset_rows,
        }
        if self._expected_bundle_sha256 is not None:
            invariants["capture_bundle_sha256"] = self._expected_bundle_sha256
        for key, expected in invariants.items():
            if payload.get(key) != expected:
                raise ValueError(
                    f"worker journal {key}={payload.get(key)!r}, expected {expected!r}"
                )

        status = payload.get("status")
        recovery = payload.get("recovery_required")
        actual_usb_bus = payload.get("actual_usb_bus")
        actual_usb_address = payload.get("actual_usb_address")
        if (actual_usb_bus is None) != (actual_usb_address is None):
            raise ValueError(
                "worker journal actual USB bus/address evidence is incomplete"
            )
        if actual_usb_bus is not None:
            if (
                isinstance(actual_usb_bus, bool)
                or not isinstance(actual_usb_bus, int)
                or not 0 <= actual_usb_bus <= 999
                or isinstance(actual_usb_address, bool)
                or not isinstance(actual_usb_address, int)
                or not 1 <= actual_usb_address <= 127
            ):
                raise ValueError("worker journal actual USB topology is malformed")
            if request.expected_usb_bus is not None and (
                actual_usb_bus != request.expected_usb_bus
                or actual_usb_address != request.expected_usb_address
            ):
                raise ValueError(
                    "worker journal actual USB topology does not match the "
                    "requested device"
                )
        if request.expected_usb_bus is not None and actual_usb_bus is None:
            raise ValueError(
                "topology-bound preview has no actual USB topology receipt"
            )
        if returncode == 0:
            _validated_density_calibration(payload)
            if status != "complete":
                raise ValueError(f"worker exited zero with journal status {status!r}")
            if recovery not in (None, "none"):
                raise ValueError(f"completed worker requested recovery: {recovery!r}")
            if (
                payload.get("completed_reads") != expected_reads
                or payload.get("completed_bytes") != expected_bytes
            ):
                raise ValueError(
                    "completed worker journal has incomplete read or byte counts"
                )
            if payload.get("disk_bytes") != expected_bytes:
                raise ValueError(
                    "completed worker journal has the wrong on-disk byte count"
                )
            if payload.get("unit_released") is not True:
                raise ValueError("completed worker did not record unit release")
            if not _is_sha256(payload.get("output_sha256")):
                raise ValueError(
                    "completed worker output SHA-256 is missing or malformed"
                )
            if (
                not paths.output.is_file()
                or paths.output.stat().st_size != expected_bytes
            ):
                raise ValueError(
                    "completed worker output file is missing or has the wrong size"
                )
            if request.mode is not CaptureMode.PREVIEW:
                if (
                    payload.get("applied_boundary_offset_rows")
                    != request.boundary_offset_rows
                ):
                    raise ValueError(
                        "worker journal applied_boundary_offset_rows does not "
                        "match the requested boundary offset"
                    )
                resolved_row = payload.get("resolved_lookup_row")
                if (
                    isinstance(resolved_row, bool)
                    or not isinstance(resolved_row, int)
                    or resolved_row < 0
                ):
                    raise ValueError("worker journal has no valid resolved_lookup_row")
                resolved_origin = payload.get("resolved_native_origin")
                if (
                    isinstance(resolved_origin, bool)
                    or not isinstance(resolved_origin, int)
                    or resolved_origin < 0
                ):
                    raise ValueError(
                        "worker journal has no valid resolved_native_origin"
                    )
        else:
            if status not in ("failed", "interrupted"):
                raise ValueError(
                    f"failed worker has unexpected journal status {status!r}"
                )
            if recovery not in ("none", POWER_CYCLE_RECOVERY):
                raise ValueError(
                    f"failed worker has unknown recovery state {recovery!r}"
                )
        return payload


__all__ = [
    "BatchAckAction",
    "BatchFrameHandler",
    "BatchProcessSpawner",
    "BatchSessionPaths",
    "CaptureAttemptResult",
    "CaptureBatchProcessError",
    "CaptureBatchResult",
    "CaptureBatchRequest",
    "CAPTURE_HELPER_FLAG",
    "CaptureIntegrityError",
    "CaptureMode",
    "CaptureOutcome",
    "CaptureProcessAdapter",
    "CaptureProcessError",
    "CaptureRequest",
    "CaptureStopped",
    "HeldPreviewSession",
    "HeldSessionExpired",
    "PreparedCaptureBatch",
]
