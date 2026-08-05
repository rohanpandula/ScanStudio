"""Offline LS-5000 whole-roll preview and selection state.

The scanner worker owns USB.  This module starts only after a preview attempt
has completed and released the device.  It revalidates the persisted journal,
whole-roll index, and same-traversal transport table before exposing slots to
the application.
"""

from __future__ import annotations

import hashlib
import json
import stat
from dataclasses import dataclass, field, replace
from enum import StrEnum
from pathlib import Path
from typing import Any, Iterable, Literal, Mapping, cast

import numpy as np

from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    AttemptPaths,
    CaptureAttemptResult,
    CaptureMode,
    CaptureOutcome,
    CaptureRequest,
    ManualFrameApproval,
    ReviewedRollFingerprint,
    build_reviewed_roll_fingerprint,
)
from coolscanpy.protocol.ls5000_single_pass.density import (
    NikonDensityEvidence,
    NikonDensityExposureBinding,
    NikonDensitySourceBinding,
    density_source_geometry_for_startup_records,
)
from coolscanpy.protocol.ls5000_single_pass.plan import (
    CANONICAL_PLAN_SHA256,
)
from coolscanpy.protocol.ls5000_single_pass.roll_index import (
    INDEX_BLOCK_BYTES,
    INDEX_ROW_WORDS,
    IndexGeometry,
    NativeFrameOrigin,
    RollDetection,
    TransportMapping,
    TransportRecord,
    decode_full_index_bytes,
    derive_transport_mapping,
    detect_roll_frames,
    parse_live_transport_records_bytes,
    scanner_addressable_interval_count,
    transport_native_origin,
    validate_live_0x8e_bytes,
)
from coolscanpy.roll.controls import (
    ScanMaterial,
    validate_boundary_offset,
)


LS5000_NATIVE_RESOLUTION = 4_000
LS5000_FINE_NATIVE_HEIGHT = 5_959
SA30_ADAPTER_FRAME_CAPACITY = 40
SESSION_VERSION = 1
_PREVIEW_SLOT_SEMANTICS = "scanner-addressable preview slots; not an exposure count"
_MINIMUM_PREVIEW_STARTUP_RECORDS = 2
_PREVIEW_INDEX_PITCH = 41
_PREVIEW_READ_MAX_BYTES = 131_072
_PREVIEW_READ_FIRST_SEQUENCE = 118
_PREVIEW_READ_LAST_SEQUENCE = 165
_PREVIEW_SHORT_TABLE_STATUS = "022b4b0000000000"
_PREVIEW_BINDING_CONTRACTS: dict[int, dict[str, object]] = {
    40: {
        "mode": "canonical-40-record",
        "startup_records": 40,
        "native_height": 250_278,
        "decoded_height": 6_104,
        "expected_stream_bytes": 6_250_496,
        "read_count": 48,
        "active_read_sequence_range": [118, 165],
        "skipped_read_sequence_range": None,
        "startup_status": "0000000000000000",
    },
}


def _short_preview_binding_contract(slot_capacity: int) -> dict[str, object]:
    """Derive the sealed preview receipt for a scanner-reported short table."""

    native_height, decoded_height = density_source_geometry_for_startup_records(
        slot_capacity
    )
    expected_stream_bytes = decoded_height * INDEX_ROW_WORDS * 2
    full_reads, final_bytes = divmod(expected_stream_bytes, _PREVIEW_READ_MAX_BYTES)
    read_count = full_reads + (1 if final_bytes else 0)
    if not 1 <= read_count <= (
        _PREVIEW_READ_LAST_SEQUENCE - _PREVIEW_READ_FIRST_SEQUENCE + 1
    ):
        raise RollSessionIntegrityError(
            "short preview contract has an invalid bounded READ allocation"
        )
    last_active = _PREVIEW_READ_FIRST_SEQUENCE + read_count - 1
    return {
        "mode": (
            "canonical-prefix-37-record"
            if slot_capacity == 37
            else f"scanner-derived-{slot_capacity}-record"
        ),
        "startup_records": slot_capacity,
        "native_height": native_height,
        "decoded_height": decoded_height,
        "expected_stream_bytes": expected_stream_bytes,
        "read_count": read_count,
        "active_read_sequence_range": [_PREVIEW_READ_FIRST_SEQUENCE, last_active],
        "skipped_read_sequence_range": (
            None
            if last_active == _PREVIEW_READ_LAST_SEQUENCE
            else [last_active + 1, _PREVIEW_READ_LAST_SEQUENCE]
        ),
        "startup_status": _PREVIEW_SHORT_TABLE_STATUS,
    }


def _preview_binding_contract(slot_capacity: object) -> dict[str, object]:
    if type(slot_capacity) is not int:
        raise RollSessionIntegrityError("preview slot capacity is not an integer")
    contract = _PREVIEW_BINDING_CONTRACTS.get(slot_capacity)
    if contract is not None:
        return contract
    if not _MINIMUM_PREVIEW_STARTUP_RECORDS <= slot_capacity < SA30_ADAPTER_FRAME_CAPACITY:
        raise RollSessionIntegrityError(
            "preview startup count is outside the scanner-derived 2..40 range"
        )
    return _short_preview_binding_contract(slot_capacity)


def _immutable_array(value: np.ndarray) -> np.ndarray:
    """Copy an array onto an immutable bytes buffer."""

    contiguous = np.ascontiguousarray(value)
    return np.frombuffer(contiguous.tobytes(), dtype=contiguous.dtype).reshape(
        contiguous.shape
    )


class RollSessionError(RuntimeError):
    """A roll session could not be created from the supplied preview."""


class RollSessionIntegrityError(RollSessionError):
    """Persisted preview evidence is missing, changed, or inconsistent."""


class CaptureRoute(StrEnum):
    """Physical acquisition implementation required by a scan recipe."""

    SINGLE_PASS_RGBI4 = "single-pass-rgbi4"
    SANE_RGB4 = "sane-rgb4"


@dataclass(frozen=True)
class CaptureRecipe:
    """Material-specific full-quality capture contract."""

    dpi: int
    bit_depth: int
    rgb_samples: int
    capture_route: CaptureRoute
    capture_ir: bool
    repair_with_ir_after_import: bool


def recipe_for_material(material: ScanMaterial) -> CaptureRecipe:
    """Return the explicit acquisition route for one supported material."""

    if not isinstance(material, ScanMaterial):
        raise TypeError("material must be a ScanMaterial")
    if material is ScanMaterial.COLOR_NEGATIVE:
        return CaptureRecipe(
            dpi=4_000,
            bit_depth=16,
            rgb_samples=4,
            capture_route=CaptureRoute.SINGLE_PASS_RGBI4,
            capture_ir=True,
            repair_with_ir_after_import=True,
        )
    return CaptureRecipe(
        dpi=4_000,
        bit_depth=16,
        rgb_samples=4,
        capture_route=CaptureRoute.SANE_RGB4,
        capture_ir=False,
        repair_with_ir_after_import=False,
    )


@dataclass(frozen=True)
class ArtifactIdentity:
    """One validated, immutable reference to a persisted preview artifact."""

    path: Path
    byte_length: int
    sha256: str


@dataclass(frozen=True)
class ValidatedRollPreview:
    """Decoded whole-roll raster bound to its exact transport-table bytes."""

    preview_artifact: ArtifactIdentity
    table_artifact: ArtifactIdentity
    journal_artifact: ArtifactIdentity
    usb_topology: tuple[int, int]
    geometry: IndexGeometry
    usable_rows: int
    rgb: np.ndarray = field(repr=False, compare=False)
    transport_records: tuple[TransportRecord, ...] = field(repr=False)
    decode_report: Mapping[str, object] = field(repr=False, compare=False)

    def __post_init__(self) -> None:
        bus, address = self.usb_topology
        if (
            type(bus) is not int
            or not 0 <= bus <= 999
            or type(address) is not int
            or not 1 <= address <= 127
        ):
            raise ValueError("validated roll preview USB topology is invalid")
        if self.rgb.dtype != np.uint16 or self.rgb.ndim != 3 or self.rgb.shape[2] != 3:
            raise ValueError("validated roll preview must be an HxWx3 uint16 raster")
        object.__setattr__(self, "rgb", _immutable_array(self.rgb))


@dataclass(frozen=True)
class RollPreviewSlot:
    """One fixed-order scanner slot and its advisory preview metadata."""

    slot_id: int
    start_boundary_row: int
    end_boundary_row: int
    base_origin: NativeFrameOrigin
    thumbnail: np.ndarray = field(repr=False, compare=False)
    warnings: tuple[str, ...] = ()
    manual_review: bool = False
    boundary_offset_rows: int = 0
    # Lane C (D2): True when >=90% of the frame's height is inside the preview
    # but not all of it. None/omitted for every full-cover frame (strictly
    # additive on the wire).
    partial: bool | None = None

    def __post_init__(self) -> None:
        if type(self.slot_id) is not int or self.slot_id < 1:
            raise ValueError("slot_id must be a positive integer")
        if not 0 <= self.start_boundary_row < self.end_boundary_row:
            raise ValueError("slot boundary rows must form a nonempty interval")
        if self.base_origin.frame != self.slot_id:
            raise ValueError("slot transport origin belongs to another slot")
        validate_boundary_offset(self.slot_id, self.boundary_offset_rows)
        warnings = tuple(dict.fromkeys(self.warnings))
        if any(type(item) is not str or not item for item in warnings):
            raise ValueError("slot warnings must be nonempty strings")
        object.__setattr__(self, "warnings", warnings)
        if (
            self.thumbnail.dtype != np.uint16
            or self.thumbnail.ndim != 3
            or self.thumbnail.shape[2] != 3
        ):
            raise ValueError("slot thumbnail must be an HxWx3 uint16 array")
        object.__setattr__(self, "thumbnail", _immutable_array(self.thumbnail))

    @property
    def boundary_rows(self) -> tuple[int, int]:
        return self.start_boundary_row, self.end_boundary_row


@dataclass(frozen=True)
class RollPreviewSession:
    """Immutable application state for one validated whole-roll traversal."""

    preview: ValidatedRollPreview
    geometry: IndexGeometry
    detection: RollDetection
    mapping: TransportMapping
    slots: tuple[RollPreviewSlot, ...]
    material: ScanMaterial
    recipe: CaptureRecipe
    selected_slots: tuple[int, ...]
    warnings: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.geometry != self.preview.geometry:
            raise ValueError("session geometry differs from its preview")
        if self.recipe != recipe_for_material(self.material):
            raise ValueError("session recipe does not match its film material")
        expected_ids = tuple(range(1, len(self.slots) + 1))
        if tuple(item.slot_id for item in self.slots) != expected_ids:
            raise ValueError("roll slots must be fixed, contiguous, and 1-based")
        selected = _validate_selected_slots(self.selected_slots, len(self.slots))
        object.__setattr__(self, "selected_slots", selected)
        object.__setattr__(self, "warnings", tuple(dict.fromkeys(self.warnings)))

    def resolve_origin(
        self,
        slot_id: int,
        boundary_offset_rows: int = 0,
    ) -> NativeFrameOrigin:
        """Resolve an offset to the exact record from this preview traversal."""

        slot = self._slot(slot_id)
        validate_boundary_offset(slot_id, boundary_offset_rows)
        if boundary_offset_rows == 0:
            return slot.base_origin
        record = _resolved_transport_record(self.preview, slot, boundary_offset_rows)
        return replace(
            slot.base_origin,
            lookup_row=record.row,
            code=record.code,
            selector=record.selector,
            native_origin=record.native_origin,
            method=f"{slot.base_origin.method}+operator-boundary-offset",
            automatic=False,
        )

    def reviewed_fingerprint(self) -> ReviewedRollFingerprint:
        """Bind the exact reviewed artifacts to a reread-tolerant roll identity."""

        return build_reviewed_roll_fingerprint(
            self.preview.rgb,
            frame_intervals=tuple(slot.boundary_rows for slot in self.slots),
            frame_native_origins=tuple(
                slot.base_origin.native_origin for slot in self.slots
            ),
            source_preview_sha256=self.preview.preview_artifact.sha256,
            source_table_sha256=self.preview.table_artifact.sha256,
        )

    def approve_manual_origin(
        self,
        slot_id: int,
        boundary_offset_rows: int = 0,
    ) -> ManualFrameApproval:
        """Create an immutable receipt for one visually reviewed slot."""

        slot = self._slot(slot_id)
        if not slot.manual_review:
            raise ValueError(f"slot {slot_id} does not require manual review")
        thumbnail = reload_thumbnail(
            self.preview,
            slot,
            boundary_offset_rows,
        )
        origin = self.resolve_origin(slot_id, boundary_offset_rows)
        thumbnail_digest = hashlib.sha256()
        thumbnail_digest.update(str(thumbnail.shape).encode("ascii"))
        thumbnail_digest.update(thumbnail.dtype.str.encode("ascii"))
        thumbnail_digest.update(np.ascontiguousarray(thumbnail).tobytes())
        reasons = tuple(
            dict.fromkeys((*slot.warnings, *slot.base_origin.review_reasons))
        )
        if not reasons:
            reasons = ("transport-origin-manual-review",)
        return ManualFrameApproval(
            reviewed_fingerprint_sha256=self.reviewed_fingerprint().binding_sha256,
            slot=slot_id,
            boundary_offset_rows=boundary_offset_rows,
            thumbnail_sha256=thumbnail_digest.hexdigest(),
            reviewed_lookup_row=origin.lookup_row,
            reviewed_native_origin=origin.native_origin,
            review_reasons=reasons,
        )

    def validate_manual_approval(
        self,
        approval: ManualFrameApproval,
        *,
        slot_id: int,
        boundary_offset_rows: int,
    ) -> bool:
        """Return whether an approval exactly matches this reviewed thumbnail."""

        if not isinstance(approval, ManualFrameApproval):
            return False
        return approval == self.approve_manual_origin(
            slot_id,
            boundary_offset_rows,
        )

    def with_material(self, material: ScanMaterial) -> RollPreviewSession:
        """Return this preview with the material's explicit capture recipe."""

        return replace(
            self,
            material=material,
            recipe=recipe_for_material(material),
        )

    def with_selected_slots(
        self,
        selected_slots: Iterable[int],
    ) -> RollPreviewSession:
        """Return a session with an explicit ordered subset of physical slots."""

        selected = _validate_selected_slots(selected_slots, len(self.slots))
        return replace(self, selected_slots=selected)

    def with_boundary_offset(
        self,
        slot_id: int,
        boundary_offset_rows: int,
    ) -> RollPreviewSession:
        """Re-crop one saved thumbnail and persist its exact operator offset."""

        slot = self._slot(slot_id)
        thumbnail = reload_thumbnail(
            self.preview,
            slot,
            boundary_offset_rows,
        )
        # Lane C (D2): an offset re-crop that is a partial frame stays flagged
        # partial (None for full-cover), preserving the additive wire contract.
        partial = (
            True
            if _resolved_crop_partial(self.preview, slot, boundary_offset_rows)
            else None
        )
        updated = replace(
            slot,
            thumbnail=thumbnail,
            boundary_offset_rows=boundary_offset_rows,
            partial=partial,
        )
        slots = list(self.slots)
        slots[slot_id - 1] = updated
        return replace(self, slots=tuple(slots))

    def to_json(self) -> str:
        """Serialize operator state plus content identities, never pixel arrays."""

        payload = {
            "version": SESSION_VERSION,
            "journal": {
                "path": str(self.preview.journal_artifact.path),
                "sha256": self.preview.journal_artifact.sha256,
            },
            "preview_sha256": self.preview.preview_artifact.sha256,
            "table_sha256": self.preview.table_artifact.sha256,
            "slot_count": len(self.slots),
            "expected_frame_count": self.detection.expected_frame_count,
            "material": self.material.value,
            "selected_slots": list(self.selected_slots),
            "boundary_offsets": [item.boundary_offset_rows for item in self.slots],
        }
        return json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )

    @classmethod
    def from_json(cls, payload: str) -> RollPreviewSession:
        """Restore state only after revalidating and re-decoding source bytes."""

        session = _restore_roll_preview_session(payload)
        if not isinstance(session, cls):
            raise AssertionError("roll-session restore returned the wrong type")
        return session

    def _slot(self, slot_id: int) -> RollPreviewSlot:
        if type(slot_id) is not int or not 1 <= slot_id <= len(self.slots):
            raise ValueError(f"unknown roll slot: {slot_id!r}")
        return self.slots[slot_id - 1]


def _validate_selected_slots(values: Iterable[int], slot_count: int) -> tuple[int, ...]:
    selected = tuple(values)
    if any(type(item) is not int or not 1 <= item <= slot_count for item in selected):
        raise ValueError(f"selected slots must be integers in 1..{slot_count}")
    if tuple(sorted(set(selected))) != selected:
        raise ValueError("selected slots must be unique and increasing")
    return selected


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_file_stable(path: Path) -> bytes:
    try:
        before = path.lstat()
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise RollSessionIntegrityError(f"artifact is not a regular file: {path}")
        payload = path.read_bytes()
        after = path.lstat()
    except OSError as error:
        raise RollSessionIntegrityError(
            f"could not read artifact {path}: {error}"
        ) from error

    def identity(item: Any) -> tuple[int, int, int, int]:
        return item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns

    if identity(before) != identity(after) or len(payload) != after.st_size:
        raise RollSessionIntegrityError(f"artifact changed while it was read: {path}")
    return payload


def _load_json_object(path: Path) -> tuple[dict[str, Any], bytes]:
    payload = _read_file_stable(path)
    try:
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise RollSessionIntegrityError(
            f"invalid JSON artifact {path}: {error}"
        ) from error
    if type(value) is not dict:
        raise RollSessionIntegrityError(f"JSON artifact is not an object: {path}")
    return cast(dict[str, Any], value), payload


def _artifact_path(root: Path, value: object, label: str) -> Path:
    if type(value) is not str:
        raise RollSessionIntegrityError(f"{label} artifact path is missing")
    raw = Path(value)
    if not raw.is_absolute():
        raise RollSessionIntegrityError(f"{label} artifact path is not absolute")
    try:
        resolved = raw.resolve(strict=True)
    except OSError as error:
        raise RollSessionIntegrityError(
            f"{label} artifact path is unavailable: {error}"
        ) from error
    if resolved != raw or not resolved.is_relative_to(root):
        raise RollSessionIntegrityError(
            f"{label} artifact path escapes or aliases the attempt directory"
        )
    return resolved


def _require_mapping(parent: Mapping[str, Any], key: str) -> dict[str, Any]:
    value = parent.get(key)
    if type(value) is not dict:
        raise RollSessionIntegrityError(f"preview journal {key} is not an object")
    return cast(dict[str, Any], value)


def _require_exact(parent: Mapping[str, Any], key: str, expected: object) -> None:
    if parent.get(key) != expected:
        raise RollSessionIntegrityError(
            f"preview journal {key}={parent.get(key)!r}, expected {expected!r}"
        )


def _validated_usb_topology(journal: Mapping[str, Any]) -> tuple[int, int]:
    expected = (
        journal.get("expected_usb_bus"),
        journal.get("expected_usb_address"),
    )
    actual = (
        journal.get("actual_usb_bus"),
        journal.get("actual_usb_address"),
    )
    for label, (bus, address) in (("expected", expected), ("actual", actual)):
        if (
            type(bus) is not int
            or not 0 <= bus <= 999
            or type(address) is not int
            or not 1 <= address <= 127
        ):
            raise RollSessionIntegrityError(
                f"preview journal {label} USB topology is invalid"
            )
    if actual != expected:
        raise RollSessionIntegrityError(
            "preview journal actual USB topology differs from the expected device"
        )
    return cast(tuple[int, int], actual)


def _validate_preview_result(
    attempt: CaptureAttemptResult,
) -> tuple[
    dict[str, Any],
    ArtifactIdentity,
    bytes,
    ArtifactIdentity,
    bytes,
    ArtifactIdentity,
    int,
    tuple[int, int],
]:
    if not isinstance(attempt, CaptureAttemptResult):
        raise TypeError("attempt must be a CaptureAttemptResult")
    if (
        attempt.outcome is not CaptureOutcome.COMPLETE
        or attempt.request.mode is not CaptureMode.PREVIEW
        or attempt.request.selected_slot is not None
        or attempt.request.boundary_offset_rows != 0
        or attempt.returncode != 0
        or attempt.journal is None
        or attempt.journal_error is not None
    ):
        raise RollSessionIntegrityError(
            "roll session requires one COMPLETE preview-only capture attempt"
        )
    try:
        root = attempt.paths.directory.resolve(strict=True)
    except OSError as error:
        raise RollSessionIntegrityError(
            f"preview attempt directory is unavailable: {error}"
        ) from error
    raw_journal_path = attempt.paths.journal
    if not raw_journal_path.is_absolute() or raw_journal_path.is_symlink():
        raise RollSessionIntegrityError("preview journal path is an alias")
    journal_path = _artifact_path(root, str(raw_journal_path), "journal")
    journal, journal_bytes = _load_json_object(journal_path)
    if journal != attempt.journal:
        raise RollSessionIntegrityError(
            "persisted preview journal differs from the validated attempt result"
        )
    for key, expected in (
        ("status", "complete"),
        ("capture_mode", "preview-only"),
        ("requested_frame", None),
        ("requested_boundary_offset_rows", 0),
        ("expected_frame_count", None),
        ("expected_reads", 0),
        ("completed_reads", 0),
        ("expected_bytes", 0),
        ("completed_bytes", 0),
        ("disk_bytes", 0),
        ("unit_released", True),
        ("plan_sha256", CANONICAL_PLAN_SHA256),
        ("preview_geometry_validated_before_reads", True),
    ):
        _require_exact(journal, key, expected)
    if not isinstance(journal.get("scanner_identity"), str) or not journal.get(
        "scanner_identity"
    ).startswith("Nikon LS-5000 ED"):
        raise RollSessionIntegrityError(
            "preview journal is not from a proven Nikon LS-5000 ED"
        )
    if not _is_sha256(journal.get("capture_engine_sha256")):
        raise RollSessionIntegrityError(
            "preview journal capture-engine hash is missing"
        )
    usb_topology = _validated_usb_topology(journal)

    output_path = _artifact_path(root, journal.get("output"), "output")
    if output_path != attempt.paths.output.resolve():
        raise RollSessionIntegrityError(
            "preview journal output path differs from the attempt"
        )
    output = _read_file_stable(output_path)
    if output or journal.get("output_sha256") != hashlib.sha256(output).hexdigest():
        raise RollSessionIntegrityError(
            "preview-only output file is not the recorded empty artifact"
        )

    artifacts = _require_mapping(journal, "live_index_artifacts")
    if set(artifacts) != {"mapping", "preview", "table"}:
        raise RollSessionIntegrityError(
            "preview journal has an unexpected live-index artifact set"
        )
    preview_path = _artifact_path(root, artifacts.get("preview"), "preview")
    table_path = _artifact_path(root, artifacts.get("table"), "table")
    mapping_path = _artifact_path(root, artifacts.get("mapping"), "mapping")
    preview = _read_file_stable(preview_path)
    table = _read_file_stable(table_path)
    receipt, _mapping_bytes = _load_json_object(mapping_path)
    evidence = _require_mapping(journal, "live_index_evidence")
    journal_receipt = _require_mapping(journal, "preview_only_receipt")
    if receipt != journal_receipt:
        raise RollSessionIntegrityError(
            "persisted preview receipt differs from the journal"
        )
    preview_sha256 = hashlib.sha256(preview).hexdigest()
    table_sha256 = hashlib.sha256(table).hexdigest()
    slot_capacity = journal_receipt.get("slot_capacity_hint")
    startup = _require_mapping(journal, "live_startup_0x8f")
    preview_binding = _require_mapping(journal, "live_preview_binding")
    contract = _preview_binding_contract(slot_capacity)
    expected_binding = {
        key: value for key, value in contract.items() if key != "startup_status"
    }
    startup_status = journal.get("live_startup_0x8f_status")
    if (
        startup.get("count") != slot_capacity
        or not _is_sha256(startup.get("sha256"))
        or startup_status != contract["startup_status"]
        or preview_binding != expected_binding
        or len(preview) != contract["expected_stream_bytes"]
    ):
        raise RollSessionIntegrityError(
            "preview startup table, binding, and artifact length disagree"
        )
    startup_receipt = {
        "count": slot_capacity,
        "sha256": startup["sha256"],
        "status": startup_status,
    }
    expected_receipt = {
        "status": "preview-only-complete",
        "slot_capacity_hint": slot_capacity,
        "slot_capacity_semantics": _PREVIEW_SLOT_SEMANTICS,
        "preview_bytes": len(preview),
        "preview_sha256": preview_sha256,
        "table_bytes": len(table),
        "table_sha256": table_sha256,
        "frame_detection": "deferred-offline",
        "startup_table": startup_receipt,
        "preview_binding": expected_binding,
    }
    if receipt != expected_receipt:
        raise RollSessionIntegrityError(
            "preview receipt does not bind the saved artifacts"
        )
    if evidence != {
        "status": "persisted-before-frame-detection",
        "preview_bytes": len(preview),
        "preview_sha256": preview_sha256,
        "table_bytes": len(table),
        "table_sha256": table_sha256,
    }:
        raise RollSessionIntegrityError(
            "preview journal evidence does not bind the saved artifacts"
        )
    return (
        journal,
        ArtifactIdentity(preview_path, len(preview), preview_sha256),
        preview,
        ArtifactIdentity(table_path, len(table), table_sha256),
        table,
        ArtifactIdentity(
            journal_path, len(journal_bytes), hashlib.sha256(journal_bytes).hexdigest()
        ),
        slot_capacity,
        usb_topology,
    )


def _derive_geometry(journal: Mapping[str, Any], preview_bytes: int) -> IndexGeometry:
    startup = _require_mapping(journal, "live_startup_0x8f")
    contract = _preview_binding_contract(startup.get("count"))
    expected_binding = {
        key: value for key, value in contract.items() if key != "startup_status"
    }
    if (
        _require_mapping(journal, "live_preview_binding") != expected_binding
        or preview_bytes != contract["expected_stream_bytes"]
    ):
        raise RollSessionIntegrityError(
            "preview geometry does not match its startup-bound receipt"
        )
    windows = journal.get("preview_windows")
    if type(windows) is not list or len(windows) != 3:
        raise RollSessionIntegrityError(
            "preview journal must contain exactly three RGB windows"
        )
    normalized: list[dict[str, Any]] = []
    for value in windows:
        if type(value) is not dict:
            raise RollSessionIntegrityError("preview window is not an object")
        window = cast(dict[str, Any], value)
        if set(window) != {
            "color_id",
            "resolution",
            "origin",
            "size",
            "bit_depth",
            "density_f03_exposure_raw_10ns",
        }:
            raise RollSessionIntegrityError("preview window has an unexpected schema")
        exposure = window["density_f03_exposure_raw_10ns"]
        if type(exposure) is not int or not 1 <= exposure <= 0xFFFFFFFF:
            raise RollSessionIntegrityError(
                "preview window density f03 exposure must be a nonzero uint32"
            )
        normalized.append(window)
    if [item["color_id"] for item in normalized] != [1, 2, 3]:
        raise RollSessionIntegrityError("preview windows are not ordered RGB")
    try:
        density_evidence = _require_mapping(journal, "nikon_density_evidence")
        exposure_binding = NikonDensityExposureBinding.from_dict(
            density_evidence.get("exposure_binding")
        )
    except (RollSessionIntegrityError, ValueError) as error:
        raise RollSessionIntegrityError(
            f"preview density exposure evidence is malformed: {error}"
        ) from error
    try:
        source_binding = NikonDensitySourceBinding.from_dict(
            density_evidence.get("source_binding")
        )
    except ValueError as error:
        raise RollSessionIntegrityError(
            f"preview density source evidence is malformed: {error}"
        ) from error
    if (
        exposure_binding.session_id != journal.get("density_calibration_session_id")
        or source_binding.session_id != exposure_binding.session_id
    ):
        raise RollSessionIntegrityError(
            "preview density source/exposure evidence belongs to another reservation"
        )
    window_exposures = tuple(
        item["density_f03_exposure_raw_10ns"] for item in normalized
    )
    if window_exposures != exposure_binding.density_f03_exposures_raw_10ns:
        raise RollSessionIntegrityError(
            "preview window density f03 exposures disagree with their evidence"
        )
    if (
        source_binding.native_height != contract["native_height"]
        or source_binding.height != contract["decoded_height"]
        or density_evidence.get("source_payload_bytes")
        != contract["expected_stream_bytes"]
    ):
        raise RollSessionIntegrityError(
            "preview density source geometry disagrees with its startup binding"
        )
    first = normalized[0]
    geometry_fields = ("resolution", "origin", "size", "bit_depth")
    for item in normalized[1:]:
        if tuple(item[key] for key in geometry_fields) != tuple(
            first[key] for key in geometry_fields
        ):
            raise RollSessionIntegrityError(
                "preview RGB windows have inconsistent geometry"
            )
    if (
        first["resolution"] != [97, 97]
        or first["origin"] != [0, 0]
        or first["size"] != [3_946, contract["native_height"]]
        or first["bit_depth"] != 16
    ):
        raise RollSessionIntegrityError(
            "preview window is not the proven LS-5000 roll index"
        )
    requested_resolution = 97
    pitch = LS5000_NATIVE_RESOLUTION // requested_resolution
    row_bytes = INDEX_ROW_WORDS * 2
    if preview_bytes % INDEX_BLOCK_BYTES or preview_bytes % row_bytes:
        raise RollSessionIntegrityError(
            "preview byte length is not a complete block allocation"
        )
    height = preview_bytes // row_bytes
    native_width, native_height = cast(list[int], first["size"])
    geometry = IndexGeometry(
        requested_resolution=requested_resolution,
        native_resolution=LS5000_NATIVE_RESOLUTION,
        pitch=pitch,
        native_width=native_width,
        native_height=native_height,
        width=native_width // pitch,
        height=height,
        block_bytes=INDEX_BLOCK_BYTES,
        expected_stream_bytes=preview_bytes,
    )
    if (
        geometry.width != 96
        or geometry.height != geometry.native_height // geometry.pitch
        or geometry.height % 2
        or geometry.native_height != contract["native_height"]
        or geometry.height != contract["decoded_height"]
        or geometry.expected_stream_bytes != contract["expected_stream_bytes"]
    ):
        raise RollSessionIntegrityError(
            "preview geometry does not match the LS-5000 RGB96 allocation"
        )
    return geometry


def _validated_preview_density_evidence(
    attempt: CaptureAttemptResult,
    journal: Mapping[str, Any],
    preview_bytes: bytes,
    geometry: IndexGeometry,
) -> NikonDensityEvidence:
    """Replay the full density receipt and bind it to this preview artifact."""

    try:
        evidence = attempt.density_evidence
    except (OSError, ValueError) as error:
        raise RollSessionIntegrityError(
            f"preview density evidence does not replay from its source: {error}"
        ) from error
    if not isinstance(evidence, NikonDensityEvidence):
        raise RollSessionIntegrityError("preview density evidence is unavailable")
    source = evidence.source_binding
    preview_sha256 = hashlib.sha256(preview_bytes).hexdigest()
    expected_session_id = journal.get("density_calibration_session_id")
    expected_attempt_id = attempt.paths.directory.name
    expected_scan_identity = (
        f"{expected_session_id}:density-97dpi:{preview_sha256}"
    )
    if (
        evidence.source_payload != preview_bytes
        or source.session_id != expected_session_id
        or source.capture_attempt_id != expected_attempt_id
        or source.scan_identity != expected_scan_identity
        or source.native_height != geometry.native_height
        or source.height != geometry.height
        or source.wire_sha256 != preview_sha256
        or evidence.result.source_native_height != geometry.native_height
        or evidence.result.source_height != geometry.height
    ):
        raise RollSessionIntegrityError(
            "preview density provenance disagrees with the startup-bound artifact"
        )
    return evidence


# Lane C (D2): a frame whose crop overlaps the preview such that >= this
# fraction of its height is inside (but not all of it) is exposed flagged
# partial instead of refused. Strictly below it stays REFEED_REQUIRED.
PARTIAL_FRAME_MIN_COVERAGE = 0.90


def _crop_coverage(start: int, end: int, preview_height: int) -> float:
    """Fraction of crop ``[start, end)`` that lies inside ``[0, preview_height)``.

    ``1.0`` for a fully-inside frame; lower when the frame runs off the top or
    bottom edge of the preview. ``0.0`` for an empty/invalid crop.
    """
    if end <= start:
        return 0.0
    inside_top = min(max(0, start), preview_height)
    inside_bottom = min(max(0, end), preview_height)
    inside = max(0, inside_bottom - inside_top)
    return inside / (end - start)


def _crop_state(
    start: int, end: int, preview_height: int
) -> Literal["full", "partial", "refeed"]:
    """Classify a frame crop against the preview (Lane C, D2)."""
    coverage = _crop_coverage(start, end, preview_height)
    if coverage < PARTIAL_FRAME_MIN_COVERAGE:
        return "refeed"
    if coverage < 1.0:
        return "partial"
    return "full"


def _thumbnail(rgb: np.ndarray, start: int, end: int) -> np.ndarray:
    start = max(0, min(start, len(rgb)))
    end = max(start, min(end, len(rgb)))
    if end <= start:
        raise RollSessionError("preview slot crop is empty")
    return _immutable_array(np.asarray(rgb[start:end, :, :], dtype=np.uint16))


def _resolved_transport_record(
    preview: ValidatedRollPreview,
    slot: RollPreviewSlot,
    boundary_offset_rows: int,
) -> TransportRecord:
    """Resolve ``boundary_offset_rows`` against the saved 0x8e table and
    re-verify the resulting record's identity.

    Shared by ``resolve_origin`` (returns early for a zero offset, then
    rebuilds a ``NativeFrameOrigin`` from this record) and
    ``reload_thumbnail`` (uses the row delta to re-crop the preview raster).
    """

    resolved_row = slot.base_origin.lookup_row + boundary_offset_rows
    records = preview.transport_records
    if not 0 <= resolved_row < len(records):
        raise RollSessionError(
            f"slot {slot.slot_id} boundary offset resolves outside the saved 0x8e table"
        )
    record = records[resolved_row]
    if (
        record.row != resolved_row
        or transport_native_origin(record.code, record.selector) != record.native_origin
    ):
        raise RollSessionIntegrityError(
            f"slot {slot.slot_id} resolved transport record has an invalid identity"
        )
    return record


def _resolved_crop_bounds(
    preview: ValidatedRollPreview,
    slot: RollPreviewSlot,
    boundary_offset_rows: int,
) -> tuple[int, int]:
    """Resolve the row delta and return the re-crop ``(start, end)`` bounds."""

    validate_boundary_offset(slot.slot_id, boundary_offset_rows)
    record = _resolved_transport_record(preview, slot, boundary_offset_rows)
    row_delta = record.row - slot.base_origin.lookup_row
    return slot.start_boundary_row + row_delta, slot.end_boundary_row + row_delta


def _resolved_crop_partial(
    preview: ValidatedRollPreview,
    slot: RollPreviewSlot,
    boundary_offset_rows: int,
) -> bool:
    """True when the resolved re-crop is a Lane C partial frame (Lane C, D2)."""

    start, end = _resolved_crop_bounds(preview, slot, boundary_offset_rows)
    return _crop_state(start, end, len(preview.rgb)) == "partial"


def reload_thumbnail(
    preview: ValidatedRollPreview,
    slot: RollPreviewSlot,
    boundary_offset_rows: int,
) -> np.ndarray:
    """Re-crop one slot from the saved whole-roll index at an exact 0x8e row.

    This does not shift an already-rendered thumbnail.  The selected offset is
    first resolved through the raw table captured during the same traversal;
    the original decoded RGB96 preview is then cropped again at that row delta.

    Lane C (D2): a re-crop with >=90% of its height inside the preview is
    exposed (clamped) as a partial frame; strictly below stays REFEED_REQUIRED.
    """

    if not isinstance(preview, ValidatedRollPreview):
        raise TypeError("preview must be a ValidatedRollPreview")
    if not isinstance(slot, RollPreviewSlot):
        raise TypeError("slot must be a RollPreviewSlot")
    start, end = _resolved_crop_bounds(preview, slot, boundary_offset_rows)
    if _crop_state(start, end, len(preview.rgb)) == "refeed":
        raise RollSessionError(
            f"slot {slot.slot_id} boundary offset lies outside the saved preview"
        )
    return _thumbnail(preview.rgb, start, end)


def _slot_warnings(
    slot_id: int,
    interval: Any,
    origin: NativeFrameOrigin,
    detection: RollDetection,
) -> tuple[str, ...]:
    warnings = [*interval.review_reasons, *origin.review_reasons]
    if detection.content_end_candidates:
        first_end = min(detection.content_end_candidates)
        last_end = max(detection.content_end_candidates)
        if (
            len(detection.content_end_candidates) > 1
            and first_end <= slot_id <= last_end
        ):
            warnings.append("ambiguous-content-tail-boundary")
        if slot_id > last_end:
            warnings.append("beyond-advisory-content-end")
    return tuple(dict.fromkeys(warnings))


def build_roll_preview_session(
    attempt: CaptureAttemptResult,
    *,
    material: ScanMaterial = ScanMaterial.COLOR_NEGATIVE,
    selected_slots: Iterable[int] = (),
    expected_frame_count: int | None = None,
) -> RollPreviewSession:
    """Validate and decode a completed worker preview into fixed-order slots."""

    if not isinstance(material, ScanMaterial):
        raise TypeError("material must be a ScanMaterial")
    (
        journal,
        preview_artifact,
        preview_bytes,
        table_artifact,
        table_bytes,
        journal_artifact,
        capacity,
        usb_topology,
    ) = _validate_preview_result(attempt)
    geometry = _derive_geometry(journal, len(preview_bytes))
    _validated_preview_density_evidence(
        attempt,
        journal,
        preview_bytes,
        geometry,
    )
    validated_table, usable_rows = validate_live_0x8e_bytes(
        table_bytes,
        geometry.height,
    )
    rgb, known, decode_report = decode_full_index_bytes(
        preview_bytes,
        geometry,
        usable_rows=usable_rows,
    )
    detection = detect_roll_frames(
        rgb,
        known,
        nominal_frame_rows=LS5000_FINE_NATIVE_HEIGHT // geometry.pitch,
        expected_frame_count=expected_frame_count,
    )
    if detection.alignment_confidence == "low":
        raise RollSessionError("roll preview physical alignment confidence is low")
    records = parse_live_transport_records_bytes(
        validated_table,
        maximum_rows=geometry.height,
    )
    scanner_frame_count = scanner_addressable_interval_count(detection.intervals)
    mapping = derive_transport_mapping(
        detection.boundaries,
        scanner_frame_count,
        records,
    )
    slot_count = min(capacity, scanner_frame_count, len(mapping.origins))
    if slot_count < 1:
        raise RollSessionError("roll preview produced no scanner-addressable slots")
    preview = ValidatedRollPreview(
        preview_artifact=preview_artifact,
        table_artifact=table_artifact,
        journal_artifact=journal_artifact,
        usb_topology=usb_topology,
        geometry=geometry,
        usable_rows=usable_rows,
        rgb=rgb,
        transport_records=records,
        decode_report=decode_report,
    )
    slots = []
    for interval, origin in zip(
        detection.intervals[:slot_count],
        mapping.origins[:slot_count],
    ):
        warnings = _slot_warnings(interval.frame, interval, origin, detection)
        # Lane C (D2): expose >=90%-covered frames flagged partial instead of
        # refusing them; strictly-below-90% stays REFEED_REQUIRED.
        state = _crop_state(interval.start_row, interval.end_row, len(rgb))
        if state == "refeed":
            raise RollSessionError(
                f"frame {interval.frame} has <"
                f"{int(PARTIAL_FRAME_MIN_COVERAGE * 100)}% of its height inside "
                "the preview; refeed and retry"
            )
        slots.append(
            RollPreviewSlot(
                slot_id=interval.frame,
                start_boundary_row=interval.start_row,
                end_boundary_row=interval.end_row,
                base_origin=origin,
                thumbnail=_thumbnail(rgb, interval.start_row, interval.end_row),
                warnings=warnings,
                manual_review=bool(
                    interval.manual_review or origin.manual_review or warnings
                ),
                partial=(True if state == "partial" else None),
            )
        )
    selected = _validate_selected_slots(selected_slots, len(slots))
    return RollPreviewSession(
        preview=preview,
        geometry=geometry,
        detection=detection,
        mapping=mapping,
        slots=tuple(slots),
        material=material,
        recipe=recipe_for_material(material),
        selected_slots=selected,
        warnings=tuple(detection.warnings),
    )


def _restore_roll_preview_session(payload: str) -> RollPreviewSession:
    if type(payload) is not str:
        raise TypeError("roll session JSON must be a string")
    try:
        value = json.loads(payload, object_pairs_hook=_reject_duplicate_keys)
    except (json.JSONDecodeError, ValueError) as error:
        raise RollSessionIntegrityError(
            f"invalid roll session JSON: {error}"
        ) from error
    if type(value) is not dict:
        raise RollSessionIntegrityError("roll session JSON must be an object")
    state = cast(dict[str, Any], value)
    expected_keys = {
        "version",
        "journal",
        "preview_sha256",
        "table_sha256",
        "slot_count",
        "expected_frame_count",
        "material",
        "selected_slots",
        "boundary_offsets",
    }
    if set(state) != expected_keys or state.get("version") != SESSION_VERSION:
        raise RollSessionIntegrityError("roll session JSON has an unsupported schema")
    journal_identity = state.get("journal")
    if type(journal_identity) is not dict or set(journal_identity) != {
        "path",
        "sha256",
    }:
        raise RollSessionIntegrityError("roll session journal identity is malformed")
    identity = cast(dict[str, Any], journal_identity)
    if type(identity.get("path")) is not str or not _is_sha256(identity.get("sha256")):
        raise RollSessionIntegrityError("roll session journal identity is malformed")
    journal_path = Path(identity["path"])
    if not journal_path.is_absolute():
        raise RollSessionIntegrityError("roll session journal path is not absolute")
    try:
        resolved_journal = journal_path.resolve(strict=True)
    except OSError as error:
        raise RollSessionIntegrityError(
            f"roll session journal is unavailable: {error}"
        ) from error
    if resolved_journal != journal_path:
        raise RollSessionIntegrityError(
            "roll session journal path aliases another path"
        )
    journal, journal_bytes = _load_json_object(journal_path)
    if hashlib.sha256(journal_bytes).hexdigest() != identity["sha256"]:
        raise RollSessionIntegrityError(
            "roll session journal changed since it was saved"
        )
    root = journal_path.parent
    output_value = journal.get("output")
    if type(output_value) is not str:
        raise RollSessionIntegrityError("roll session journal output path is missing")
    output_path = Path(output_value)
    paths = AttemptPaths(
        directory=root,
        output=output_path,
        journal=journal_path,
        plan=root / "replay-first-rgbi4-plan.jsonl",
        manifest=root / "replay-first-rgbi4-manifest.json",
        bootstrap_status=root / "worker-bootstrap.json",
        stdout=root / "stdout.txt",
        stderr=root / "stderr.txt",
    )
    attempt = CaptureAttemptResult(
        outcome=CaptureOutcome.COMPLETE,
        request=CaptureRequest(mode=CaptureMode.PREVIEW),
        paths=paths,
        argv=(),
        returncode=0,
        stdout="",
        stderr="",
        journal=journal,
    )
    material_value = state.get("material")
    try:
        material = ScanMaterial(material_value)
    except (TypeError, ValueError) as error:
        raise RollSessionIntegrityError(
            "roll session material is unsupported"
        ) from error
    selected_value = state.get("selected_slots")
    offsets_value = state.get("boundary_offsets")
    if type(selected_value) is not list or type(offsets_value) is not list:
        raise RollSessionIntegrityError(
            "roll session selections or offsets are malformed"
        )
    expected_frame_count = state.get("expected_frame_count")
    try:
        session = build_roll_preview_session(
            attempt,
            material=material,
            selected_slots=cast(list[int], selected_value),
            expected_frame_count=cast(int | None, expected_frame_count),
        )
    except (TypeError, ValueError) as error:
        raise RollSessionIntegrityError(
            f"roll session state is invalid: {error}"
        ) from error
    if (
        state.get("slot_count") != len(session.slots)
        or state.get("preview_sha256") != session.preview.preview_artifact.sha256
        or state.get("table_sha256") != session.preview.table_artifact.sha256
        or len(offsets_value) != len(session.slots)
    ):
        raise RollSessionIntegrityError(
            "roll session source identities or slot geometry changed"
        )
    for slot_id, offset in enumerate(offsets_value, start=1):
        if type(offset) is not int:
            raise RollSessionIntegrityError(
                "roll session boundary offset is not an integer"
            )
        if offset:
            try:
                session = session.with_boundary_offset(slot_id, offset)
            except (TypeError, ValueError) as error:
                raise RollSessionIntegrityError(
                    f"roll session boundary offset is invalid: {error}"
                ) from error
    return session


__all__ = [
    "ArtifactIdentity",
    "CaptureRecipe",
    "CaptureRoute",
    "RollPreviewSession",
    "RollPreviewSlot",
    "RollSessionError",
    "RollSessionIntegrityError",
    "ValidatedRollPreview",
    "build_roll_preview_session",
    "reload_thumbnail",
    "recipe_for_material",
]
