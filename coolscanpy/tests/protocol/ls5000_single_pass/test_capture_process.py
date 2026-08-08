"""Hardware-free contracts for the process-isolated RGBI4x capture bridge."""

from __future__ import annotations

import hashlib
import json
import secrets
import subprocess
import sys
import threading
from collections.abc import Callable, Sequence
from dataclasses import FrozenInstanceError, dataclass, field, replace
from functools import lru_cache
from pathlib import Path
from types import SimpleNamespace
from typing import Any

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
    calibration_session_id: str | None = None,
    density_source_path: Path | None = None,
) -> tuple[dict[str, object], str, str]:
    """Build exact density evidence/ownership for a synthetic batch frame.

    ``calibration_session_id`` defaults to the job's own session id --
    correct for a cold batch (see ``_batch_session_provenance``) -- so
    every existing cold-batch caller is unaffected; a held/resumed caller
    passes its own separately to model the real divergence between a
    batch/round's own session id and the reservation-wide calibration
    identity.

    ``density_source_path`` is the same divergence for the reservation's
    97-dpi density source raster, and for the ``capture_attempt_id`` bound
    into its evidence. A cold batch's whole-roll traversal runs inside the
    batch child interleaved with its own first frame, so both live in that
    frame's directory -- the default. A preview-and-hold reservation
    completed its traversal in the *held preview attempt's* directory,
    before any frame directory existed, and a resume inherits it from
    there: a held caller must pass that path or this fixture models a
    layout the real worker never produces (which is exactly how the
    2026-08-06 attempt-11 live failure reached hardware with a green suite).
    """

    job = json.loads(job_path.read_text(encoding="utf-8"))
    session_id = job["session_id"]
    calibration_session_id = calibration_session_id or session_id
    selected_slots = tuple(frame["slot"] for frame in job["frames"])
    first_output = job_path.parent / job["frames"][0]["output"]
    source_path = (
        first_output.with_name(f"{first_output.stem}-preview.bin")
        if density_source_path is None
        else density_source_path
    )
    calibration = single_pass.DensityCalibration.from_dict(
        _density_calibration_provenance(calibration_session_id)[
            "nikon_density_calibration"
        ]
    )
    source = _density_source_fixture()
    evidence = single_pass.build_nikon_density_evidence(
        source,
        calibration=calibration,
        density_f03_exposures_raw_10ns=(70_307, 136_614, 125_470),
        session_id=calibration_session_id,
        capture_attempt_id=source_path.parent.name,
        scan_identity=(
            f"{calibration_session_id}:density-97dpi:"
            f"{hashlib.sha256(source).hexdigest()}"
        ),
    )
    if frame_index == 1 and not source_path.exists():
        source_path.write_bytes(source)
    reviewed_sha = job["reviewed_roll_fingerprint"]["binding_sha256"]
    table_sha = "e" * 64
    ownership = single_pass.build_nikon_density_frame_ownership(
        evidence,
        reservation_id=calibration_session_id,
        batch_session_id=calibration_session_id,
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
        source_path=capture._density_source_path(output),
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
            expected_batch_session_id=session_id,
            expected_calibration_session_id=session_id,
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
    *,
    calibration_session_id: str | None = None,
) -> dict[str, object]:
    """``calibration_session_id`` defaults to the job's own session id --
    correct for a cold batch, where they coincide (see
    ``PreparedCaptureBatch``'s docstring) -- so every existing cold-batch
    caller is unaffected. A held/resumed caller passes its own separately
    to model the real divergence.
    """

    job = json.loads(job_path.read_text(encoding="utf-8"))
    return {
        **_density_calibration_provenance(calibration_session_id or job["session_id"]),
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


def _one_frame_batch_request(
    exposure_override_10ns: object = None,
) -> capture.CaptureBatchRequest:
    return capture.CaptureBatchRequest(
        frames=(
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=1,
                boundary_offset_rows=0,
            ),
        ),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
        exposure_override_10ns=exposure_override_10ns,
    )


def test_batch_request_exposure_override_defaults_to_none_and_is_byte_identical() -> None:
    """API surface default: omitting exposure_override_10ns is today's
    behavior, unchanged."""

    request = _one_frame_batch_request()

    assert request.exposure_override_10ns is None


def test_batch_request_accepts_a_valid_exposure_override() -> None:
    request = _one_frame_batch_request((97_482, 195_597, 180_705))

    assert request.exposure_override_10ns == (97_482, 195_597, 180_705)


@pytest.mark.parametrize(
    ("bad_override", "channel"),
    [
        ((0, 90_000, 90_000), "red"),
        ((90_000, 0, 90_000), "green"),
        ((90_000, 90_000, 0), "blue"),
        ((-1, 90_000, 90_000), "red"),
        ((90_000, -1, 90_000), "green"),
        ((90_000, 90_000, -1), "blue"),
        ((49_999, 90_000, 90_000), "red"),
        ((90_000, 49_999, 90_000), "green"),
        ((90_000, 90_000, 49_999), "blue"),
        ((400_001, 90_000, 90_000), "red"),
        ((90_000, 400_001, 90_000), "green"),
        ((90_000, 90_000, 400_001), "blue"),
    ],
)
def test_batch_request_refuses_exposure_override_ticks_outside_metered_bounds(
    bad_override: tuple[int, int, int],
    channel: str,
) -> None:
    """Validation reuses the AE contract machinery's own metered-tick
    bounds (EXPOSURE_MIN/EXPOSURE_MAX in meter.py, currently [50_000,
    400_000]) rather than inventing new ones, and names the offending
    channel."""

    with pytest.raises(ValueError, match=channel):
        _one_frame_batch_request(bad_override)


@pytest.mark.parametrize(
    "bad_override",
    [
        (90_000, 90_000),
        (90_000, 90_000, 90_000, 90_000),
        "90000,90000,90000",
        (90_000, 90_000, True),
        (90_000, 90_000, 90_000.0),
    ],
)
def test_batch_request_refuses_malformed_exposure_override_shape(bad_override: object) -> None:
    with pytest.raises(ValueError, match="exposure_override_10ns"):
        _one_frame_batch_request(bad_override)


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
        "exposure_override_10ns": None,
        "manual_boundary_rows": None,
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


def test_prepare_batch_session_threads_exposure_override_into_the_batch_job(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """The exposure_override_10ns choke point on this side of the process
    boundary: it must reach the published batch-job.json unchanged (as a
    3-element array -- JSON has no tuple type), the one hand-off
    capture_process.py owns between CaptureBatchRequest and the worker
    subprocess that reads it back via load_validated_batch_job."""

    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)
    request = capture.CaptureBatchRequest(
        frames=(
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=1,
                boundary_offset_rows=0,
            ),
        ),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
        exposure_override_10ns=(97_482, 195_597, 180_705),
    )

    prepared = adapter.prepare_batch_session(request)
    job = json.loads(prepared.paths.job.read_text(encoding="utf-8"))

    assert job["exposure_override_10ns"] == [97_482, 195_597, 180_705]


def test_prepare_batch_session_threads_manual_boundary_rows_into_the_batch_job(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): same choke point as
    exposure_override_10ns above, for the operator-picked rows a manual
    placement session hands Roll.scan_many() -- must reach the published
    batch-job.json unchanged (as a plain array; JSON has no tuple type)."""

    runner = FakeRunner(binding.worker_sha256)
    adapter = _adapter(tmp_path, binding, runner)
    request = capture.CaptureBatchRequest(
        frames=(
            capture.CaptureRequest(
                mode=capture.CaptureMode.FULL,
                selected_slot=1,
                boundary_offset_rows=0,
            ),
        ),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
        manual_boundary_rows=(128, 271, 414),
    )

    prepared = adapter.prepare_batch_session(request)
    job = json.loads(prepared.paths.job.read_text(encoding="utf-8"))

    assert job["manual_boundary_rows"] == [128, 271, 414]


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


def test_held_preview_spawn_uses_the_same_bootstrap_prefix_as_every_other_launch(
    tmp_path: Path,
    binding: Binding,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A source/wheel install launches the worker through the stdlib
    bootstrap under an isolated interpreter -- ``_launcher`` alone is just
    ``(sys.executable,)`` and cannot run anything. ``_build_held_preview_argv``
    used to prepend ``_launcher`` directly, so the packaged adapter's held
    preview came out as ``python --plan ...``, which no interpreter accepts:
    preview-and-hold, and therefore every multi-batch-per-feed session, was
    unlaunchable outside a frozen build. Pin the prefix and the bundle
    assertion against the cold batch's own, which is the contract.
    """

    spawned: list[tuple[str, ...]] = []

    class NeverReady:
        def poll(self) -> int:
            return 0

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            return 0

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> NeverReady:
        del cwd, stdout, stderr
        spawned.append(tuple(argv))
        return NeverReady()

    adapter = capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        launcher=(sys.executable,),
        bootstrap_module=capture.PACKAGED_WORKER_MODULE,
        expected_bundle_sha256=CAPTURE_BUNDLE_SHA256,
        verify_worker_source=False,
        batch_spawner=spawn,
        batch_poll_seconds=0,
    )

    held = adapter.begin_held_preview(
        capture.CaptureRequest(
            capture.CaptureMode.PREVIEW,
            expected_usb_bus=1,
            expected_usb_address=2,
        )
    )
    # The child exited without ever publishing an awaiting-hold-job journal,
    # so this is an unusable session -- which is fine here: the argv is what
    # is under test, and it was already built before the spawn.
    assert held.usable is False
    assert len(spawned) == 1
    argv = spawned[0]

    assert argv[0] == sys.executable
    assert argv[1:4] == ("-I", "-B", "-c")
    assert argv[4] == capture._PACKAGED_WORKER_BOOTSTRAP
    assert argv[6] == capture.PACKAGED_WORKER_MODULE
    # The launcher receipt binds this exact bootstrap status file/nonce to
    # this exact worker argv -- the binding _verified_bootstrap_failure
    # re-derives before it will believe any bootstrap marker at all.
    assert argv[5] == str(held.preview_attempt.paths.bootstrap_status)
    assert argv[7] == held.preview_attempt.paths.bootstrap_nonce
    assert argv[8] == capture._worker_argv_sha256(argv[9:])
    assert "--preview-and-hold" in argv[9:]
    # Asserted on the child's own command line by every other live launch
    # shape (_build_argv, _build_batch_argv), and now by this one.
    assert "--expected-capture-bundle-sha256" in argv[9:]
    assert _argument(argv, "--expected-capture-bundle-sha256") == CAPTURE_BUNDLE_SHA256

    # And the resume that follows reuses this same argv/status/nonce, so a
    # bootstrap receipt stays verifiable across the whole reservation.
    monkeypatch.setattr(adapter, "_batch_poll_seconds", 0)
    assert held.preview_attempt.argv == argv


def test_held_preview_bootstrap_failure_is_not_reported_as_a_parked_feeder(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """``_interpret_held_preview_launch_failure`` conservatively requires
    recovery for any untrustworthy journal. A verified pre-dispatch
    bootstrap receipt is not that case -- the scanner was never touched --
    and every other launch shape already distinguishes it
    (``_interpret_result``). Reporting RECOVERY_REQUIRED here tells the
    operator to power-cycle a scanner over a missing Python module.
    """

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

    held = adapter.begin_held_preview(
        capture.CaptureRequest(capture.CaptureMode.PREVIEW)
    )

    assert held.usable is False
    attempt = held.preview_attempt
    assert attempt.outcome is capture.CaptureOutcome.BOOTSTRAP_FAILED
    assert attempt.recovery_required is False
    assert attempt.journal is None
    assert attempt.journal_error is not None
    assert "CAPTURE_WORKER_BOOTSTRAP_FAILED" in attempt.journal_error
    assert "before scanner dispatch" in attempt.journal_error


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


# ===========================================================================
# Held preview: begin_held_preview / resume_held_session / release_held_session
#
# These cover the refeed-elimination fix's five required scenarios directly
# against the adapter (below Roll, mirroring this file's own FakeRunner/
# inline-FakeBatchProcess convention): (a) a held preview never releases;
# (b) resuming it launches no second worker process (i.e. no fresh
# RESERVE_UNIT/command-64 -- both only ever happen inside a freshly spawned
# child); (c) a cold run_batch_session's own argv is untouched by any of
# this; (d) a held session that turns out to be dead maps to
# HeldSessionExpired; (e) an explicit release publishes exactly one
# release decision.
# ===========================================================================


@dataclass
class FakeHeldBatchProcess:
    """RunningBatchProcess double for a ``--preview-and-hold`` launch.

    Mirrors the real worker's own two-phase shape (see
    ``run_live_capture``'s ``preview_and_hold`` branch): writes an
    ``awaiting-hold-job`` journal immediately, then ``poll()`` returns
    ``None`` until ``hold-ack.json`` appears. ``"release"`` finalizes the
    attempt journal as a released preview and exits; ``"scan"`` reads the
    now-published ``hold-job.json`` and emits/acks frames exactly like this
    file's own batch fakes (e.g. ``test_batch_parent_finalizes_each_frame_
    before_acknowledging_the_next``'s local ``FakeBatchProcess``).
    """

    output_path: Path
    journal_path: Path
    hold_job_path: Path
    hold_ack_path: Path
    worker_sha256: str
    hold_session_id: str = field(default_factory=lambda: secrets.token_hex(16))
    # Reservation-wide, unlike hold_session_id: minted once here and never
    # reset across hold rounds (see poll()'s held_resume branch), exactly
    # mirroring the real worker's calibration_session_id -- independently
    # minted from any batch/round's own session id (PreparedCaptureBatch's
    # docstring).
    calibration_session_id: str = field(
        default_factory=lambda: f"single-reservation-{secrets.token_hex(16)}"
    )
    events: list[str] = field(default_factory=list)
    journal_overrides: dict[str, Any] | None = None
    # journal_overrides' sibling for the *other* hold boundary: corrupts one
    # field of the held-after-batch session journal a continue_hold ack
    # publishes, while the child itself keeps behaving normally (it minted a
    # real next-round hold_session_id and is parked on that round's hold-ack
    # file). The reservation is live while the parent refuses -- the shape
    # every _resolve_held_after_batch refusal has.
    held_after_batch_journal_overrides: dict[str, Any] | None = None
    _job: dict[str, Any] | None = field(default=None, init=False)
    _frame_index: int = field(default=0, init=False)
    _returncode: int | None = field(default=None, init=False)
    # Set by _poll_batch() when a frame ack is "continue_hold": poll()
    # notices this on the very next call, drops the finished batch, and
    # resets hold_job_path/hold_ack_path/hold_session_id to the fresh
    # round this names -- mirroring the real worker looping the same
    # child back into wait_for_hold_decision.
    held_resume: dict[str, str] | None = field(default=None, init=False)
    # Where a "release"/"eject" hold-ack's completion receipt is written.
    # Round 0 is journal_path itself (pre-populated by __post_init__
    # below); a later round (after a continue_hold reset) is a fresh,
    # dedicated file named by that round's own hold_resume -- matching
    # the real worker's hold_wait_release_receipt_path.
    _release_journal_path: Path = field(default=None, init=False)  # type: ignore[assignment]

    @property
    def density_source_path(self) -> Path:
        """This reservation's 97-dpi density source raster, where the real
        worker puts it for a preview-and-hold: beside the *preview
        attempt's* own output, not beside any frame's."""

        return self.output_path.with_name(f"{self.output_path.stem}-preview.bin")

    def __post_init__(self) -> None:
        self.output_path.write_bytes(b"")
        # Persisted at preview time, exactly like the real worker's
        # `_write_bytes_exclusive(artifact_paths["preview"], preview_bytes)`
        # -- long before any frame directory exists, and never rewritten by
        # any later round of the same reservation.
        self.density_source_path.write_bytes(_density_source_fixture())
        journal = {
            "status": "awaiting-hold-job",
            "capture_mode": "preview-and-hold",
            "hold_session_id": self.hold_session_id,
            "density_calibration_session_id": self.calibration_session_id,
            "requested_frame": None,
            "requested_boundary_offset_rows": 0,
            "expected_frame_count": None,
            "expected_reads": 0,
            "completed_reads": 0,
            "expected_bytes": 0,
            "completed_bytes": 0,
            "disk_bytes": 0,
            "unit_released": False,
            "recovery_required": None,
            "output": str(self.output_path.resolve()),
            "output_sha256": hashlib.sha256(b"").hexdigest(),
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "capture_engine_sha256": self.worker_sha256,
        }
        # journal_overrides corrupts exactly one published field while the
        # child stays parked at the hold boundary -- the shape of every
        # integrity refusal _wait_for_held_preview_ready can raise. The
        # child itself keeps behaving normally (it minted a real
        # hold_session_id and is still blocked on hold-ack.json), which is
        # the whole point: the reservation is live while the parent refuses.
        if self.journal_overrides is not None:
            journal.update(self.journal_overrides)
        self.journal_path.write_text(json.dumps(journal), encoding="utf-8")
        self.events.append("preview-hold-ready")
        self._release_journal_path = self.journal_path

    def die(self, returncode: int = 1) -> None:
        """Simulate the child having already exited (crash, power cycle,
        or an auto-eject the worker itself detected and gave up on) --
        discovered only when a resume/release is attempted next."""

        self._returncode = returncode

    def poll(self) -> int | None:
        if self._returncode is not None:
            return self._returncode
        if self._job is not None:
            if self.held_resume is not None:
                # The batch's own terminal frame ack was "continue_hold":
                # it published a fresh hold_resume and is done polling.
                # Drop it and reset to hold-wait at the paths it named --
                # mirroring the real worker looping the same child back
                # into wait_for_hold_decision.
                resume = self.held_resume
                self.held_resume = None
                self._job = None
                self._frame_index = 0
                self.hold_job_path = Path(resume["hold_job_path"])
                self.hold_ack_path = Path(resume["hold_ack_path"])
                self.hold_session_id = resume["hold_session_id"]
                self._release_journal_path = Path(resume["hold_release_journal_path"])
                return None
            return self._poll_batch()
        if not self.hold_ack_path.exists():
            return None
        ack = json.loads(self.hold_ack_path.read_text(encoding="utf-8"))
        self.events.append(f"hold-ack-{ack['action']}")
        if ack["hold_session_id"] != self.hold_session_id:
            # worker.wait_for_hold_decision exact-matches the id it minted
            # and raises SynchronizedProtocolError otherwise. That lands in
            # run_live_capture's synchronized-cleanup path, which still
            # releases the unit but finalizes a failed journal and exits
            # non-zero -- the honest outcome for a decision the parent could
            # only publish unbound, and still an exit rather than a child
            # left holding the reservation for the wait's full timeout.
            journal = json.loads(self.journal_path.read_text(encoding="utf-8"))
            journal.update(
                status="failed",
                error="SynchronizedProtocolError: hold decision has an "
                "unexpected hold_session_id",
                recovery_required="none",
                unit_released=True,
            )
            self.journal_path.write_text(json.dumps(journal), encoding="utf-8")
            self.events.append("hold-ack-refused")
            self._returncode = 1
            return 1
        if ack["action"] == "release":
            journal = (
                json.loads(self._release_journal_path.read_text(encoding="utf-8"))
                if self._release_journal_path.exists()
                else {}
            )
            journal.update(
                status="complete",
                capture_mode="preview-and-hold",
                hold_outcome="released",
                unit_released=True,
            )
            self._release_journal_path.write_text(
                json.dumps(journal), encoding="utf-8"
            )
            self._returncode = 0
            return 0
        if ack["action"] == "eject":
            # Mirrors "release" (still a preview-and-hold attempt that never
            # scanned) but with the traced eject sequence's own evidence
            # recorded, exactly as worker.py's real teardown does.
            journal = (
                json.loads(self._release_journal_path.read_text(encoding="utf-8"))
                if self._release_journal_path.exists()
                else {}
            )
            journal.update(
                status="complete",
                capture_mode="preview-and-hold",
                hold_outcome="ejected",
                unit_released=True,
                eject={
                    "eject_cdb_status": "0000000000000000",
                    "eject_execute_status": "0000000000000000",
                    "terminal_sense": "023a00",
                    "wait_polls": 5,
                    "stall_recoveries": 0,
                },
            )
            self._release_journal_path.write_text(
                json.dumps(journal), encoding="utf-8"
            )
            self._returncode = 0
            return 0
        self._job = json.loads(self.hold_job_path.read_text(encoding="utf-8"))
        # The real worker overwrites the session journal to "capturing"
        # immediately on processing "scan", strictly before it captures
        # anything -- sequentially before the frame this round's own
        # frame-complete journal reports. That ordering is what keeps a
        # later round's own _resolve_held_after_batch poll from ever
        # observing a *previous* round's stale "held" entry still sitting
        # in the same file: by the time the parent sees this round's frame
        # complete, "capturing" has already superseded it. Mirror that
        # here, or a third (or later) round-ending continue_hold can race
        # and validate against the wrong round's session_id.
        session_journal_path = self.hold_job_path.with_name("session-journal.json")
        session_journal_path.write_text(
            json.dumps(
                {
                    **_batch_session_provenance(
                        self.hold_job_path,
                        self.worker_sha256,
                        calibration_session_id=self.calibration_session_id,
                    ),
                    "completed_slots": [],
                    "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
                    "plan_sha256": CANONICAL_PLAN_SHA256,
                    "recovery_required": None,
                    "reservation_acquired": True,
                    "selected_slots": [item["slot"] for item in self._job["frames"]],
                    "session_id": self._job["session_id"],
                    "status": "capturing",
                    "unit_release_attempts": 0,
                    "unit_released": False,
                }
            ),
            encoding="utf-8",
        )
        self._emit_frame()
        return None

    def _emit_frame(self) -> None:
        assert self._job is not None
        frame = self._job["frames"][self._frame_index]
        directory = self.hold_job_path.parent
        output = directory / frame["output"]
        frame_journal = directory / frame["journal"]
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("xb") as stream:
            stream.truncate(CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES)
        density, preview_sha, table_sha = _batch_density_frame_provenance(
            self.hold_job_path,
            output=output,
            frame_index=self._frame_index + 1,
            selected_slot=frame["slot"],
            calibration_session_id=self.calibration_session_id,
            density_source_path=self.density_source_path,
        )
        frame_journal.write_text(
            json.dumps(
                {
                    **_density_calibration_provenance(self.calibration_session_id),
                    **density,
                    "ack_nonce": f"nonce-{frame['slot']}",
                    "batch_session": {
                        "frame_index": self._frame_index + 1,
                        "frame_total": len(self._job["frames"]),
                        "selected_slots": [item["slot"] for item in self._job["frames"]],
                        "session_id": self._job["session_id"],
                    },
                    "capture_engine_sha256": self.worker_sha256,
                    "capture_mode": "full",
                    "completed_bytes": CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
                    "completed_reads": CANONICAL_FINE_READ_COUNT,
                    "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
                    "disk_bytes": CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
                    "expected_bytes": CANONICAL_FINE_READ_COUNT * CANONICAL_FINE_READ_BYTES,
                    "expected_reads": CANONICAL_FINE_READ_COUNT,
                    "frame_complete": True,
                    "live_frame_selection": {
                        "frame": frame["slot"],
                        "preview_sha256": preview_sha,
                        "table_sha256": table_sha,
                        "roll_identity": _roll_identity_evidence(
                            self._job["reviewed_roll_fingerprint"]["binding_sha256"],
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
                    "reviewed_roll_fingerprint_sha256": (
                        self._job["reviewed_roll_fingerprint"]["binding_sha256"]
                    ),
                    "session_reservation_retained": True,
                    "status": "frame-complete",
                    "unit_released": False,
                }
            ),
            encoding="utf-8",
        )
        self.events.append(f"ready-{frame['slot']}")

    def _poll_batch(self) -> int | None:
        assert self._job is not None
        frame = self._job["frames"][self._frame_index]
        ack_path = self.hold_job_path.parent / frame["ack"]
        if not ack_path.exists():
            return None
        ack = json.loads(ack_path.read_text(encoding="utf-8"))
        self.events.append(f"ack-{frame['slot']}-{ack['action']}")
        if ack["action"] == "continue" and self._frame_index + 1 < len(self._job["frames"]):
            self._frame_index += 1
            self._emit_frame()
            return None
        completed = [item["slot"] for item in self._job["frames"][: self._frame_index + 1]]
        if ack["action"] == "continue_hold":
            # This batch's own terminal frame chose to keep the
            # reservation held instead of releasing: publish a fresh
            # round's hold_resume into the session journal (status
            # "held", unit_released False) and record it on self so the
            # very next poll() resets to a fresh hold-wait -- see poll()'s
            # own held_resume branch above.
            next_hold_session_id = secrets.token_hex(16)
            next_hold_job_path = self.hold_job_path.with_name(
                f"hold-job-{next_hold_session_id}.json"
            )
            next_hold_ack_path = self.hold_job_path.with_name(
                f"hold-ack-{next_hold_session_id}.json"
            )
            resume = {
                "hold_session_id": next_hold_session_id,
                "hold_job_path": str(next_hold_job_path),
                "hold_ack_path": str(next_hold_ack_path),
                "hold_release_journal_path": str(
                    self.hold_job_path.with_name(
                        f"hold-release-{next_hold_session_id}.json"
                    )
                ),
            }
            session_journal_path = self.hold_job_path.with_name("session-journal.json")
            session_journal = {
                **_batch_session_provenance(
                    self.hold_job_path,
                    self.worker_sha256,
                    calibration_session_id=self.calibration_session_id,
                ),
                "completed_slots": completed,
                "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
                "plan_sha256": CANONICAL_PLAN_SHA256,
                "recovery_required": None,
                "reservation_acquired": True,
                "selected_slots": [item["slot"] for item in self._job["frames"]],
                "session_id": self._job["session_id"],
                "status": "held",
                "unit_release_attempts": 0,
                "unit_released": False,
                "hold_resume": resume,
            }
            if self.held_after_batch_journal_overrides is not None:
                session_journal.update(self.held_after_batch_journal_overrides)
            session_journal_path.write_text(
                json.dumps(session_journal), encoding="utf-8"
            )
            self.held_resume = resume
            return None
        session_journal_path = self.hold_job_path.with_name("session-journal.json")
        ejected = ack["action"] == "eject"
        session_journal: dict[str, Any] = {
            **_batch_session_provenance(
                self.hold_job_path,
                self.worker_sha256,
                calibration_session_id=self.calibration_session_id,
            ),
            "completed_slots": completed,
            "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
            "plan_sha256": CANONICAL_PLAN_SHA256,
            "recovery_required": "none",
            "reservation_acquired": True,
            "selected_slots": [item["slot"] for item in self._job["frames"]],
            "session_id": self._job["session_id"],
            "status": "ejected" if ejected else ("stopped" if ack["action"] == "stop" else "complete"),
            "unit_release_attempts": 1,
            "unit_released": True,
        }
        if ejected:
            # Mirrors worker.py's own _perform_vendor_eject evidence shape.
            session_journal["eject"] = {
                "eject_cdb_status": "0000000000000000",
                "eject_execute_status": "0000000000000000",
                "terminal_sense": "023a00",
                "wait_polls": 5,
                "stall_recoveries": 0,
            }
        session_journal_path.write_text(json.dumps(session_journal), encoding="utf-8")
        self._returncode = 0
        return 0

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        while self.poll() is None:
            pass
        return int(self._returncode)


def _held_spawner(
    spawn_calls: list[tuple[str, ...]],
    worker_sha256: str,
    *,
    children: list[FakeHeldBatchProcess] | None = None,
    journal_overrides: dict[str, Any] | None = None,
    held_after_batch_journal_overrides: dict[str, Any] | None = None,
):
    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> FakeHeldBatchProcess:
        del cwd, stdout, stderr
        spawn_calls.append(tuple(argv))
        hold_job_path = Path(_argument(argv, "--hold-job"))
        child = FakeHeldBatchProcess(
            output_path=Path(_argument(argv, "--output")),
            journal_path=Path(_argument(argv, "--journal")),
            hold_job_path=hold_job_path,
            hold_ack_path=hold_job_path.with_name("hold-ack.json"),
            worker_sha256=worker_sha256,
            journal_overrides=journal_overrides,
            held_after_batch_journal_overrides=held_after_batch_journal_overrides,
        )
        if children is not None:
            children.append(child)
        return child

    return spawn


def _held_adapter(
    tmp_path: Path,
    binding: Binding,
    spawn_calls: list[tuple[str, ...]],
    *,
    children: list[FakeHeldBatchProcess] | None = None,
    journal_overrides: dict[str, Any] | None = None,
    held_after_batch_journal_overrides: dict[str, Any] | None = None,
) -> capture.CaptureProcessAdapter:
    return capture.CaptureProcessAdapter(
        worker_path=binding.worker,
        expected_worker_sha256=binding.worker_sha256,
        manifest_path=binding.manifest,
        attempts_root=tmp_path / "attempts",
        batch_spawner=_held_spawner(
            spawn_calls,
            binding.worker_sha256,
            children=children,
            journal_overrides=journal_overrides,
            held_after_batch_journal_overrides=(
                held_after_batch_journal_overrides
            ),
        ),
        batch_poll_seconds=0,
    )


def test_begin_held_preview_never_releases(tmp_path: Path, binding: Binding) -> None:
    """(a) A held preview's own attempt journal must report the reservation
    is still held, never released -- run_attempt(PREVIEW)'s worker.py path
    always calls _release_unit; --preview-and-hold's must not."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)

    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    assert held.preview_attempt.outcome is capture.CaptureOutcome.COMPLETE
    assert held.preview_attempt.journal is not None
    assert held.preview_attempt.journal["status"] == "awaiting-hold-job"
    assert held.preview_attempt.journal["unit_released"] is False
    assert "--preview-and-hold" in held.preview_attempt.argv
    assert "--preview-only" not in held.preview_attempt.argv
    assert held.process.poll() is None
    assert len(spawn_calls) == 1
    assert held.usable is True


def test_resume_held_session_launches_no_new_worker_process(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(b) Resuming a held preview into scan_many's batch must not spawn a
    second worker process -- RESERVE_UNIT and command 64 only ever happen
    inside a freshly spawned child's own preamble walk, so "one spawn total"
    is this hardware-free suite's faithful proxy for "neither was repeated"."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    assert len(spawn_calls) == 1

    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    result = adapter.resume_held_session(
        held, request, frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE
    )

    assert len(spawn_calls) == 1, "resume must reuse the held child, not spawn another"
    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert result.session_journal["reservation_acquired"] is True
    assert result.session_journal["unit_released"] is True
    assert result.session_journal["unit_release_attempts"] == 1
    # Regression (2026-08-06 live failure): the resumed batch's session
    # journal must carry the calibration's reservation-wide identity, and
    # this package's own post-hoc validation (_load_and_validate_batch_
    # session_journal, reached only via a COMPLETE outcome above) must
    # accept it even though it genuinely differs from this round's own
    # session_id -- held.hold_session_id is independently minted per hold
    # round (see PreparedCaptureBatch's docstring), so a fixture where they
    # coincided would not actually exercise this.
    assert (
        result.session_journal["density_calibration_session_id"]
        == held.preview_attempt.journal["density_calibration_session_id"]
    )
    assert (
        result.session_journal["session_id"]
        != result.session_journal["density_calibration_session_id"]
    )


def test_cold_run_batch_session_argv_is_unchanged_by_held_preview_support(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(c) A batch prepared with no held preview involved at all must keep
    launching with exactly the pre-existing --batch-job argv shape -- no
    --hold-job, no --preview-and-hold -- proving begin_held_preview/
    resume_held_session are purely additive to the cold path."""

    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    prepared = adapter.prepare_batch_session(request)

    assert "--hold-job" not in prepared.argv
    assert "--preview-and-hold" not in prepared.argv
    assert _argument(prepared.argv, "--batch-job") == str(prepared.paths.job)
    assert _argument(prepared.argv, "--session-journal") == str(prepared.paths.session_journal)


def test_resume_held_session_after_child_death_raises_held_session_expired(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(d) If the held child is no longer running by the time a resume is
    attempted (auto-eject, crash, power cycle), resume_held_session must
    fail closed with HeldSessionExpired rather than assume the reservation
    is still good -- Roll._scan_many maps this to RefeedRequired."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    assert isinstance(held.process, FakeHeldBatchProcess)
    held.process.die(returncode=1)

    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    with pytest.raises(capture.HeldSessionExpired):
        adapter.resume_held_session(
            held, request, frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE
        )
    assert len(spawn_calls) == 1, "a dead held child must never trigger a fresh spawn either"


def test_release_held_session_publishes_exactly_one_release_decision(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(e) An explicit release must publish exactly one release decision
    and leave the child's own journal honestly reporting the release --
    mirroring the pinned worker's own _release_unit-is-sent-once contract."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    journal = adapter.release_held_session(held)

    assert journal["status"] == "complete"
    assert journal["capture_mode"] == "preview-and-hold"
    assert journal["hold_outcome"] == "released"
    assert journal["unit_released"] is True
    ack = json.loads(held.hold_ack_path.read_text(encoding="utf-8"))
    assert ack == {
        "action": "release",
        "hold_session_id": held.hold_session_id,
        "schema_version": 1,
    }
    # The exclusive-publish primitive underneath is the actual "exactly
    # once" guarantee (release_held_session itself is safely idempotent on
    # top of it, since a second call sees the child already exited and
    # skips republishing) -- calling it directly proves a second decision
    # for this session can never land.
    with pytest.raises(FileExistsError):
        adapter._publish_hold_ack(held, action="release")
    # release_held_session itself stays idempotent: a second call is a
    # harmless re-confirmation, not a second RELEASE_UNIT.
    assert adapter.release_held_session(held) == journal


def test_eject_held_session_publishes_exactly_one_eject_decision(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """The "operator saw the preview, wants out" case: eject_held_session
    is release_held_session's sibling, not a parameterization of it -- a
    different hold-ack action, a different terminal hold_outcome."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    journal = adapter.eject_held_session(held)

    assert journal["status"] == "complete"
    assert journal["capture_mode"] == "preview-and-hold"
    assert journal["hold_outcome"] == "ejected"
    assert journal["unit_released"] is True
    assert journal["eject"]["terminal_sense"] == "023a00"
    ack = json.loads(held.hold_ack_path.read_text(encoding="utf-8"))
    assert ack == {
        "action": "eject",
        "hold_session_id": held.hold_session_id,
        "schema_version": 1,
    }
    with pytest.raises(FileExistsError):
        adapter._publish_hold_ack(held, action="eject")
    # eject_held_session itself stays idempotent: a second call is a
    # harmless re-confirmation, not a second eject sequence.
    assert adapter.eject_held_session(held) == journal


def test_eject_held_session_surfaces_worker_recovery_diagnosis_on_failure(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """A suspected transport wedge (worker.EjectWedgeSuspected) exits the
    held child non-zero with recovery_required forced to the power-cycle
    string even though the defensive release still succeeded (see that
    exception's own docstring). eject_held_session must surface exactly
    that diagnosis in its raised message -- callers (Roll.eject()) match
    on it to translate into FeederParked, the same idiom this package
    already uses elsewhere for worker-diagnosis translation."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    @dataclass
    class _WedgedEjectProcess:
        hold_ack_path: Path
        journal_path: Path
        hold_session_id: str
        _returncode: int | None = field(default=None, init=False)

        def poll(self) -> int | None:
            if self._returncode is not None:
                return self._returncode
            if not self.hold_ack_path.exists():
                return None
            ack = json.loads(self.hold_ack_path.read_text(encoding="utf-8"))
            assert ack == {
                "action": "eject",
                "hold_session_id": self.hold_session_id,
                "schema_version": 1,
            }
            journal = json.loads(self.journal_path.read_text(encoding="utf-8"))
            journal.update(
                status="failed",
                capture_mode="preview-and-hold",
                error=(
                    "EjectWedgeSuspected: eject wait: no motion observed "
                    "within 36s of the eject command (sense stayed "
                    "000000); matches the documented "
                    "accepted-without-actuation wedge signature -- power "
                    "cycle required, do not retry"
                ),
                recovery_required="power-cycle scanner before another attempt",
                # The defensive release inside _cleanup_synchronized still
                # succeeded -- this is the exact combination the wedge
                # diagnosis must survive, not get masked by.
                unit_released=True,
            )
            self.journal_path.write_text(json.dumps(journal), encoding="utf-8")
            self._returncode = 1
            return 1

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            while self.poll() is None:
                pass
            return int(self._returncode)

    wedged_held = replace(
        held,
        process=_WedgedEjectProcess(
            hold_ack_path=held.hold_ack_path,
            journal_path=held.preview_attempt.paths.journal,
            hold_session_id=held.hold_session_id,
        ),
    )

    with pytest.raises(
        capture.CaptureProcessError,
        match="power-cycle scanner before another attempt",
    ):
        adapter.eject_held_session(wedged_held)


def test_resume_held_session_with_eject_frame_handler_marks_batch_result_ejected(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(c) task requirement: batch + eject_after ends with eject-then-
    release ordering pinned, at the level this hardware-free suite can
    prove it -- the worker's own byte-level ordering is pinned separately
    in test_worker.py. frame_handler returning EJECT (Roll.scan_many's
    eject_after on the last requested slot) must mark the returned
    CaptureBatchResult ejected -- distinct from, and mutually exclusive
    with, stopped -- and the session journal's status must say "ejected",
    not "complete" or "stopped"."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    result = adapter.resume_held_session(
        held, request, frame_handler=lambda _frame: capture.BatchAckAction.EJECT
    )

    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert result.ejected is True
    assert result.stopped is False
    assert result.session_journal["status"] == "ejected"
    assert result.session_journal["unit_released"] is True
    assert result.session_journal["eject"]["terminal_sense"] == "023a00"


def test_resume_held_session_with_continue_hold_returns_held_again(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """Multi-batch-per-feed, the core new contract: frame_handler
    returning CONTINUE_HOLD on a batch's terminal frame must not release
    -- the returned CaptureBatchResult carries a fresh held_again
    (mutually exclusive with stopped/ejected), and the session journal
    reports the reservation still held (unit_released False), never
    "complete"/"stopped"/"ejected"."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    result = adapter.resume_held_session(
        held, request, frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE_HOLD
    )

    assert len(spawn_calls) == 1, "held_again must reuse the same child, not spawn another"
    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert result.stopped is False
    assert result.ejected is False
    assert result.session_journal["status"] == "held"
    assert result.session_journal["unit_released"] is False
    assert result.held_again is not None
    assert result.held_again.usable is True
    assert result.held_again.process is held.process
    assert result.held_again.hold_session_id != held.hold_session_id
    assert result.held_again.hold_job_path != held.hold_job_path
    assert result.held_again.hold_ack_path != held.hold_ack_path
    assert result.held_again.directory == held.directory


@pytest.mark.parametrize(
    ("overrides", "match"),
    [
        ({"completed_slots": [99]}, "completed_slots"),
        ({"session_id": "another-round"}, "session_id"),
        ({"unit_released": True}, "still held"),
        ({"hold_resume": {"hold_session_id": "short"}}, "hold_resume"),
        # The identity invariants the release boundary has always checked
        # and this one, until now, did not -- a reservation handed back for
        # another round must prove the same things about itself.
        (
            {"density_calibration_session_id": "another-reservation"},
            "density_calibration_session_id",
        ),
        ({"plan_sha256": "0" * 64}, "plan_sha256"),
        ({"continuation_plan_sha256": "0" * 64}, "continuation_plan_sha256"),
        ({"capture_engine_sha256": "0" * 64}, "capture_engine_sha256"),
        ({"expected_usb_bus": 9}, "expected_usb_bus"),
        (
            {"manual_review_approval_sha256_by_slot": {"1": "0" * 64}},
            "manual_review_approval_sha256_by_slot",
        ),
    ],
    ids=[
        "completed-slots",
        "session-id",
        "already-released",
        "bad-rendezvous",
        "calibration-identity",
        "plan-sha256",
        "continuation-plan-sha256",
        "capture-engine-sha256",
        "usb-topology",
        "manual-approvals",
    ],
)
def test_refused_held_after_batch_journal_releases_the_child_instead_of_orphaning_it(
    tmp_path: Path,
    binding: Binding,
    overrides: dict[str, Any],
    match: str,
) -> None:
    """``_resolve_held_after_batch``'s refusals happen at exactly the moment
    ``begin_held_preview``'s do -- the child is alive, parked at a fresh
    hold-wait, holding the reservation -- and raise instead of returning the
    only handle that could release it. Without the release path this test
    pins, a refused CONTINUE_HOLD round left a live child sitting on the
    scanner until wait_for_hold_decision's own half-hour timeout, from a
    parent that had already given up on it.

    The last case is the one with no usable rendezvous to address the child
    with: the refusal must still propagate, and must say so rather than
    guess at a path.
    """

    spawn_calls: list[tuple[str, ...]] = []
    children: list[FakeHeldBatchProcess] = []
    adapter = _held_adapter(
        tmp_path,
        binding,
        spawn_calls,
        children=children,
        held_after_batch_journal_overrides=overrides,
    )
    held = adapter.begin_held_preview(
        capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW)
    )
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )

    with pytest.raises(capture.CaptureProcessError, match=match) as excinfo:
        adapter.resume_held_session(
            held,
            request,
            frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE_HOLD,
        )

    assert len(children) == 1
    child = children[0]
    assert len(spawn_calls) == 1, "a refusal must never trigger a fresh spawn"
    notes = getattr(excinfo.value, "__notes__", [])
    assert any("held preview child" in note for note in notes), (
        "the propagating refusal must record what happened to the child"
    )
    if overrides.get("hold_resume") is None:
        assert child.poll() is not None, (
            "the refused child must be reaped, not left holding the scanner"
        )
        assert child.events[-1] == "hold-ack-release", child.events
        assert any("exited 0" in note for note in notes), notes
    else:
        # No rendezvous to publish a decision at, so the child cannot be
        # unblocked -- and must therefore not be waited on either, or the
        # refusal would sit here for wait_for_hold_decision's own half-hour
        # timeout instead of reaching the caller.
        assert any("no usable hold rendezvous" in note for note in notes), notes
        assert any("left running rather than waited on" in note for note in notes), notes


def test_batch_result_density_accessors_survive_the_held_preview_port(
    tmp_path: Path,
) -> None:
    """``CaptureBatchResult.density_evidence``/``.density_ownership`` -- the
    batch-level accessors that enforce one shared reservation preview across
    every frame -- were re-parented onto ``_HeldPreviewLaunchFailed`` when
    the held-preview classes were inserted between the dataclass body and
    its properties. ``CaptureBatchResult`` silently lost both, and the
    exception gained two that can only ``AttributeError`` on ``self.frames``.

    Exercised in the resumed shape specifically, so the reservation's
    density source raster lives in the held attempt's directory rather than
    beside the frames -- the layout that has to reach these accessors
    through ``CaptureAttemptResult.density_source_path``.
    """

    assert not hasattr(capture._HeldPreviewLaunchFailed(1), "density_evidence")

    attempt_directory = tmp_path / "preview-held"
    attempt_directory.mkdir()
    source_path = attempt_directory / "capture-preview.bin"
    source_path.write_bytes(_density_source_fixture())

    calibration_session_id = "single-reservation-batch-accessors"
    job_path = attempt_directory / "hold-job.json"
    job_path.write_text(
        json.dumps(
            {
                "session_id": "round-two-token",
                "frames": [
                    {"slot": 4, "output": "frame-004/capture.bin"},
                    {"slot": 9, "output": "frame-009/capture.bin"},
                ],
                "reviewed_roll_fingerprint": {"binding_sha256": "2" * 64},
            }
        ),
        encoding="utf-8",
    )

    frames: list[capture.CaptureAttemptResult] = []
    evidence_receipt: dict[str, object] | None = None
    for index, slot in enumerate((4, 9), start=1):
        output = attempt_directory / f"frame-{slot:03d}" / "capture.bin"
        output.parent.mkdir()
        density, preview_sha, table_sha = _batch_density_frame_provenance(
            job_path,
            output=output,
            frame_index=index,
            selected_slot=slot,
            calibration_session_id=calibration_session_id,
            density_source_path=source_path,
        )
        if index == 1:
            evidence_receipt = density["nikon_density_evidence"]
        frames.append(
            capture.CaptureAttemptResult(
                outcome=capture.CaptureOutcome.COMPLETE,
                request=capture.CaptureRequest(capture.CaptureMode.FULL, slot, 0),
                paths=capture.AttemptPaths(
                    directory=output.parent,
                    output=output,
                    journal=output.parent / "journal.json",
                    plan=attempt_directory / "plan.jsonl",
                    manifest=attempt_directory / "manifest.json",
                    bootstrap_status=attempt_directory / "worker-bootstrap.json",
                    stdout=attempt_directory / "stdout.txt",
                    stderr=attempt_directory / "stderr.txt",
                ),
                argv=(),
                returncode=0,
                stdout="",
                stderr="",
                journal={
                    **density,
                    "batch_session": {
                        "frame_index": index,
                        "frame_total": 2,
                        "selected_slots": [4, 9],
                        "session_id": "round-two-token",
                    },
                    "density_calibration_session_id": calibration_session_id,
                    "live_frame_selection": {
                        "frame": slot,
                        "preview_sha256": preview_sha,
                        "table_sha256": table_sha,
                        "roll_identity": {
                            "reviewed_fingerprint_sha256": "2" * 64,
                            "fresh_fingerprint_sha256": "d" * 64,
                        },
                    },
                    "session_reservation_retained": True,
                },
                batch_session_id="round-two-token",
                batch_frame_index=index,
                batch_frame_total=2,
                batch_selected_slots=(4, 9),
                density_source_path=source_path,
            )
        )

    result = capture.CaptureBatchResult(
        outcome=capture.CaptureOutcome.COMPLETE,
        request=capture.CaptureBatchRequest(
            (
                capture.CaptureRequest(capture.CaptureMode.FULL, 4, 0),
                capture.CaptureRequest(capture.CaptureMode.FULL, 9, 0),
            ),
            reviewed_fingerprint=_reviewed_fingerprint(),
            expected_usb_bus=1,
            expected_usb_address=2,
        ),
        paths=_prepare_batch_paths_stub(attempt_directory, job_path),
        frames=tuple(frames),
        returncode=0,
        stopped=False,
        session_journal={"nikon_density_evidence": evidence_receipt},
        stdout="",
        stderr="",
    )

    evidence = result.density_evidence
    assert evidence is not None
    assert evidence.to_dict() == evidence_receipt
    ownership = result.density_ownership
    assert len(ownership) == 2
    assert {receipt.selected_slot for receipt in ownership} == {4, 9}
    assert len({receipt.transport_identity_sha256 for receipt in ownership}) == 1
    assert len({receipt.preview_identity_sha256 for receipt in ownership}) == 1


def _prepare_batch_paths_stub(directory: Path, job_path: Path) -> capture.BatchSessionPaths:
    return capture.BatchSessionPaths(
        directory=directory,
        job=job_path,
        first_plan=directory / "plan.jsonl",
        continuation_plan=directory / "continuation.json",
        manifest=directory / "manifest.json",
        bootstrap_status=directory / "worker-bootstrap.json",
        session_journal=directory / "session-journal.json",
        stdout=directory / "stdout.txt",
        stderr=directory / "stderr.txt",
    )


def test_resume_held_session_can_be_called_again_after_continue_hold(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(a) task requirement: a second resume_held_session() on the
    held_again from a first CONTINUE_HOLD batch resumes the very same
    child a second time -- still no new spawn -- and completes normally
    when its own terminal frame answers CONTINUE this time."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    first_request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    first = adapter.resume_held_session(
        held,
        first_request,
        frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE_HOLD,
    )
    assert first.held_again is not None

    second_request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 2, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    second = adapter.resume_held_session(
        first.held_again,
        second_request,
        frame_handler=lambda _frame: capture.BatchAckAction.CONTINUE,
    )

    assert len(spawn_calls) == 1, "the second resume must reuse the one held child"
    assert second.outcome is capture.CaptureOutcome.COMPLETE
    assert second.stopped is False
    assert second.ejected is False
    assert second.held_again is None
    assert second.session_journal["status"] == "complete"
    assert second.session_journal["unit_released"] is True
    assert second.session_journal["unit_release_attempts"] == 1
    assert second.session_journal["selected_slots"] == [2]
    assert second.session_journal["completed_slots"] == [2]


def test_three_resumes_then_eject_ends_with_one_eject_and_one_release(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(b) task requirement: three separate resumes on one held child --
    the first two ending with CONTINUE_HOLD, the third with EJECT -- must
    produce exactly one eject and one release, only on the third, with
    the reservation reported held (never released) after the first two."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    def request_for(slot: int) -> capture.CaptureBatchRequest:
        return capture.CaptureBatchRequest(
            (capture.CaptureRequest(capture.CaptureMode.FULL, slot, 0),),
            reviewed_fingerprint=_reviewed_fingerprint(),
            expected_usb_bus=1,
            expected_usb_address=2,
        )

    first = adapter.resume_held_session(
        held, request_for(1), frame_handler=lambda _f: capture.BatchAckAction.CONTINUE_HOLD
    )
    assert first.held_again is not None
    assert first.session_journal["unit_released"] is False

    second = adapter.resume_held_session(
        first.held_again,
        request_for(2),
        frame_handler=lambda _f: capture.BatchAckAction.CONTINUE_HOLD,
    )
    assert second.held_again is not None
    assert second.session_journal["unit_released"] is False

    third = adapter.resume_held_session(
        second.held_again,
        request_for(3),
        frame_handler=lambda _f: capture.BatchAckAction.EJECT,
    )

    assert len(spawn_calls) == 1, "all three resumes share the one held child"
    assert third.held_again is None
    assert third.ejected is True
    assert third.stopped is False
    assert third.session_journal["status"] == "ejected"
    assert third.session_journal["unit_released"] is True
    assert third.session_journal["unit_release_attempts"] == 1
    assert third.session_journal["eject"]["terminal_sense"] == "023a00"


def test_release_held_session_works_on_a_held_again_session(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(c) task requirement: release_held_session (Roll.release()'s own
    adapter call) works unmodified on a held_again session from a prior
    CONTINUE_HOLD batch, exactly like it already does on the original
    preview's own held session -- same validated receipt shape, read from
    the fresh per-round file this round's own hold_resume named, not the
    original (unrelated) preview attempt journal."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    result = adapter.resume_held_session(
        held, request, frame_handler=lambda _f: capture.BatchAckAction.CONTINUE_HOLD
    )
    held_again = result.held_again
    assert held_again is not None

    journal = adapter.release_held_session(held_again)

    assert journal["status"] == "complete"
    assert journal["capture_mode"] == "preview-and-hold"
    assert journal["hold_outcome"] == "released"
    assert journal["unit_released"] is True
    # release_held_session itself stays idempotent, exactly like the
    # original held session's own contract.
    assert adapter.release_held_session(held_again) == journal


def test_eject_held_session_works_on_a_held_again_session(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(c)/(f) task requirement: eject_held_session (Roll.eject() between
    batches) works unmodified on a held_again session too."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    result = adapter.resume_held_session(
        held, request, frame_handler=lambda _f: capture.BatchAckAction.CONTINUE_HOLD
    )
    held_again = result.held_again
    assert held_again is not None

    journal = adapter.eject_held_session(held_again)

    assert journal["status"] == "complete"
    assert journal["capture_mode"] == "preview-and-hold"
    assert journal["hold_outcome"] == "ejected"
    assert journal["unit_released"] is True
    assert journal["eject"]["terminal_sense"] == "023a00"


def test_resume_after_continue_hold_and_child_death_raises_held_session_expired(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(d) task requirement: if the held child dies between batches (auto-
    eject, crash, power cycle) after a CONTINUE_HOLD, the next
    resume_held_session on that held_again must fail closed with
    HeldSessionExpired -- the same contract the original preview's held
    session already has, now proven across a batch boundary too."""

    spawn_calls: list[tuple[str, ...]] = []
    adapter = _held_adapter(tmp_path, binding, spawn_calls)
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 1, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    result = adapter.resume_held_session(
        held, request, frame_handler=lambda _f: capture.BatchAckAction.CONTINUE_HOLD
    )
    held_again = result.held_again
    assert held_again is not None
    assert isinstance(held_again.process, FakeHeldBatchProcess)
    held_again.process.die(returncode=1)

    second_request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 2, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    with pytest.raises(capture.HeldSessionExpired):
        adapter.resume_held_session(
            held_again,
            second_request,
            frame_handler=lambda _f: capture.BatchAckAction.CONTINUE,
        )
    assert len(spawn_calls) == 1, "a dead held_again child must never trigger a fresh spawn"


def test_load_and_validate_batch_session_journal_accepts_ejected_status(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """A successfully ejected batch's own status must be "ejected", not
    "complete" -- proves _load_and_validate_batch_session_journal's
    expected_status computation, independent of the fuller resume flow
    above."""

    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    prepared = adapter.prepare_batch_session(request)
    handled = [SimpleNamespace(request=SimpleNamespace(selected_slot=17))]
    prepared.paths.session_journal.write_text(
        json.dumps(
            {
                **_batch_session_provenance(prepared.paths.job, binding.worker_sha256),
                "completed_slots": [17],
                "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
                "plan_sha256": CANONICAL_PLAN_SHA256,
                "recovery_required": "none",
                "reservation_acquired": True,
                "selected_slots": [17],
                "session_id": prepared.session_id,
                "status": "ejected",
                "unit_release_attempts": 1,
                "unit_released": True,
            }
        ),
        encoding="utf-8",
    )

    payload = adapter._load_and_validate_batch_session_journal(
        prepared,
        returncode=0,
        handled=handled,
        stopped=False,
        ejected=True,
    )

    assert payload["status"] == "ejected"


def test_load_and_validate_batch_session_journal_tolerates_wedge_after_clean_release_only_when_ejected(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """(d) task requirement: the exact dangerous combination this feature
    introduces -- unit_released=True (the defensive RELEASE_UNIT
    succeeded) alongside recovery_required=power-cycle (the transport
    itself may still be wedged) -- must be accepted ONLY when this batch
    actually requested an eject. For every other caller (ejected=False,
    every batch that existed before this feature), that exact combination
    must still fail closed as internally inconsistent, unchanged."""

    adapter = _adapter(tmp_path, binding, FakeRunner(binding.worker_sha256))
    request = capture.CaptureBatchRequest(
        (capture.CaptureRequest(capture.CaptureMode.FULL, 17, 0),),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
    )
    prepared = adapter.prepare_batch_session(request)
    handled = [SimpleNamespace(request=SimpleNamespace(selected_slot=17))]
    journal_payload = {
        **_batch_session_provenance(prepared.paths.job, binding.worker_sha256),
        "completed_slots": [17],
        "continuation_plan_sha256": CANONICAL_CONTINUATION_PLAN_SHA256,
        "plan_sha256": CANONICAL_PLAN_SHA256,
        "recovery_required": capture.POWER_CYCLE_RECOVERY,
        "reservation_acquired": True,
        "selected_slots": [17],
        "session_id": prepared.session_id,
        "status": "failed",
        "unit_release_attempts": 1,
        "unit_released": True,
    }
    prepared.paths.session_journal.write_text(json.dumps(journal_payload), encoding="utf-8")

    # ejected=True: this is the one caller allowed to see this exact
    # combination -- worker.py's own EjectWedgeSuspected override.
    payload = adapter._load_and_validate_batch_session_journal(
        prepared,
        returncode=1,
        handled=handled,
        stopped=False,
        ejected=True,
    )
    assert payload["recovery_required"] == capture.POWER_CYCLE_RECOVERY
    assert payload["unit_released"] is True

    # ejected=False: the exact same journal content must still be rejected
    # -- the relaxation must never widen to a batch that never asked to
    # eject in the first place.
    with pytest.raises(capture.CaptureProcessError, match="internally inconsistent"):
        adapter._load_and_validate_batch_session_journal(
            prepared,
            returncode=1,
            handled=handled,
            stopped=False,
            ejected=False,
        )


# ===========================================================================
# begin_held_preview refusing a child that already reached the hold boundary
#
# _wait_for_held_preview_ready validates four journal fields only after the
# child reports awaiting-hold-job -- i.e. while that child is alive, blocked
# in wait_for_hold_decision, and holding the scanner's reservation. Each
# refusal raises CaptureIntegrityError out of begin_held_preview, which
# returns no session at all, so no caller can ever be handed a handle to
# release that child with. Roll.preview()'s own orphan fix cannot reach this
# case for exactly that reason: it can only track a session that was
# returned. The release has to happen inside the adapter, before the raise
# leaves begin_held_preview.
# ===========================================================================


def test_bad_hold_session_id_releases_the_held_child_instead_of_orphaning_it(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """A malformed hold_session_id is the one refusal with no well-formed
    release decision available -- the parent cannot echo an id it just
    rejected as invalid. It must still publish the decision it has and reap
    the child: an unbound decision fails the worker's wait closed through
    the synchronized-cleanup path that releases the unit, whereas publishing
    nothing leaves the reservation held until wait_for_hold_decision's own
    half-hour timeout. Orphaning it was the defect."""

    spawn_calls: list[tuple[str, ...]] = []
    children: list[FakeHeldBatchProcess] = []
    adapter = _held_adapter(
        tmp_path,
        binding,
        spawn_calls,
        children=children,
        journal_overrides={"hold_session_id": "too-short"},
    )

    with pytest.raises(capture.CaptureIntegrityError, match="hold_session_id") as excinfo:
        adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    assert len(children) == 1
    child = children[0]
    assert child.poll() is not None, (
        "the refused child must be reaped, not left alive holding the "
        "scanner's reservation"
    )
    assert child.events == [
        "preview-hold-ready",
        "hold-ack-release",
        "hold-ack-refused",
    ], "the child must be told to release before the refusal propagates"
    ack = json.loads(child.hold_ack_path.read_text(encoding="utf-8"))
    assert ack == {
        "action": "release",
        "hold_session_id": "too-short",
        "schema_version": 1,
    }
    assert len(spawn_calls) == 1, "a refusal must never trigger a fresh spawn"
    assert any(
        "held preview child" in note for note in getattr(excinfo.value, "__notes__", [])
    ), "the propagating refusal must record what happened to the child"


@pytest.mark.parametrize(
    ("overrides", "match"),
    [
        ({"capture_mode": "preview"}, "capture_mode"),
        ({"output": "/not/this/attempt/preview.raw"}, "output path"),
        ({"plan_sha256": "0" * 64}, "canonical plan"),
    ],
    ids=["capture-mode", "output-path", "plan-sha256"],
)
def test_refused_held_preview_journal_cleanly_releases_the_held_child(
    tmp_path: Path,
    binding: Binding,
    overrides: dict[str, Any],
    match: str,
) -> None:
    """The other three refusals all happen after hold_session_id validated,
    so the still-valid id in the journal buys a properly bound release: the
    child takes the decision, releases the unit, and exits 0, exactly as an
    explicit release_held_session would have driven it. The refusal itself
    still propagates unchanged."""

    spawn_calls: list[tuple[str, ...]] = []
    children: list[FakeHeldBatchProcess] = []
    adapter = _held_adapter(
        tmp_path, binding, spawn_calls, children=children, journal_overrides=overrides
    )

    with pytest.raises(capture.CaptureIntegrityError, match=match):
        adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    assert len(children) == 1
    child = children[0]
    assert child.events == ["preview-hold-ready", "hold-ack-release"]
    assert child.poll() == 0
    journal = json.loads(child.journal_path.read_text(encoding="utf-8"))
    assert journal["hold_outcome"] == "released"
    assert journal["unit_released"] is True
    assert len(spawn_calls) == 1


def test_a_refused_held_preview_leaves_the_adapter_able_to_start_another(
    tmp_path: Path,
    binding: Binding,
) -> None:
    """The release happens under the same _attempt_lock begin_held_preview
    already holds, so a refusal must not deadlock or poison the adapter: a
    caller that catches CaptureIntegrityError and retries gets a normal
    held session, with the refused child already gone."""

    spawn_calls: list[tuple[str, ...]] = []
    children: list[FakeHeldBatchProcess] = []
    overrides: dict[str, Any] = {"hold_session_id": "too-short"}
    adapter = _held_adapter(
        tmp_path,
        binding,
        spawn_calls,
        children=children,
        journal_overrides=overrides,
    )

    with pytest.raises(capture.CaptureIntegrityError):
        adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))
    # The spawner holds this exact dict by reference, so emptying it is what
    # makes only the first child publish a bad journal.
    overrides.clear()
    held = adapter.begin_held_preview(capture.CaptureRequest(mode=capture.CaptureMode.PREVIEW))

    assert held.usable is True
    assert held.process.poll() is None
    assert children[0].poll() is not None, "the refused child stays reaped"
    assert len(spawn_calls) == 2
