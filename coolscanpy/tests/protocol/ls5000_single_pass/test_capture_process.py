"""Hardware-free contracts for the process-isolated RGBI4x capture bridge."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import threading
from collections.abc import Callable, Sequence
from dataclasses import FrozenInstanceError, dataclass, field
from functools import lru_cache
from pathlib import Path

import numpy as np
import pytest

from coolscanpy.protocol import ls5000_single_pass as single_pass
from coolscanpy.protocol.ls5000_single_pass import capture_process as capture
from coolscanpy.protocol.ls5000_single_pass.bundle import (
    CAPTURE_BUNDLE_SHA256,
    CAPTURE_WORKER_SHA256,
)
from coolscanpy.protocol.ls5000_single_pass.continuation_plan import (
    CANONICAL_CONTINUATION_PLAN_SHA256,
)
from coolscanpy.protocol.ls5000_single_pass.plan import (
    CANONICAL_FINE_READ_BYTES,
    CANONICAL_FINE_READ_COUNT,
    CANONICAL_PLAN_SHA256,
)


def _argument(argv: Sequence[str], name: str) -> str:
    index = argv.index(name)
    return argv[index + 1]


def _density_calibration_provenance(session_id: str) -> dict[str, object]:
    reads = [
        single_pass.decode_density_calibration_read(
            bytes.fromhex(cdb),
            bytes.fromhex(payload),
        )
        for cdb, payload in zip(
            (
                "28008c00010300000a80",
                "28008c00020300000a80",
                "28008c00030300000a80",
            ),
            (
                "8c20000000040000df1a",
                "8c20000000040000bba4",
                "8c200000000400007fab",
            ),
            strict=True,
        )
    ]
    calibration = single_pass.assemble_density_calibration(
        reads,
        session_id=session_id,
    )
    return {
        "density_calibration_session_id": session_id,
        "nikon_density_calibration": calibration.to_dict(),
    }


@lru_cache(maxsize=1)
def _density_source_fixture() -> bytes:
    samples = np.concatenate(
        (
            np.full(96, 45_000, dtype=np.uint16),
            np.full(96, 40_000, dtype=np.uint16),
            np.full(96, 32_000, dtype=np.uint16),
        )
    ).astype(">u2")
    row = samples.tobytes() + bytes(448)
    return bytes(100 * 1_024) + row + bytes((6_104 - 101) * 1_024)


def _batch_density_frame_provenance(
    job_path: Path,
    *,
    output: Path,
    frame_index: int,
    selected_slot: int,
) -> tuple[dict[str, object], str, str]:
    """Build exact density evidence/ownership for a synthetic batch frame."""

    job = json.loads(job_path.read_text(encoding="utf-8"))
    session_id = job["session_id"]
    selected_slots = tuple(frame["slot"] for frame in job["frames"])
    first_output = job_path.parent / job["frames"][0]["output"]
    calibration = single_pass.DensityCalibration.from_dict(
        _density_calibration_provenance(session_id)["nikon_density_calibration"]
    )
    source = _density_source_fixture()
    evidence = single_pass.build_nikon_density_evidence(
        source,
        calibration=calibration,
        density_f03_exposures_raw_10ns=(70_307, 136_614, 125_470),
        session_id=session_id,
        capture_attempt_id=first_output.parent.name,
        scan_identity=f"{session_id}:density-97dpi:{hashlib.sha256(source).hexdigest()}",
    )
    if frame_index == 1:
        first_output.with_name(f"{first_output.stem}-preview.bin").write_bytes(source)
    reviewed_sha = job["reviewed_roll_fingerprint"]["binding_sha256"]
    table_sha = "e" * 64
    ownership = single_pass.build_nikon_density_frame_ownership(
        evidence,
        reservation_id=session_id,
        batch_session_id=session_id,
        transport_table_sha256=table_sha,
        reviewed_fingerprint_sha256=reviewed_sha,
        fresh_fingerprint_sha256="d" * 64,
        frame_capture_attempt_id=output.parent.name,
        frame_index=frame_index,
        frame_total=len(selected_slots),
        selected_slots=selected_slots,
        selected_slot=selected_slot,
    )
    provenance: dict[str, object] = {
        "nikon_density_frame_ownership": ownership.to_dict(),
    }
    if "expected_usb_bus" in job and "expected_usb_address" in job:
        provenance.update(
            {
                "expected_usb_bus": job["expected_usb_bus"],
                "expected_usb_address": job["expected_usb_address"],
                "actual_usb_bus": job["expected_usb_bus"],
                "actual_usb_address": job["expected_usb_address"],
            }
        )
    if frame_index == 1:
        provenance["nikon_density_evidence"] = evidence.to_dict()
    return provenance, evidence.source_binding.wire_sha256, table_sha


def test_capture_process_replays_37_record_density_geometry(tmp_path: Path) -> None:
    session_id = "reservation-preview-37"
    output = tmp_path / "frame-001" / "capture.bin"
    output.parent.mkdir()
    source = _density_source_fixture()[: 5_668 * 1_024]
    calibration = single_pass.DensityCalibration.from_dict(
        _density_calibration_provenance(session_id)["nikon_density_calibration"]
    )
    evidence = single_pass.build_nikon_density_evidence(
        source,
        calibration=calibration,
        density_f03_exposures_raw_10ns=(70_307, 136_614, 125_470),
        session_id=session_id,
        capture_attempt_id=output.parent.name,
        scan_identity=f"{session_id}:density-97dpi:{hashlib.sha256(source).hexdigest()}",
        source_native_height=232_401,
        source_height=5_668,
    )
    output.with_name(f"{output.stem}-preview.bin").write_bytes(source)

    rebuilt = capture._validated_density_evidence(
        {"nikon_density_evidence": evidence.to_dict()},
        output_path=output,
    )

    assert rebuilt == evidence
    assert rebuilt.source_binding.native_height == 232_401
    assert rebuilt.source_binding.height == 5_668


@pytest.mark.parametrize(
    "mutation",
    [
        "missing-receipt",
        "new-preview",
        "new-transport-table",
        "new-registration",
        "new-reservation",
    ],
)
def test_capture_boundary_invalidates_density_on_any_ownership_change(
    tmp_path: Path,
    mutation: str,
) -> None:
    session_id = "reservation-preview-test"
    job_path = tmp_path / "batch-job.json"
    output = tmp_path / "frame-004" / "capture.bin"
    output.parent.mkdir()
    job = {
        "session_id": session_id,
        "frames": [{"slot": 4, "output": "frame-004/capture.bin"}],
        "reviewed_roll_fingerprint": {"binding_sha256": "2" * 64},
    }
    job_path.write_text(json.dumps(job), encoding="utf-8")
    density, preview_sha, table_sha = _batch_density_frame_provenance(
        job_path,
        output=output,
        frame_index=1,
        selected_slot=4,
    )
    journal: dict[str, object] = {
        **density,
        "batch_session": {
            "frame_index": 1,
            "frame_total": 1,
            "selected_slots": [4],
            "session_id": session_id,
        },
        "live_frame_selection": {
            "frame": 4,
            "preview_sha256": preview_sha,
            "table_sha256": table_sha,
            "roll_identity": {
                "reviewed_fingerprint_sha256": "2" * 64,
                "fresh_fingerprint_sha256": "d" * 64,
            },
        },
        "session_reservation_retained": True,
    }
    if mutation == "missing-receipt":
        journal.pop("nikon_density_frame_ownership")
    elif mutation == "new-preview":
        journal["live_frame_selection"]["preview_sha256"] = "4" * 64
    elif mutation == "new-transport-table":
        journal["live_frame_selection"]["table_sha256"] = "5" * 64
    elif mutation == "new-registration":
        journal["live_frame_selection"]["roll_identity"]["fresh_fingerprint_sha256"] = (
            "6" * 64
        )
    elif mutation == "new-reservation":
        journal["batch_session"]["session_id"] = "another-reservation"

    with pytest.raises(ValueError, match="density|ownership|receipt|batch"):
        capture._validated_density_frame_ownership(
            journal,
            output_path=output,
            expected_session_id=session_id,
            expected_frame_index=1,
            expected_frame_total=1,
            expected_selected_slots=(4,),
            expected_selected_slot=4,
        )


def _tamper_density_calibration_payload(journal: dict[str, object]) -> None:
    calibration = journal["nikon_density_calibration"]
    assert isinstance(calibration, dict)
    payloads = calibration["payload_hex_rgb"]
    assert isinstance(payloads, list)
    payloads[0] = "00" * 10


@dataclass
class FakeRunner:
    worker_sha256: str
    bundle_sha256: str | None = None
    status: str = "complete"
    recovery: str | None = None
    returncode: int = 0
    stdout: str = "worker stdout\n"
    stderr: str = "worker stderr\n"
    mutate_journal: Callable[[dict[str, object]], None] | None = None
    during_run: Callable[[], None] | None = None
    write_journal: bool = True
    calls: list[tuple[tuple[str, ...], Path]] = field(default_factory=list)

    def __call__(
        self, argv: Sequence[str], *, cwd: Path
    ) -> subprocess.CompletedProcess[str]:
        command = tuple(argv)
        self.calls.append((command, cwd))
        if self.during_run is not None:
            self.during_run()

        output = Path(_argument(command, "--output"))
        journal_path = Path(_argument(command, "--journal"))
        selected = int(_argument(command, "--frame")) if "--frame" in command else None
        if "--preview-only" in command:
            mode = "preview-only"
            expected_reads = 0
            expected_bytes = 0
        elif "--meter-only" in command:
            mode = "meter-only"
            expected_reads = capture.METER_READ_COUNT
            expected_bytes = capture.METER_CAPTURE_BYTES
        else:
            mode = "full"
            expected_reads = CANONICAL_FINE_READ_COUNT
            expected_bytes = CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES

        if self.returncode == 0:
            with output.open("xb") as stream:
                stream.truncate(expected_bytes)
        payload: dict[str, object] = {
            "status": self.status,
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "capture_engine_sha256": self.worker_sha256,
            "output": str(output.resolve()),
            "capture_mode": mode,
            "requested_frame": selected,
            "expected_frame_count": None,
            "expected_usb_bus": (
                int(_argument(command, "--expected-usb-bus"))
                if "--expected-usb-bus" in command
                else None
            ),
            "expected_usb_address": (
                int(_argument(command, "--expected-usb-address"))
                if "--expected-usb-address" in command
                else None
            ),
            "actual_usb_bus": (
                int(_argument(command, "--expected-usb-bus"))
                if "--expected-usb-bus" in command
                else None
            ),
            "actual_usb_address": (
                int(_argument(command, "--expected-usb-address"))
                if "--expected-usb-address" in command
                else None
            ),
            "expected_reads": expected_reads,
            "expected_bytes": expected_bytes,
            "requested_boundary_offset_rows": int(
                _argument(command, "--boundary-offset-rows")
            ),
            "completed_reads": expected_reads if self.returncode == 0 else 0,
            "completed_bytes": expected_bytes if self.returncode == 0 else 0,
        }
        if self.bundle_sha256 is not None:
            payload["capture_bundle_sha256"] = self.bundle_sha256
        if self.returncode == 0:
            payload.update(
                disk_bytes=expected_bytes,
                unit_released=True,
                output_sha256="a" * 64,
            )
            payload.update(_density_calibration_provenance("single-reservation-test"))
            if mode != "preview-only":
                payload.update(
                    applied_boundary_offset_rows=payload[
                        "requested_boundary_offset_rows"
                    ],
                    resolved_lookup_row=2400,
                    resolved_native_origin=100_000,
                )
        else:
            payload["recovery_required"] = self.recovery
        if self.mutate_journal is not None:
            self.mutate_journal(payload)
        if self.write_journal:
            journal_path.write_text(json.dumps(payload), encoding="utf-8")
        return subprocess.CompletedProcess(
            command, self.returncode, self.stdout, self.stderr
        )


@dataclass(frozen=True)
class Binding:
    worker: Path
    manifest: Path
    worker_sha256: str


def _batch_session_provenance(
    job_path: Path,
    worker_sha256: str,
) -> dict[str, object]:
    job = json.loads(job_path.read_text(encoding="utf-8"))
    return {
        **_density_calibration_provenance(job["session_id"]),
        "batch_job_sha256": hashlib.sha256(job_path.read_bytes()).hexdigest(),
        "capture_bundle_sha256": CAPTURE_BUNDLE_SHA256,
        "capture_engine_sha256": worker_sha256,
        "expected_usb_bus": job["expected_usb_bus"],
        "expected_usb_address": job["expected_usb_address"],
        "actual_usb_bus": job["expected_usb_bus"],
        "actual_usb_address": job["expected_usb_address"],
        "manual_review_approval_sha256_by_slot": {
            str(frame["slot"]): (
                None
                if frame["manual_review_approval"] is None
                else frame["manual_review_approval"]["binding_sha256"]
            )
            for frame in job["frames"]
        },
        "reviewed_roll_fingerprint_sha256": job["reviewed_roll_fingerprint"][
            "binding_sha256"
        ],
    }


def _reviewed_fingerprint() -> capture.ReviewedRollFingerprint:
    return capture.ReviewedRollFingerprint(
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
        preview_shape=(6_104, 96, 3),
        frame_start_rows=tuple(100 + 143 * index for index in range(40)),
        frame_native_origins=tuple(6_000 + 6_000 * index for index in range(40)),
        frame_visual_hashes=tuple(f"{index:064x}" for index in range(40)),
        frame_visual_log_spans=(2.0,) * 40,
    )


def _manual_approval(
    fingerprint: capture.ReviewedRollFingerprint,
    *,
    slot: int,
    offset: int,
) -> capture.ManualFrameApproval:
    return capture.ManualFrameApproval(
        reviewed_fingerprint_sha256=fingerprint.binding_sha256,
        slot=slot,
        boundary_offset_rows=offset,
        thumbnail_sha256="3" * 64,
        reviewed_lookup_row=2_400,
        reviewed_native_origin=100_000,
        review_reasons=("transport-origin-inferred",),
    )


def _roll_identity_evidence(
    reviewed_fingerprint_sha256: str,
    *,
    slot: int,
) -> dict[str, object]:
    return {
        "reviewed_fingerprint_sha256": reviewed_fingerprint_sha256,
        "fresh_fingerprint_sha256": "d" * 64,
        "comparison": capture.RollFingerprintComparison(
            matches=True,
            reason="matched",
            compared_frames=40,
            preview_height_delta_rows=2,
            visual_median_hamming=6.0,
            visual_p90_hamming=12,
            frame_start_median_delta_rows=2.0,
            frame_start_max_delta_rows=8,
            native_origin_median_delta=14.0,
            native_origin_max_delta=42,
            discriminative_frames=40,
            minimum_discriminative_frames=3,
            minimum_visual_log_span=0.5,
        ).to_payload(),
        "selected_slot_comparison": capture.SelectedRollFingerprintComparison(
            matches=True,
            reason="matched",
            slot=slot,
            visual_hamming=8,
            maximum_visual_hamming=48,
            reviewed_visual_log_span=2.0,
            fresh_visual_log_span=1.9,
            minimum_visual_log_span=0.5,
        ).to_payload(),
    }


def _fingerprint_raster() -> tuple[np.ndarray, tuple[tuple[int, int], ...]]:
    frame_height = 20
    frames = []
    for slot in range(40):
        rng = np.random.default_rng(10_000 + slot)
        coarse = rng.integers(2_000, 50_000, size=(10, 10, 3), dtype=np.uint16)
        frames.append(np.repeat(np.repeat(coarse, 2, axis=0), 2, axis=1))
    rgb = np.concatenate(frames, axis=0).clip(0, 65_535).astype(np.uint16)
    intervals = tuple(
        (slot * frame_height, (slot + 1) * frame_height) for slot in range(40)
    )
    return rgb, intervals


@pytest.fixture
def binding(tmp_path: Path) -> Binding:
    worker = tmp_path / "capture_rgbi4.py"
    worker.write_text("# fake external capture worker\n", encoding="utf-8")
    worker_sha256 = hashlib.sha256(worker.read_bytes()).hexdigest()
    manifest = tmp_path / "replay-first-rgbi4-manifest.json"
    manifest.write_text(
        json.dumps({"plan_sha256": CANONICAL_PLAN_SHA256}), encoding="utf-8"
    )
    return Binding(worker, manifest, worker_sha256)


def _adapter(
    tmp_path: Path, binding: Binding, runner: FakeRunner
) -> capture.CaptureProcessAdapter:
    return capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        python_executable=sys.executable,
        runner=runner,
    )


def test_parent_ack_publish_is_exclusive_without_a_hard_link(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    path = tmp_path / "parent-ack.json"
    payload = b'{"action":"stop"}\n'

    def forbid_hard_link(*_args, **_kwargs):
        raise AssertionError("parent ACK publication must not call os.link")

    monkeypatch.setattr("os.link", forbid_hard_link)
    capture._publish_exclusive(path, payload)

    assert path.read_bytes() == payload
    with pytest.raises(FileExistsError):
        capture._publish_exclusive(path, payload)


def test_batch_request_is_one_immutable_ordered_full_capture_unit() -> None:
    fingerprint = _reviewed_fingerprint()
    approval = _manual_approval(fingerprint, slot=17, offset=-12)
    request = capture.CaptureBatchRequest(
        frames=(
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=17,
                boundary_offset_rows=-12,
                manual_review_approval=approval,
            ),
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=19,
                boundary_offset_rows=8,
            ),
        ),
        reviewed_fingerprint=fingerprint,
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    assert request.selected_slots == (17, 19)
    assert request.reviewed_fingerprint is fingerprint
    assert request.frames[0].manual_review_approval is approval
    assert request.expected_usb_bus == 1
    assert request.expected_usb_address == 2
    with pytest.raises(FrozenInstanceError):
        setattr(request, "frames", ())


def test_roll_fingerprint_accepts_harmless_reread_noise_but_rejects_reordered_film() -> (
    None
):
    rgb, intervals = _fingerprint_raster()
    origins = tuple(6_000 + 6_000 * index for index in range(40))
    reviewed = capture.build_reviewed_roll_fingerprint(
        rgb,
        frame_intervals=intervals,
        frame_native_origins=origins,
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )
    rng = np.random.default_rng(17)
    reread = np.clip(
        rgb.astype(np.float64) * 1.08 + rng.normal(0.0, 12.0, rgb.shape),
        0,
        65_535,
    ).astype(np.uint16)
    reread = np.concatenate(
        (reread, np.repeat(reread[-1:, :, :], 8, axis=0)),
        axis=0,
    )
    fresh = capture.build_reviewed_roll_fingerprint(
        reread,
        frame_intervals=intervals,
        frame_native_origins=tuple(
            value + (-28 if index % 2 else 28) for index, value in enumerate(origins)
        ),
        source_preview_sha256="4" * 64,
        source_table_sha256="5" * 64,
    )

    accepted = capture.compare_reviewed_roll_fingerprints(reviewed, fresh)

    assert accepted.matches is True
    assert accepted.visual_median_hamming <= 24
    assert accepted.visual_p90_hamming <= 48

    frame_height = intervals[0][1] - intervals[0][0]
    reordered = np.concatenate(
        [rgb[start:end] for start, end in reversed(intervals)],
        axis=0,
    )
    changed = capture.build_reviewed_roll_fingerprint(
        reordered,
        frame_intervals=tuple(
            (slot * frame_height, (slot + 1) * frame_height) for slot in range(40)
        ),
        frame_native_origins=origins,
        source_preview_sha256="6" * 64,
        source_table_sha256="7" * 64,
    )

    refused = capture.compare_reviewed_roll_fingerprints(reviewed, changed)

    assert refused.matches is False
    assert refused.reason == "visual-content-mismatch"


def test_selected_slot_fingerprint_refuses_one_changed_outlier() -> None:
    rgb, intervals = _fingerprint_raster()
    origins = tuple(6_000 + 6_000 * index for index in range(40))
    reviewed = capture.build_reviewed_roll_fingerprint(
        rgb,
        frame_intervals=intervals,
        frame_native_origins=origins,
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )
    changed_rgb = rgb.copy()
    start, end = intervals[16]
    rng = np.random.default_rng(91_017)
    changed_rgb[start:end] = rng.integers(
        1,
        65_535,
        size=changed_rgb[start:end].shape,
        dtype=np.uint16,
    )
    fresh = capture.build_reviewed_roll_fingerprint(
        changed_rgb,
        frame_intervals=intervals,
        frame_native_origins=origins,
        source_preview_sha256="3" * 64,
        source_table_sha256="4" * 64,
    )

    # The roll-level aggregate is deliberately tolerant of a small number of
    # damaged/blank candidates, but a selected frame must prove its own image.
    assert capture.compare_reviewed_roll_fingerprints(reviewed, fresh).matches
    selected = capture.compare_selected_roll_fingerprint(
        reviewed,
        fresh,
        slot=17,
    )

    assert selected.matches is False
    assert selected.reason == "selected-visual-content-mismatch"
    assert selected.visual_hamming > selected.maximum_visual_hamming
    assert selected.to_payload()["slot"] == 17


def test_roll_fingerprint_refuses_flat_non_discriminative_signatures() -> None:
    intervals = tuple((slot * 20, (slot + 1) * 20) for slot in range(40))
    origins = tuple(6_000 + 6_000 * index for index in range(40))
    reviewed = capture.build_reviewed_roll_fingerprint(
        np.full((800, 20, 3), 1_000, dtype=np.uint16),
        frame_intervals=intervals,
        frame_native_origins=origins,
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )
    fresh = capture.build_reviewed_roll_fingerprint(
        np.full((800, 20, 3), 50_000, dtype=np.uint16),
        frame_intervals=intervals,
        frame_native_origins=origins,
        source_preview_sha256="3" * 64,
        source_table_sha256="4" * 64,
    )

    comparison = capture.compare_reviewed_roll_fingerprints(reviewed, fresh)

    assert comparison.matches is False
    assert comparison.reason == "visual-signature-indeterminate"
    assert comparison.discriminative_frames == 0
    assert comparison.minimum_discriminative_frames == 3


def test_roll_fingerprint_ignores_blank_tail_slots_in_visual_aggregate() -> None:
    starts = tuple(100 + 143 * index for index in range(40))
    origins = tuple(6_000 + 6_000 * index for index in range(40))
    informative_hashes = tuple(f"{index + 1:064x}" for index in range(24))
    reviewed = capture.ReviewedRollFingerprint(
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
        preview_shape=(6_104, 96, 3),
        frame_start_rows=starts,
        frame_native_origins=origins,
        frame_visual_hashes=informative_hashes + ("0" * 64,) * 16,
        frame_visual_log_spans=(2.0,) * 24 + (0.0,) * 16,
    )
    fresh = capture.ReviewedRollFingerprint(
        source_preview_sha256="3" * 64,
        source_table_sha256="4" * 64,
        preview_shape=(6_104, 96, 3),
        frame_start_rows=starts,
        frame_native_origins=origins,
        frame_visual_hashes=informative_hashes + ("f" * 64,) * 16,
        frame_visual_log_spans=(2.0,) * 24 + (0.0,) * 16,
    )

    comparison = capture.compare_reviewed_roll_fingerprints(reviewed, fresh)

    assert comparison.matches is True
    assert comparison.reason == "matched"
    assert comparison.discriminative_frames == 24
    assert comparison.visual_median_hamming == 0.0
    assert comparison.visual_p90_hamming == 0


def test_roll_fingerprint_thresholds_retain_archived_same_roll_margin() -> None:
    fixture = json.loads(
        (
            Path(__file__).parent
            / "fixtures"
            / "ls5000-roll-fingerprint-calibration.json"
        ).read_text(encoding="utf-8")
    )
    thresholds = fixture["thresholds"]
    assert thresholds == {
        "frame_start_max_delta_rows": capture.MAX_FRAME_START_DELTA_ROWS,
        "frame_start_median_delta_rows": capture.MAX_FRAME_START_MEDIAN_DELTA_ROWS,
        "native_origin_max_delta": capture.MAX_NATIVE_ORIGIN_DELTA,
        "native_origin_median_delta": capture.MAX_NATIVE_ORIGIN_MEDIAN_DELTA,
        "preview_height_delta_rows": capture.MAX_PREVIEW_HEIGHT_DELTA_ROWS,
        "selected_visual_hamming": capture.MAX_SELECTED_VISUAL_HAMMING,
        "visual_log_span_min": capture.MIN_VISUAL_LOG_SPAN,
        "minimum_discriminative_frames": capture.MIN_DISCRIMINATIVE_FRAME_COUNT,
        "visual_median_hamming": capture.MAX_VISUAL_MEDIAN_HAMMING,
        "visual_p90_hamming": capture.MAX_VISUAL_P90_HAMMING,
    }
    same_roll = fixture["same_roll_rereads"]
    assert max(item["visual_p90_hamming"] for item in same_roll) <= 16
    assert max(item["frame_start_max_delta_rows"] for item in same_roll) <= 12
    assert max(item["native_origin_max_delta"] for item in same_roll) <= 56
    guard = fixture["discriminative_guard"]
    assert guard["same_roll_selected_visual_hamming_max"] <= 32
    assert (
        guard["same_roll_selected_visual_hamming_max"]
        < thresholds["selected_visual_hamming"]
    )
    assert (
        guard["same_roll_visual_log_span_min"] > 3 * thresholds["visual_log_span_min"]
    )
    different = fixture["different_roll"]
    assert (
        different["common_slot_visual_hamming_median"]
        > thresholds["visual_median_hamming"]
    )
    assert (
        different["frame_start_delta_median_rows"]
        > thresholds["frame_start_median_delta_rows"]
    )
    assert (
        different["native_origin_delta_median"]
        > thresholds["native_origin_median_delta"]
    )


def test_batch_session_foundation_is_exported_from_scanner_package() -> None:
    assert single_pass.CaptureBatchRequest is capture.CaptureBatchRequest
    assert single_pass.PreparedCaptureBatch is capture.PreparedCaptureBatch


def test_prepare_batch_frames_every_selected_slot_as_one_future_child_session(
    tmp_path: Path,
    binding: Binding,
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)
    fingerprint = _reviewed_fingerprint()
    approval = _manual_approval(fingerprint, slot=17, offset=-12)
    request = capture.CaptureBatchRequest(
        frames=(
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=17,
                boundary_offset_rows=-12,
                manual_review_approval=approval,
            ),
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=19,
                boundary_offset_rows=8,
            ),
        ),
        reviewed_fingerprint=fingerprint,
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    prepared = adapter.prepare_batch_session(request)
    job = json.loads(prepared.paths.job.read_text(encoding="utf-8"))

    assert runner.calls == []
    assert prepared.request is request
    assert _argument(prepared.argv, "--batch-job") == str(prepared.paths.job)
    assert _argument(prepared.argv, "--plan") == str(prepared.paths.first_plan)
    assert _argument(prepared.argv, "--continuation-plan") == str(
        prepared.paths.continuation_plan
    )
    assert _argument(prepared.argv, "--session-journal") == str(
        prepared.paths.session_journal
    )
    assert _argument(prepared.argv, "--expected-batch-job-sha256") == (
        prepared.job_sha256
    )
    assert "--frame" not in prepared.argv
    assert job["session_id"] == prepared.session_id
    assert job == {
        "apply_all_boundary_offsets_before_first_frame": True,
        "capture_plan_sha256": CANONICAL_PLAN_SHA256,
        "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
        "expected_usb_address": 2,
        "expected_usb_bus": 1,
        "frames": [
            {
                "ack": "frame-017/parent-ack.json",
                "boundary_offset_rows": -12,
                "journal": "frame-017/journal.json",
                "manual_review_approval": approval.to_payload(),
                "output": "frame-017/capture.bin",
                "slot": 17,
            },
            {
                "ack": "frame-019/parent-ack.json",
                "boundary_offset_rows": 8,
                "journal": "frame-019/journal.json",
                "manual_review_approval": None,
                "output": "frame-019/capture.bin",
                "slot": 19,
            },
        ],
        "parent_ack_required_after_every_frame": True,
        "release_once_after_last_frame": True,
        "reviewed_roll_fingerprint": fingerprint.to_payload(),
        "schema_version": 3,
        "session_id": prepared.session_id,
        "session_contract": "one-process-one-reservation",
    }
    assert hashlib.sha256(prepared.paths.first_plan.read_bytes()).hexdigest() == (
        CANONICAL_PLAN_SHA256
    )
    assert (
        hashlib.sha256(prepared.paths.continuation_plan.read_bytes()).hexdigest()
        == CANONICAL_CONTINUATION_PLAN_SHA256
    )
    assert hashlib.sha256(prepared.paths.job.read_bytes()).hexdigest() == (
        prepared.job_sha256
    )


@pytest.mark.parametrize(
    "field",
    [
        "batch_job_sha256",
        "capture_engine_sha256",
        "capture_bundle_sha256",
        "density_calibration_session_id",
        "expected_usb_bus",
        "actual_usb_address",
        "actual_usb_topology",
    ],
)
def test_batch_session_receipt_rejects_tampered_process_identity(
    tmp_path: Path,
    binding: Binding,
    field: str,
) -> None:
    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    prepared = adapter.prepare_batch_session(request)
    receipt: dict[str, object] = {
        **_batch_session_provenance(
            prepared.paths.job,
            binding.worker_sha256,
        ),
        "completed_slots": [],
        "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
        "plan_sha256": CANONICAL_PLAN_SHA256,
        "recovery_required": "none",
        "reservation_acquired": True,
        "selected_slots": [17],
        "session_id": prepared.session_id,
        "status": "stopped",
        "unit_release_attempts": 1,
        "unit_released": True,
    }
    expected_error = field
    if field == "actual_usb_topology":
        receipt["actual_usb_bus"] = None
        receipt["actual_usb_address"] = None
        expected_error = "reserved batch session"
    else:
        receipt[field] = "f" * 64
    prepared.paths.session_journal.write_text(
        json.dumps(receipt),
        encoding="utf-8",
    )

    with pytest.raises(capture.CaptureProcessError, match=expected_error):
        adapter._load_and_validate_batch_session_journal(
            prepared,
            returncode=0,
            handled=(),
            stopped=True,
        )


def test_failed_batch_receipt_rejects_unobserved_completed_frames(
    tmp_path: Path,
    binding: Binding,
) -> None:
    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    request = capture.CaptureBatchRequest(
        (
            capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),
            capture.CaptureRequest(capture.CaptureMode.FULL, 19, 0),
        ),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    prepared = adapter.prepare_batch_session(request)
    receipt: dict[str, object] = {
        **_batch_session_provenance(
            prepared.paths.job,
            binding.worker_sha256,
        ),
        "completed_slots": [17, 19],
        "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
        "plan_sha256": CANONICAL_PLAN_SHA256,
        "recovery_required": "none",
        "reservation_acquired": True,
        "selected_slots": [17, 19],
        "session_id": prepared.session_id,
        "status": "failed",
        "unit_release_attempts": 1,
        "unit_released": True,
    }
    prepared.paths.session_journal.write_text(
        json.dumps(receipt),
        encoding="utf-8",
    )

    with pytest.raises(
        capture.CaptureProcessError,
        match="does not match the observed frame prefix",
    ):
        adapter._load_and_validate_batch_session_journal(
            prepared,
            returncode=1,
            handled=(),
            stopped=False,
        )


def test_stop_winning_the_launch_gate_prevents_batch_process_creation(
    tmp_path: Path,
    binding: Binding,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    stdout_opened = threading.Event()
    spawn_calls: list[tuple[str, ...]] = []
    original_open = Path.open

    def observe_open(path: Path, *args: object, **kwargs: object):
        if path.name == "stdout.txt" and args and args[0] == "xb":
            stdout_opened.set()
        return original_open(path, *args, **kwargs)

    def forbidden_spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> capture.RunningBatchProcess:
        del cwd, stdout, stderr
        spawn_calls.append(tuple(argv))
        raise AssertionError("a stop that wins the launch gate must prevent Popen")

    monkeypatch.setattr(Path, "open", observe_open)
    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        batch_spawner=forbidden_spawn,
        batch_poll_seconds=0,
    )
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    errors: list[BaseException] = []

    def run() -> None:
        try:
            adapter.run_batch_session(
                request,
                frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE,
            )
        except BaseException as error:
            errors.append(error)

    adapter._stop_gate.acquire()
    thread = threading.Thread(target=run)
    try:
        thread.start()
        assert stdout_opened.wait(timeout=5)
        # This is the state request_stop() publishes while owning _stop_gate.
        adapter._stop_requested.set()
    finally:
        adapter._stop_gate.release()
    thread.join(timeout=5)

    assert not thread.is_alive()
    assert spawn_calls == []
    assert len(errors) == 1
    assert isinstance(errors[0], capture.CaptureStopped)


def test_batch_parent_finalizes_each_frame_before_acknowledging_the_next(
    tmp_path: Path,
    binding: Binding,
) -> None:
    events: list[str] = []

    class FakeBatchProcess:
        def __init__(self, argv: Sequence[str]) -> None:
            self.job_path = Path(_argument(argv, "--batch-job"))
            self.session_journal = Path(_argument(argv, "--session-journal"))
            self.job = json.loads(self.job_path.read_text(encoding="utf-8"))
            self.index = 0
            self.returncode: int | None = None
            self._emit_frame()

        def _emit_frame(self) -> None:
            frame = self.job["frames"][self.index]
            directory = self.job_path.parent
            output = directory / frame["output"]
            journal = directory / frame["journal"]
            output.parent.mkdir(parents=True)
            with output.open("xb") as stream:
                stream.truncate(CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES)
            density, preview_sha, table_sha = _batch_density_frame_provenance(
                self.job_path,
                output=output,
                frame_index=self.index + 1,
                selected_slot=frame["slot"],
            )
            journal.write_text(
                json.dumps(
                    {
                        **_density_calibration_provenance(self.job["session_id"]),
                        **density,
                        "ack_nonce": f"nonce-{frame['slot']}",
                        "batch_session": {
                            "frame_index": self.index + 1,
                            "frame_total": len(self.job["frames"]),
                            "selected_slots": [
                                item["slot"] for item in self.job["frames"]
                            ],
                            "session_id": self.job["session_id"],
                        },
                        "capture_engine_sha256": binding.worker_sha256,
                        "capture_mode": "full",
                        "completed_bytes": (
                            CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
                        ),
                        "completed_reads": CANONICAL_FINE_READ_COUNT,
                        "continuation_plan_sha256": (
                            CANONICAL_CONTINUATION_PLAN_SHA256
                        ),
                        "disk_bytes": (
                            CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
                        ),
                        "expected_bytes": (
                            CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
                        ),
                        "expected_reads": CANONICAL_FINE_READ_COUNT,
                        "frame_complete": True,
                        "live_frame_selection": {
                            "frame": frame["slot"],
                            "preview_sha256": preview_sha,
                            "table_sha256": table_sha,
                            "roll_identity": _roll_identity_evidence(
                                self.job["reviewed_roll_fingerprint"]["binding_sha256"],
                                slot=frame["slot"],
                            ),
                        },
                        "manual_review_approval": frame["manual_review_approval"],
                        "output": str(output.resolve()),
                        "output_sha256": "a" * 64,
                        "plan_sha256": CANONICAL_PLAN_SHA256,
                        "recovery_required": None,
                        "requested_boundary_offset_rows": frame["boundary_offset_rows"],
                        "requested_frame": frame["slot"],
                        "reviewed_roll_fingerprint_sha256": self.job[
                            "reviewed_roll_fingerprint"
                        ]["binding_sha256"],
                        "session_reservation_retained": True,
                        "status": "frame-complete",
                        "unit_released": False,
                    }
                ),
                encoding="utf-8",
            )
            events.append(f"ready-{frame['slot']}")

        def poll(self) -> int | None:
            if self.returncode is not None:
                return self.returncode
            frame = self.job["frames"][self.index]
            ack_path = self.job_path.parent / frame["ack"]
            if not ack_path.exists():
                return None
            ack = json.loads(ack_path.read_text(encoding="utf-8"))
            events.append(f"ack-{frame['slot']}-{ack['action']}")
            if ack["action"] == "continue" and self.index + 1 < len(self.job["frames"]):
                self.index += 1
                self._emit_frame()
                return None
            completed = [item["slot"] for item in self.job["frames"][: self.index + 1]]
            self.session_journal.write_text(
                json.dumps(
                    {
                        **_batch_session_provenance(
                            self.job_path,
                            binding.worker_sha256,
                        ),
                        "completed_slots": completed,
                        "continuation_plan_sha256": (
                            CANONICAL_CONTINUATION_PLAN_SHA256
                        ),
                        "plan_sha256": CANONICAL_PLAN_SHA256,
                        "recovery_required": "none",
                        "reservation_acquired": True,
                        "selected_slots": [item["slot"] for item in self.job["frames"]],
                        "session_id": self.job["session_id"],
                        "status": (
                            "stopped" if ack["action"] == "stop" else "complete"
                        ),
                        "unit_release_attempts": 1,
                        "unit_released": True,
                    }
                ),
                encoding="utf-8",
            )
            self.returncode = 0
            return 0

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            while self.poll() is None:
                pass
            return int(self.returncode)

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> FakeBatchProcess:
        del cwd, stdout, stderr
        return FakeBatchProcess(argv)

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        batch_spawner=spawn,
        batch_poll_seconds=0,
    )
    request = capture.CaptureBatchRequest(
        frames=(
            capture.CaptureRequest(capture.CaptureMode.FULL, 17, -12),
            capture.CaptureRequest(capture.CaptureMode.FULL, 19, 8),
        ),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    def finalize(result: capture.CaptureAttemptResult) -> capture.BatchAckAction:
        events.append(f"finalized-{result.request.selected_slot}")
        assert result.density_calibration is not None
        assert result.density_calibration.session_id == result.batch_session_id
        assert result.density_calibration.numerators == (57_114, 48_036, 32_683)
        # This is the scratch-deletion point.  The child must not need the raw
        # stream again after the parent acknowledges it.
        result.paths.output.unlink()
        return capture.BatchAckAction.CONTINUE

    result = adapter.run_batch_session(request, frame_handler=finalize)

    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert result.stopped is False
    assert [frame.request.selected_slot for frame in result.frames] == [17, 19]
    assert events == [
        "ready-17",
        "finalized-17",
        "ack-17-continue",
        "ready-19",
        "finalized-19",
        "ack-19-continue",
    ]
    assert result.session_journal["unit_release_attempts"] == 1
    assert (
        result.session_journal["density_calibration_session_id"]
        == (result.session_journal["session_id"])
    )


def test_batch_adapter_refuses_false_roll_comparison_before_parent_handler(
    tmp_path: Path,
    binding: Binding,
) -> None:
    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    fingerprint = _reviewed_fingerprint()
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=fingerprint,
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    prepared = adapter.prepare_batch_session(request)
    frame_request = request.frames[0]
    paths = adapter._batch_frame_paths(prepared, frame_request)
    paths.output.parent.mkdir(parents=True)
    with paths.output.open("xb") as stream:
        stream.truncate(CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES)
    roll_identity = _roll_identity_evidence(
        fingerprint.binding_sha256,
        slot=17,
    )
    roll_identity["comparison"]["matches"] = False
    roll_identity["comparison"]["reason"] = "visual-content-mismatch"
    payload = {
        **_density_calibration_provenance(prepared.session_id),
        "ack_nonce": "nonce-17",
        "batch_session": {
            "frame_index": 1,
            "frame_total": 1,
            "selected_slots": [17],
            "session_id": prepared.session_id,
        },
        "capture_engine_sha256": binding.worker_sha256,
        "capture_mode": "full",
        "expected_usb_bus": 1,
        "expected_usb_address": 2,
        "actual_usb_bus": 1,
        "actual_usb_address": 2,
        "completed_bytes": CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
        "completed_reads": CANONICAL_FINE_READ_COUNT,
        "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
        "disk_bytes": CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
        "expected_bytes": CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
        "expected_reads": CANONICAL_FINE_READ_COUNT,
        "frame_complete": True,
        "live_frame_selection": {"frame": 17, "roll_identity": roll_identity},
        "manual_review_approval": None,
        "output": str(paths.output.resolve()),
        "output_sha256": "a" * 64,
        "plan_sha256": CANONICAL_PLAN_SHA256,
        "recovery_required": None,
        "requested_boundary_offset_rows": 0,
        "requested_frame": 17,
        "reviewed_roll_fingerprint_sha256": fingerprint.binding_sha256,
        "session_reservation_retained": True,
        "status": "frame-complete",
        "unit_released": False,
    }

    with pytest.raises(
        capture.CaptureProcessError, match="roll fingerprint comparison"
    ):
        adapter._validate_batch_frame_result(
            prepared,
            frame_request,
            paths,
            payload,
            frame_index=1,
        )


@pytest.mark.parametrize(
    "failure_mode",
    [
        "handler",
        "handler-cleanup-before-release",
        "handler-release-failed",
        "journal",
        "ack-write",
        "stdout-read",
    ],
)
def test_batch_parent_always_waits_for_child_release_after_post_spawn_failure(
    tmp_path: Path,
    binding: Binding,
    monkeypatch: pytest.MonkeyPatch,
    failure_mode: str,
) -> None:
    events: list[str] = []

    class SelfCleaningBatchProcess:
        def __init__(self, argv: Sequence[str]) -> None:
            self.job_path = Path(_argument(argv, "--batch-job"))
            self.session_journal = Path(_argument(argv, "--session-journal"))
            self.job = json.loads(self.job_path.read_text(encoding="utf-8"))
            self.returncode: int | None = None
            frame = self.job["frames"][0]
            output = self.job_path.parent / frame["output"]
            journal = self.job_path.parent / frame["journal"]
            output.parent.mkdir(parents=True)
            with output.open("xb") as stream:
                stream.truncate(CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES)
            density, preview_sha, table_sha = _batch_density_frame_provenance(
                self.job_path,
                output=output,
                frame_index=1,
                selected_slot=17,
            )
            journal.write_text(
                json.dumps(
                    {
                        **_density_calibration_provenance(self.job["session_id"]),
                        **density,
                        "ack_nonce": "nonce-17",
                        "batch_session": {
                            "frame_index": 1,
                            "frame_total": 1,
                            "selected_slots": [17],
                            "session_id": self.job["session_id"],
                        },
                        "capture_engine_sha256": (
                            "f" * 64
                            if failure_mode == "journal"
                            else binding.worker_sha256
                        ),
                        "capture_mode": "full",
                        "completed_bytes": (
                            CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
                        ),
                        "completed_reads": CANONICAL_FINE_READ_COUNT,
                        "continuation_plan_sha256": (
                            CANONICAL_CONTINUATION_PLAN_SHA256
                        ),
                        "disk_bytes": (
                            CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
                        ),
                        "expected_bytes": (
                            CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES
                        ),
                        "expected_reads": CANONICAL_FINE_READ_COUNT,
                        "frame_complete": True,
                        "live_frame_selection": {
                            "frame": 17,
                            "preview_sha256": preview_sha,
                            "table_sha256": table_sha,
                            "roll_identity": _roll_identity_evidence(
                                self.job["reviewed_roll_fingerprint"]["binding_sha256"],
                                slot=17,
                            ),
                        },
                        "manual_review_approval": frame["manual_review_approval"],
                        "output": str(output.resolve()),
                        "output_sha256": "a" * 64,
                        "plan_sha256": CANONICAL_PLAN_SHA256,
                        "recovery_required": None,
                        "requested_boundary_offset_rows": 0,
                        "requested_frame": 17,
                        "reviewed_roll_fingerprint_sha256": self.job[
                            "reviewed_roll_fingerprint"
                        ]["binding_sha256"],
                        "session_reservation_retained": True,
                        "status": "frame-complete",
                        "unit_released": False,
                    }
                ),
                encoding="utf-8",
            )

        def poll(self) -> int | None:
            return self.returncode

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            events.append("waited-for-child")
            ack = self.job_path.parent / self.job["frames"][0]["ack"]
            stopped = bool(
                ack.exists()
                and json.loads(ack.read_text(encoding="utf-8"))["action"] == "stop"
            )
            acknowledged = ack.exists()
            cleanup_before_release = failure_mode == "handler-cleanup-before-release"
            release_failed = failure_mode in (
                "handler-cleanup-before-release",
                "handler-release-failed",
            )
            self.session_journal.write_text(
                json.dumps(
                    {
                        **_batch_session_provenance(
                            self.job_path,
                            binding.worker_sha256,
                        ),
                        "completed_slots": [17],
                        "continuation_plan_sha256": (
                            CANONICAL_CONTINUATION_PLAN_SHA256
                        ),
                        "plan_sha256": CANONICAL_PLAN_SHA256,
                        "recovery_required": (
                            capture.POWER_CYCLE_RECOVERY if release_failed else "none"
                        ),
                        "reservation_acquired": True,
                        "selected_slots": [17],
                        "session_id": self.job["session_id"],
                        "status": (
                            "failed"
                            if release_failed or not acknowledged
                            else ("stopped" if stopped else "complete")
                        ),
                        "unit_release_attempts": (0 if cleanup_before_release else 1),
                        "unit_released": not release_failed,
                    }
                ),
                encoding="utf-8",
            )
            self.returncode = 0 if acknowledged and not release_failed else 1
            return self.returncode

    process: SelfCleaningBatchProcess | None = None

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> SelfCleaningBatchProcess:
        nonlocal process
        del cwd, stdout, stderr
        process = SelfCleaningBatchProcess(argv)
        return process

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        batch_spawner=spawn,
        batch_poll_seconds=0,
    )
    if failure_mode == "ack-write":
        monkeypatch.setattr(
            adapter,
            "_write_batch_ack",
            lambda *args, **kwargs: (_ for _ in ()).throw(OSError("disk full")),
        )
    if failure_mode == "stdout-read":
        original_read_text = Path.read_text

        def fail_stdout_read(
            path: Path,
            *args: object,
            **kwargs: object,
        ) -> str:
            if path.name == "stdout.txt":
                raise OSError("diagnostic volume unavailable")
            return original_read_text(path, *args, **kwargs)

        monkeypatch.setattr(Path, "read_text", fail_stdout_read)

    def handler(
        result: capture.CaptureAttemptResult,
    ) -> capture.BatchAckAction:
        if failure_mode in (
            "handler",
            "handler-cleanup-before-release",
            "handler-release-failed",
        ):
            raise RuntimeError("finalizer failed")
        return capture.BatchAckAction.CONTINUE

    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    with pytest.raises(capture.CaptureBatchProcessError) as raised:
        adapter.run_batch_session(request, frame_handler=handler)

    assert process is not None
    assert events == ["waited-for-child"]
    receipt = json.loads(process.session_journal.read_text(encoding="utf-8"))
    assert receipt["unit_release_attempts"] == (
        0 if failure_mode == "handler-cleanup-before-release" else 1
    )
    assert receipt["unit_released"] is (
        failure_mode not in ("handler-cleanup-before-release", "handler-release-failed")
    )
    assert raised.value.recovery_required is (
        failure_mode in ("handler-cleanup-before-release", "handler-release-failed")
    )
    if failure_mode == "journal":
        assert raised.value.frames == ()
        assert raised.value.session_journal == receipt
        ack = process.job_path.parent / process.job["frames"][0]["ack"]
        assert json.loads(ack.read_text(encoding="utf-8"))["action"] == "stop"
    else:
        assert [frame.request.selected_slot for frame in raised.value.frames] == [17]
        assert raised.value.session_journal == receipt


@pytest.mark.parametrize(
    ("recovery", "expected_outcome"),
    [
        ("none", capture.CaptureOutcome.SYNCHRONIZED_REFUSAL),
        (capture.POWER_CYCLE_RECOVERY, capture.CaptureOutcome.RECOVERY_REQUIRED),
    ],
)
def test_failed_batch_before_reserve_preserves_recovery_without_release(
    tmp_path: Path,
    binding: Binding,
    recovery: str,
    expected_outcome: capture.CaptureOutcome,
) -> None:
    class ConnectFailureProcess:
        def __init__(self, argv: Sequence[str]) -> None:
            self.session_journal = Path(_argument(argv, "--session-journal"))
            self.job_path = Path(_argument(argv, "--batch-job"))
            self.job = json.loads(self.job_path.read_text(encoding="utf-8"))

        def poll(self) -> int | None:
            return 1

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            self.session_journal.write_text(
                json.dumps(
                    {
                        **_batch_session_provenance(
                            self.job_path,
                            binding.worker_sha256,
                        ),
                        # A connect failure can happen before the worker has
                        # observed any actual USB topology. This is the exact
                        # fail-closed pre-reservation receipt emitted by the
                        # worker, not an inferred copy of the expected device.
                        "actual_usb_bus": None,
                        "actual_usb_address": None,
                        "completed_slots": [],
                        "continuation_plan_sha256": (
                            CANONICAL_CONTINUATION_PLAN_SHA256
                        ),
                        "plan_sha256": CANONICAL_PLAN_SHA256,
                        "recovery_required": recovery,
                        "reservation_acquired": False,
                        "selected_slots": [17],
                        "session_id": self.job["session_id"],
                        "status": "failed",
                        "unit_release_attempts": 0,
                        "unit_released": False,
                    }
                ),
                encoding="utf-8",
            )
            return 1

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> ConnectFailureProcess:
        del cwd, stdout, stderr
        return ConnectFailureProcess(argv)

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        batch_spawner=spawn,
        batch_poll_seconds=0,
    )
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    with pytest.raises(capture.CaptureBatchProcessError) as raised:
        adapter.run_batch_session(
            request,
            frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE,
        )

    assert raised.value.outcome is expected_outcome
    assert raised.value.recovery_required is (
        expected_outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    )
    assert raised.value.session_journal is not None
    assert raised.value.session_journal["reservation_acquired"] is False
    assert raised.value.session_journal["actual_usb_bus"] is None
    assert raised.value.session_journal["actual_usb_address"] is None


def test_terminal_batch_receipt_wakes_parent_before_repeated_process_polling(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """A released failure receipt is a durable wake-up, not just post-exit data."""

    class TerminalFailureProcess:
        def __init__(self, argv: Sequence[str]) -> None:
            self.session_journal = Path(_argument(argv, "--session-journal"))
            self.job_path = Path(_argument(argv, "--batch-job"))
            self.job = json.loads(self.job_path.read_text(encoding="utf-8"))
            self.poll_calls = 0
            self.wait_calls = 0
            self.session_journal.write_text(
                json.dumps(
                    {
                        **_batch_session_provenance(
                            self.job_path,
                            binding.worker_sha256,
                        ),
                        "completed_slots": [],
                        "continuation_plan_sha256": (
                            CANONICAL_CONTINUATION_PLAN_SHA256
                        ),
                        "error": "SynchronizedProtocolError: metering refused",
                        "finished_unix": 123.0,
                        "plan_sha256": CANONICAL_PLAN_SHA256,
                        "recovery_required": "none",
                        "reservation_acquired": True,
                        "selected_slots": [17],
                        "session_id": self.job["session_id"],
                        "status": "failed",
                        "unit_release_attempts": 1,
                        "unit_released": True,
                    }
                ),
                encoding="utf-8",
            )

        def poll(self) -> int | None:
            self.poll_calls += 1
            raise AssertionError(
                "the terminal release receipt should wake the parent before poll"
            )

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            self.wait_calls += 1
            return 1

    process: TerminalFailureProcess | None = None

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> TerminalFailureProcess:
        nonlocal process
        del cwd, stdout, stderr
        process = TerminalFailureProcess(argv)
        return process

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        batch_spawner=spawn,
        batch_poll_seconds=0,
    )
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    result = adapter.run_batch_session(
        request,
        frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE,
    )

    assert process is not None
    assert process.poll_calls == 0
    assert process.wait_calls == 1
    assert result.outcome is capture.CaptureOutcome.SYNCHRONIZED_REFUSAL
    assert result.returncode == 1
    assert result.frames == ()
    assert result.session_journal["error"].endswith("metering refused")


def test_batch_wait_defers_interrupt_until_child_cleanup_finishes(
    tmp_path: Path,
    binding: Binding,
) -> None:
    class InterruptedWait:
        calls = 0

        def poll(self) -> int | None:
            return None

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            self.calls += 1
            if self.calls == 1:
                raise KeyboardInterrupt
            return 0

    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    process = InterruptedWait()

    returncode, deferred = adapter._wait_for_batch_exit(process)

    assert returncode == 0
    assert isinstance(deferred, KeyboardInterrupt)
    assert process.calls == 2


def test_preview_uses_preview_only_without_slot_or_exposure_count(
    tmp_path: Path, binding: Binding
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )

    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert "--preview-only" in result.argv
    assert "--frame" not in result.argv
    assert "--meter-only" not in result.argv
    assert "--confirm-full-capture" not in result.argv
    assert "--expected-frame-count" not in result.argv
    assert result.paths.output.stat().st_size == 0


def test_preview_binds_fresh_usb_fingerprint_to_exact_sane_topology(
    tmp_path: Path,
    binding: Binding,
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(
            mode=capture.CaptureMode.PREVIEW,
            expected_usb_bus=1,
            expected_usb_address=2,
        )
    )

    assert _argument(result.argv, "--expected-usb-bus") == "1"
    assert _argument(result.argv, "--expected-usb-address") == "2"
    assert "--preview-only" in result.argv
    assert result.journal is not None
    assert result.journal["actual_usb_bus"] == 1
    assert result.journal["actual_usb_address"] == 2


@pytest.mark.parametrize(
    "mode", (capture.CaptureMode.METER_ONLY, capture.CaptureMode.FULL)
)
def test_live_meter_and_full_requests_preserve_the_reviewed_usb_topology(
    tmp_path: Path,
    binding: Binding,
    mode: capture.CaptureMode,
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(
            mode=mode,
            selected_slot=18,
            expected_usb_bus=1,
            expected_usb_address=2,
        )
    )

    assert _argument(result.argv, "--expected-usb-bus") == "1"
    assert _argument(result.argv, "--expected-usb-address") == "2"


@pytest.mark.parametrize(
    "mutate",
    (
        lambda journal: journal.update(
            actual_usb_bus=None,
            actual_usb_address=None,
        ),
        lambda journal: journal.update(
            actual_usb_bus=1,
            actual_usb_address=3,
        ),
    ),
)
def test_topology_bound_preview_refuses_missing_or_changed_actual_usb_receipt(
    tmp_path: Path,
    binding: Binding,
    mutate: Callable[[dict[str, object]], None],
) -> None:
    runner = FakeRunner(binding.worker_sha256, mutate_journal=mutate)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(
            mode=capture.CaptureMode.PREVIEW,
            expected_usb_bus=1,
            expected_usb_address=2,
        )
    )

    assert result.outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    assert result.journal is None
    assert result.journal_error is not None
    assert "actual USB topology" in result.journal_error


def test_meter_uses_one_explicit_slot_and_never_passes_expected_count(
    tmp_path: Path, binding: Binding
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.METER_ONLY, selected_slot=18)
    )

    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert _argument(result.argv, "--frame") == "18"
    assert "--meter-only" in result.argv
    assert "--preview-only" not in result.argv
    assert "--expected-frame-count" not in result.argv
    assert result.journal is not None
    assert result.journal["expected_frame_count"] is None


def test_full_capture_uses_complete_stream_confirmation(
    tmp_path: Path, binding: Binding
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.FULL, selected_slot=7)
    )

    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert _argument(result.argv, "--frame") == "7"
    assert _argument(result.argv, "--reads") == "2980"
    assert "--confirm-full-capture" in result.argv
    assert "--meter-only" not in result.argv
    assert "--preview-only" not in result.argv
    assert "--expected-frame-count" not in result.argv
    assert result.paths.output.stat().st_size == 619_458_560


@pytest.mark.parametrize(
    ("slot", "offset"),
    [(1, 0), (1, 144), (2, -144), (18, 73), (40, 144)],
)
def test_per_frame_boundary_offset_is_passed_to_the_isolated_worker(
    tmp_path: Path,
    binding: Binding,
    slot: int,
    offset: int,
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    result = adapter.run_attempt(
        capture.CaptureRequest(
            mode=capture.CaptureMode.FULL,
            selected_slot=slot,
            boundary_offset_rows=offset,
        )
    )

    assert _argument(result.argv, "--boundary-offset-rows") == str(offset)
    assert result.journal is not None
    assert result.journal["requested_boundary_offset_rows"] == offset


@pytest.mark.parametrize(
    ("mode", "slot", "offset"),
    [
        (capture.CaptureMode.PREVIEW, None, 1),
        (capture.CaptureMode.FULL, 1, -1),
        (capture.CaptureMode.FULL, 1, 145),
        (capture.CaptureMode.FULL, 2, -145),
        (capture.CaptureMode.FULL, 2, 145),
        (capture.CaptureMode.FULL, 2, True),
    ],
)
def test_boundary_offset_refuses_values_outside_nikon_ui_semantics(
    mode: capture.CaptureMode,
    slot: int | None,
    offset: int,
) -> None:
    with pytest.raises((TypeError, ValueError), match="boundary offset"):
        capture.CaptureRequest(
            mode=mode,
            selected_slot=slot,
            boundary_offset_rows=offset,
        )


def test_worker_and_materialized_package_plan_are_hash_pinned_before_launch(
    tmp_path: Path,
    binding: Binding,
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)
    result = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )

    assert (
        hashlib.sha256(result.paths.plan.read_bytes()).hexdigest()
        == CANONICAL_PLAN_SHA256
    )
    assert _argument(result.argv, "--plan") == str(result.paths.plan)

    binding.worker.write_text("changed after binding\n", encoding="utf-8")
    with pytest.raises(capture.CaptureIntegrityError, match="worker SHA-256 mismatch"):
        adapter.run_attempt(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    assert len(runner.calls) == 1


def test_manifest_must_bind_the_packaged_plan_before_launch(
    tmp_path: Path, binding: Binding
) -> None:
    binding.manifest.write_text(json.dumps({"plan_sha256": "0" * 64}), encoding="utf-8")
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    with pytest.raises(capture.CaptureIntegrityError, match="not bound"):
        adapter.run_attempt(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    assert runner.calls == []


def test_packaged_factory_uses_isolated_module_dispatch_and_internal_manifest(
    tmp_path: Path,
) -> None:
    runner = FakeRunner(CAPTURE_WORKER_SHA256, CAPTURE_BUNDLE_SHA256)
    adapter = capture.CaptureProcessAdapter.packaged(
        tmp_path / "attempts",
        runner=runner,
    )

    result = adapter.run_attempt(capture.CaptureRequest(capture.CaptureMode.PREVIEW))

    assert result.argv[:4] == (
        sys.executable,
        "-I",
        "-B",
        "-c",
    )
    assert result.argv[4] == capture._PACKAGED_WORKER_BOOTSTRAP
    assert result.argv[6] == capture.PACKAGED_WORKER_MODULE
    assert result.argv[7] == result.paths.bootstrap_nonce
    assert result.argv[8] == capture._worker_argv_sha256(result.argv[9:])
    assert result.paths.manifest.is_file()
    assert _argument(result.argv, "--manifest") == str(result.paths.manifest)
    assert (
        _argument(result.argv, "--expected-capture-bundle-sha256")
        == CAPTURE_BUNDLE_SHA256
    )
    assert result.journal is not None
    assert result.journal["capture_bundle_sha256"] == CAPTURE_BUNDLE_SHA256
    assert result.density_calibration is not None
    assert result.density_calibration.numerators == (57_114, 48_036, 32_683)
    assert result.density_calibration.session_id == "single-reservation-test"


def test_verified_pre_dispatch_worker_bootstrap_failure_is_not_recovery_required(
    tmp_path: Path,
    binding: Binding,
) -> None:
    def bootstrap_failure(
        argv: Sequence[str], *, cwd: Path
    ) -> subprocess.CompletedProcess[str]:
        del cwd
        command = tuple(argv)
        marker = command.index(capture._PACKAGED_WORKER_BOOTSTRAP)
        Path(command[marker + 1]).write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "state": "failed-before-ready",
                    "nonce": command[marker + 3],
                    "worker_argv_sha256": command[marker + 4],
                    "error_type": "ModuleNotFoundError",
                    "error_message": "No module named 'coolscanpy'",
                }
            ),
            encoding="utf-8",
        )
        return subprocess.CompletedProcess(command, 1, "", "")

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        launcher=(sys.executable,),
        bootstrap_module=capture.PACKAGED_WORKER_MODULE,
        runner=bootstrap_failure,
    )

    result = adapter.run_attempt(capture.CaptureRequest(capture.CaptureMode.PREVIEW))

    assert result.outcome is capture.CaptureOutcome.BOOTSTRAP_FAILED
    assert result.recovery_required is False
    assert result.journal is None
    assert result.journal_error is not None
    assert "CAPTURE_WORKER_BOOTSTRAP_FAILED" in result.journal_error
    assert "before scanner dispatch" in result.journal_error


def test_unmarked_no_journal_remains_recovery_required(
    tmp_path: Path,
    binding: Binding,
) -> None:
    runner = FakeRunner(
        binding.worker_sha256,
        returncode=1,
        write_journal=False,
    )
    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        launcher=(sys.executable,),
        bootstrap_module=capture.PACKAGED_WORKER_MODULE,
        runner=runner,
    )

    result = adapter.run_attempt(capture.CaptureRequest(capture.CaptureMode.PREVIEW))

    assert result.outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    assert result.recovery_required is True
    assert result.journal is None


def test_ready_bootstrap_marker_without_journal_remains_recovery_required(
    tmp_path: Path,
    binding: Binding,
) -> None:
    def exited_after_ready(
        argv: Sequence[str], *, cwd: Path
    ) -> subprocess.CompletedProcess[str]:
        del cwd
        command = tuple(argv)
        marker = command.index(capture._PACKAGED_WORKER_BOOTSTRAP)
        Path(command[marker + 1]).write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "state": "ready",
                    "nonce": command[marker + 3],
                    "worker_argv_sha256": command[marker + 4],
                }
            ),
            encoding="utf-8",
        )
        return subprocess.CompletedProcess(command, 1, "", "")

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        launcher=(sys.executable,),
        bootstrap_module=capture.PACKAGED_WORKER_MODULE,
        runner=exited_after_ready,
    )

    result = adapter.run_attempt(capture.CaptureRequest(capture.CaptureMode.PREVIEW))

    assert result.outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    assert result.recovery_required is True
    assert result.journal is None


def test_verified_batch_bootstrap_failure_is_not_recovery_required(
    tmp_path: Path,
    binding: Binding,
) -> None:
    class FailedBeforeDispatch:
        def poll(self) -> int:
            return 1

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            return 1

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> FailedBeforeDispatch:
        del cwd, stdout, stderr
        command = tuple(argv)
        marker = command.index(capture._PACKAGED_WORKER_BOOTSTRAP)
        Path(command[marker + 1]).write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "state": "failed-before-ready",
                    "nonce": command[marker + 3],
                    "worker_argv_sha256": command[marker + 4],
                    "error_type": "ModuleNotFoundError",
                    "error_message": "No module named 'coolscanpy'",
                }
            ),
            encoding="utf-8",
        )
        return FailedBeforeDispatch()

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        launcher=(sys.executable,),
        bootstrap_module=capture.PACKAGED_WORKER_MODULE,
        batch_spawner=spawn,
        batch_poll_seconds=0,
    )
    request = capture.CaptureBatchRequest(
        frames=(capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    with pytest.raises(capture.CaptureBatchProcessError) as excinfo:
        adapter.run_batch_session(
            request,
            frame_handler=lambda _result: capture.BatchAckAction.CONTINUE,
        )

    assert excinfo.value.outcome is capture.CaptureOutcome.BOOTSTRAP_FAILED
    assert excinfo.value.recovery_required is False
    assert "CAPTURE_WORKER_BOOTSTRAP_FAILED" in str(excinfo.value)


def test_packaged_factory_uses_frozen_app_helper_dispatch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    runner = FakeRunner(CAPTURE_WORKER_SHA256, CAPTURE_BUNDLE_SHA256)
    adapter = capture.CaptureProcessAdapter.packaged(
        tmp_path / "attempts",
        runner=runner,
    )

    result = adapter.run_attempt(capture.CaptureRequest(capture.CaptureMode.PREVIEW))

    assert result.argv[:2] == (sys.executable, capture.CAPTURE_HELPER_FLAG)
    assert "-m" not in result.argv[:2]


def test_attempt_paths_never_overlap_and_capture_stdout_stderr(
    tmp_path: Path, binding: Binding
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)

    first = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )
    second = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )

    assert first.paths.directory != second.paths.directory
    assert first.paths.stdout.read_text(encoding="utf-8") == runner.stdout
    assert first.paths.stderr.read_text(encoding="utf-8") == runner.stderr
    assert first.stdout == runner.stdout
    assert first.stderr == runner.stderr


def test_synchronized_refusal_is_safe_to_retry_without_power_cycle(
    tmp_path: Path, binding: Binding
) -> None:
    runner = FakeRunner(
        binding.worker_sha256,
        status="failed",
        recovery="none",
        returncode=1,
    )
    result = _adapter(tmp_path, binding, runner).run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.METER_ONLY, selected_slot=18)
    )

    assert result.outcome is capture.CaptureOutcome.SYNCHRONIZED_REFUSAL
    assert result.recovery_required is False
    assert result.journal_error is None


def test_desynchronized_failure_requires_power_cycle(
    tmp_path: Path, binding: Binding
) -> None:
    runner = FakeRunner(
        binding.worker_sha256,
        status="failed",
        recovery=capture.POWER_CYCLE_RECOVERY,
        returncode=1,
    )
    result = _adapter(tmp_path, binding, runner).run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.FULL, selected_slot=18)
    )

    assert result.outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    assert result.recovery_required is True
    assert result.journal is not None


def test_completed_frame_capture_requires_resolved_boundary_offset_evidence(
    tmp_path: Path,
    binding: Binding,
) -> None:
    runner = FakeRunner(
        binding.worker_sha256,
        mutate_journal=lambda journal: journal.update(
            applied_boundary_offset_rows=12,
            resolved_native_origin=None,
        ),
    )
    request = capture.CaptureRequest(
        mode=capture.CaptureMode.FULL,
        selected_slot=18,
        boundary_offset_rows=11,
    )

    result = _adapter(tmp_path, binding, runner).run_attempt(request)

    assert result.outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    assert result.journal is None
    assert "applied_boundary_offset_rows" in (result.journal_error or "")


@pytest.mark.parametrize(
    "runner_factory",
    [
        lambda digest: FakeRunner(digest, returncode=1, write_journal=False),
        lambda digest: FakeRunner(
            digest,
            returncode=1,
            status="failed",
            recovery="mystery",
        ),
        lambda digest: FakeRunner(
            digest,
            mutate_journal=lambda journal: journal.update(
                capture_engine_sha256="f" * 64
            ),
        ),
        lambda digest: FakeRunner(
            digest,
            mutate_journal=_tamper_density_calibration_payload,
        ),
    ],
)
def test_missing_or_untrustworthy_journal_fails_closed_to_recovery(
    tmp_path: Path,
    binding: Binding,
    runner_factory: Callable[[str], FakeRunner],
) -> None:
    runner = runner_factory(binding.worker_sha256)
    result = _adapter(tmp_path, binding, runner).run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )

    assert result.outcome is capture.CaptureOutcome.RECOVERY_REQUIRED
    assert result.recovery_required is True
    assert result.journal is None
    assert result.journal_error


def test_stop_requested_during_child_waits_for_that_attempt_then_blocks_next(
    tmp_path: Path,
    binding: Binding,
) -> None:
    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)
    runner.during_run = adapter.request_stop

    active = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )

    assert active.outcome is capture.CaptureOutcome.COMPLETE
    with pytest.raises(capture.CaptureStopped, match="between attempts"):
        adapter.run_attempt(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    assert len(runner.calls) == 1

    adapter.clear_stop()
    runner.during_run = None
    resumed = adapter.run_attempt(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )
    assert resumed.outcome is capture.CaptureOutcome.COMPLETE


@pytest.mark.parametrize(
    "request_factory",
    [
        lambda: capture.CaptureRequest(
            mode=capture.CaptureMode.PREVIEW, selected_slot=1
        ),
        lambda: capture.CaptureRequest(mode=capture.CaptureMode.METER_ONLY),
        lambda: capture.CaptureRequest(mode=capture.CaptureMode.FULL, selected_slot=0),
        lambda: capture.CaptureRequest(
            mode=capture.CaptureMode.FULL, selected_slot=True
        ),
        lambda: capture.CaptureRequest(mode=capture.CaptureMode.FULL, selected_slot=41),
        lambda: capture.CaptureRequest(
            mode=capture.CaptureMode.PREVIEW,
            expected_usb_bus=1,
        ),
        lambda: capture.CaptureRequest(
            mode=capture.CaptureMode.PREVIEW,
            expected_usb_bus=True,
            expected_usb_address=2,
        ),
        lambda: capture.CaptureRequest(
            mode=capture.CaptureMode.PREVIEW,
            expected_usb_bus=1,
            expected_usb_address=0,
        ),
    ],
)
def test_request_rejects_ambiguous_or_out_of_capacity_slots(
    request_factory: Callable[[], object],
) -> None:
    with pytest.raises(ValueError):
        request_factory()


def test_default_runner_uses_argv_without_shell_and_isolates_child_signals(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    recorded: dict[str, object] = {}

    def fake_run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        recorded["argv"] = argv
        recorded.update(kwargs)
        return subprocess.CompletedProcess(argv, 0, "out", "err")

    monkeypatch.setattr(capture.subprocess, "run", fake_run)
    result = capture._run_subprocess(["python", "worker.py", "--live"], cwd=tmp_path)

    assert result.returncode == 0
    assert recorded["argv"] == ["python", "worker.py", "--live"]
    assert recorded["shell"] is False
    assert recorded["start_new_session"] is True
    assert recorded["capture_output"] is True


def test_roll_fingerprint_skips_trailing_sliver_and_filters_origins_in_lockstep() -> (
    None
):
    rgb, intervals = _fingerprint_raster()
    sliver_rows = capture.MIN_FINGERPRINT_FRAME_ROWS - 14
    padded = np.concatenate((rgb, rgb[-sliver_rows:, :, :]), axis=0)
    with_sliver = intervals + ((len(rgb), len(rgb) + sliver_rows),)
    origins = tuple(6_000 + 6_000 * index for index in range(len(with_sliver)))

    fingerprint = capture.build_reviewed_roll_fingerprint(
        padded,
        frame_intervals=with_sliver,
        frame_native_origins=origins,
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )

    assert len(fingerprint.frame_start_rows) == len(intervals)
    assert len(fingerprint.frame_native_origins) == len(intervals)
    assert len(fingerprint.frame_visual_hashes) == len(intervals)
    assert origins[-1] not in fingerprint.frame_native_origins
    assert len(rgb) not in fingerprint.frame_start_rows


def test_sliver_bearing_and_sliver_free_traversals_stay_comparable() -> None:
    rgb, intervals = _fingerprint_raster()
    sliver_rows = 3
    padded = np.concatenate((rgb, rgb[-sliver_rows:, :, :]), axis=0)
    origins = tuple(6_000 + 6_000 * index for index in range(len(intervals)))

    reviewed = capture.build_reviewed_roll_fingerprint(
        padded,
        frame_intervals=intervals + ((len(rgb), len(rgb) + sliver_rows),),
        frame_native_origins=origins + (origins[-1] + 6_000,),
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )
    fresh = capture.build_reviewed_roll_fingerprint(
        rgb,
        frame_intervals=intervals,
        frame_native_origins=origins,
        source_preview_sha256="4" * 64,
        source_table_sha256="5" * 64,
    )

    comparison = capture.compare_reviewed_roll_fingerprints(reviewed, fresh)
    assert comparison.matches is True


def test_roll_fingerprint_rejects_all_sliver_rolls() -> None:
    rgb, _ = _fingerprint_raster()
    with pytest.raises(ValueError, match="at least one frame interval"):
        capture.build_reviewed_roll_fingerprint(
            rgb,
            frame_intervals=((0, 2), (2, 5)),
            frame_native_origins=(6_000, 12_000),
            source_preview_sha256="1" * 64,
            source_table_sha256="2" * 64,
        )
