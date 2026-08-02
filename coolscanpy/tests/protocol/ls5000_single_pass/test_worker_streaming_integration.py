"""Integration contracts for the LS-5000 fail-open streaming capture hook.

These tests drive the worker's real fine-read loops with the established
fake-USB harnesses (ported from ``test_worker.py``) and a recording streaming
session, proving:

* both the first-frame loop and the continuation-frame loop call the one shared
  ``_open_fine_stream_session`` / ``_submit_fine_stream_record`` /
  ``_finish_fine_stream`` helper, with ``finish`` bound to the complete raw
  output SHA-256;
* a synchronous decoder exception (or a raised ``finish``) never aborts or
  drain-stops a live scan -- raw capture completes unchanged;
* a wedged streaming consumer cannot block the worker; and
* the ``COOLSCANPY_CAPTURE_STREAMING`` kill switch disables streaming.

All fixtures are synthetic; no scanner is touched and no committed image is
produced.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from coolscanpy import _roll as roll_module
from coolscanpy.capture.single_pass_workflow import (
    SinglePassAttempt,
    SinglePassFinalizationResult,
    SinglePassSession,
)
from coolscanpy.protocol.ls5000_single_pass import worker as worker_module
from coolscanpy.protocol.ls5000_single_pass import streaming_sidecar as sidecar_module
from coolscanpy.protocol.ls5000_single_pass.streaming_sidecar import FineStreamSession
from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    ReviewedRollFingerprint,
)
from coolscanpy.protocol.ls5000_single_pass.continuation_plan import (
    load_canonical_continuation_plan,
)
from coolscanpy.protocol.ls5000_single_pass.plan import (
    CANONICAL_PLAN_SHA256,
    load_canonical_plan,
)
from coolscanpy.protocol.ls5000_single_pass.roll_index import (
    NativeFrameOrigin,
    TransportMapping,
    TransportRecord,
)
from coolscanpy.protocol.ls5000_single_pass.worker import (
    TransactionResult,
    _derive_index_geometry,
    apply_batch_boundary_offsets,
)


def _reviewed_fingerprint() -> ReviewedRollFingerprint:
    return ReviewedRollFingerprint(
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
        preview_shape=(6_104, 96, 3),
        frame_start_rows=tuple(100 + 143 * index for index in range(40)),
        frame_native_origins=tuple(6_000 + 6_000 * index for index in range(40)),
        frame_visual_hashes=tuple(f"{index:064x}" for index in range(40)),
        frame_visual_log_spans=(2.0,) * 40,
    )


def _density_calibration(session_id: str) -> worker_module.DensityCalibration:
    reads = [
        worker_module.decode_density_calibration_read(
            bytes.fromhex(f"28008c000{color}0300000a80"),
            bytes.fromhex(payload),
        )
        for color, payload in enumerate(
            (
                "8c20000000040000df1a",
                "8c20000000040000bba4",
                "8c200000000400007fab",
            ),
            start=1,
        )
    ]
    return worker_module.assemble_density_calibration(
        reads,
        session_id=session_id,
    )


def _records_and_mapping() -> tuple[tuple[TransportRecord, ...], TransportMapping]:
    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    origins = tuple(
        NativeFrameOrigin(
            frame=frame,
            boundary_index=frame - 1,
            boundary_output_row=row - 4,
            lookup_row=row,
            code=records[row].code,
            selector=records[row].selector,
            native_origin=records[row].native_origin,
            method="direct-gap-trailing-row",
            automatic=True,
            manual_review=False,
            review_reasons=(),
            affine_residual_rows=0.0,
        )
        for frame, row in enumerate(
            (100 + 143 * index for index in range(37)),
            start=1,
        )
    )
    return records, TransportMapping(6_000, 168.0, 42.0, 0.0, 0.0, origins)


def _synthetic_meter_observation() -> object:
    meter = worker_module.meter_module
    yy, xx = np.mgrid[0 : meter.METER_ROWS, 0 : meter.METER_WIDTH]
    field = 0.08 + 0.82 * (
        0.55 * xx / (meter.METER_WIDTH - 1)
        + 0.45 * yy / (meter.METER_ROWS - 1)
    )
    image = np.empty(
        (meter.METER_ROWS, meter.METER_WIDTH, 4),
        dtype=np.uint16,
    )
    for channel_index, peak in enumerate(
        (28_000, 31_000, 34_000, 29_000)
    ):
        image[:, :, channel_index] = np.round(
            900 + peak * field
        ).astype(np.uint16)
    return meter.observe_meter_pass(
        meter.DecodedMeterPass(
            image=image,
            row_tail=np.zeros(
                (meter.METER_ROWS, meter.METER_TAIL_SAMPLES),
                dtype=">u2",
            ),
        ),
        worker_module.DEFAULT_EXPOSURES,
    )


class RecordingStreamSession:
    """Stand-in FineStreamSession that records every hook invocation."""

    def __init__(
        self, log: dict, *, submit_raises: bool = False, finish_raises: bool = False
    ) -> None:
        self.log = log
        self.submit_raises = submit_raises
        self.finish_raises = finish_raises
        self.session_id = len(log["sessions"])
        log["sessions"].append(self)

    def submit(self, payload: bytes) -> None:
        if self.submit_raises:
            raise RuntimeError("synchronous decoder explosion")
        self.log["submit_calls"].append((self.session_id, bytes(payload)))

    def finish(self, *, raw_sha256: str, raw_bytes: int) -> dict:
        if self.finish_raises:
            raise RuntimeError("finish explosion")
        self.log["finish_calls"].append((self.session_id, raw_sha256, raw_bytes))
        return {"status": "ok"}

    def abort(self, reason: str) -> None:
        self.log["abort_calls"].append((self.session_id, reason))


def _new_log() -> dict:
    return {
        "sessions": [],
        "submit_calls": [],
        "finish_calls": [],
        "abort_calls": [],
    }


def _patch_continuation_common(
    monkeypatch: pytest.MonkeyPatch,
    plan: list[dict],
    *,
    fine_reads: int = 1,
    full_meter_payload: bool = False,
) -> dict:
    canonical_target = worker_module.validate_plan(plan)
    tiny_target = {
        **canonical_target,
        "repeat": fine_reads,
        "request_len": 1,
        "request_parts": [1],
    }
    monkeypatch.setattr(worker_module, "EXPECTED_FINE_READS", fine_reads)
    if not full_meter_payload:
        monkeypatch.setattr(worker_module, "METER_GROUP_BYTES", 5)
        monkeypatch.setattr(worker_module, "METER_CAPTURE_BYTES", 15)
    monkeypatch.setattr(worker_module, "validate_plan", lambda _plan: tiny_target)

    accepted_proposal = SimpleNamespace(
        accepted=True,
        proposed_exposures=dict(worker_module.DEFAULT_EXPOSURES),
        refusals=(),
        to_dict=lambda: {"accepted": True},
    )
    accepted_final = SimpleNamespace(
        accepted=True,
        final_exposures=dict(worker_module.DEFAULT_EXPOSURES),
        refusals=(),
        to_dict=lambda: {
            "accepted": True,
            "final_exposures_raw_10ns": dict(worker_module.DEFAULT_EXPOSURES),
            "steps": [
                {
                    "observation": {
                        "exposures_raw_10ns": dict(worker_module.DEFAULT_EXPOSURES)
                    }
                }
            ],
        },
    )
    monkeypatch.setattr(
        worker_module,
        "observe_meter_pass",
        lambda *_a, **_k: _synthetic_meter_observation(),
    )
    monkeypatch.setattr(
        worker_module, "propose_next_exposures", lambda *_a, **_k: accepted_proposal
    )
    monkeypatch.setattr(
        worker_module, "verify_final_convergence", lambda *_a, **_k: accepted_final
    )
    monkeypatch.setattr(
        worker_module, "_wait_post_scan_ready", lambda *_a, **_k: (1, 0)
    )
    return tiny_target


def _drive_continuation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    open_session,
    perform=None,
    fine_reads: int = 1,
    fail_fine_read_index: int | None = None,
    full_meter_payload: bool = False,
) -> tuple[dict, worker_module.BatchFrameSpec]:
    """Run one continuation frame with the fake-USB harness; return its journal."""

    records, mapping = _records_and_mapping()
    combined, _resolved = apply_batch_boundary_offsets(
        mapping, records, ((7, 9), (18, -11))
    )
    plan = load_canonical_plan()
    geometry = _derive_index_geometry(plan)
    selection = SimpleNamespace(
        frame=18,
        frame_count=len(combined.origins),
        geometry=geometry,
        mapping=combined,
        selected=combined.origins[17],
        requested_boundary_offset_rows=-11,
        applied_boundary_offset_rows=-11,
        diagnostics=lambda: {"frame": 18, "prevalidated": True},
    )
    root = tmp_path / "continuation"
    root.mkdir()
    second = worker_module.BatchFrameSpec(
        18,
        -11,
        root / "frame-018" / "capture.bin",
        root / "frame-018" / "journal.json",
        root / "frame-018" / "parent-ack.json",
    )
    first = worker_module.BatchFrameSpec(
        7,
        9,
        root / "frame-007" / "capture.bin",
        root / "frame-007" / "journal.json",
        root / "frame-007" / "parent-ack.json",
    )
    batch = worker_module.LiveBatchJob(
        "continuation-session",
        root,
        (first, second),
        _reviewed_fingerprint(),
        1,
        2,
        CANONICAL_PLAN_SHA256,
        worker_module.CANONICAL_CONTINUATION_PLAN_SHA256,
        "c" * 64,
    )
    _patch_continuation_common(
        monkeypatch,
        plan,
        fine_reads=fine_reads,
        full_meter_payload=full_meter_payload,
    )

    def ready(_ep_out, _ep_in, entries, **_kwargs):
        return 1, 0

    if perform is None:
        fine_read_index = 0

        def perform(_ep_out, _ep_in, entry, **_kwargs):
            nonlocal fine_read_index
            sequence = entry["seq"]
            if sequence == 607:
                if fine_read_index == fail_fine_read_index:
                    raise RuntimeError("forced continuation fine-read failure")
                fine_read_index += 1
            if sequence in (
                *worker_module.METER_GET_WINDOW_SEQUENCES,
                *worker_module.FINE_GET_WINDOW_SEQUENCES,
            ):
                payload = bytes.fromhex(entry["expected_data_in"])
            elif sequence in worker_module.METER_READ_SEQUENCES:
                payload = (
                    b"\x12\x34" * (entry["request_len"] // 2)
                    if full_meter_payload
                    else b"x"
                )
            elif sequence == 607:
                payload = b"x"
            else:
                payload = bytes.fromhex(entry.get("expected_data_in", ""))
            return TransactionResult(
                phase=entry.get("expected_phase", 1),
                payload=payload,
                status=bytes.fromhex(entry.get("expected_status", "00" * 8)),
                sense=entry.get("expected_sense", "000000"),
                stall_recoveries=0,
            )

    monkeypatch.setattr(worker_module, "_perform_ready_group", ready)
    monkeypatch.setattr(worker_module, "_perform_with_busy_retry", perform)
    monkeypatch.setattr(worker_module, "_open_fine_stream_session", open_session)
    density_evidence = SimpleNamespace(
        source_binding=SimpleNamespace(session_id=batch.session_id)
    )
    monkeypatch.setattr(
        worker_module,
        "_density_frame_ownership_receipt",
        lambda *_args, **_kwargs: {"fixture": "owned"},
    )

    journal = worker_module._run_live_continuation_frame(
        "out",
        "in",
        plan,
        tmp_path / "plan.jsonl",
        CANONICAL_PLAN_SHA256,
        load_canonical_continuation_plan(),
        worker_module.CANONICAL_CONTINUATION_PLAN_SHA256,
        second,
        selection,
        batch_job=batch,
        frame_index=2,
        lifecycle=worker_module.SessionLifecycle(),
        density_calibration=_density_calibration(batch.session_id),
        density_evidence=density_evidence,
        actual_usb_bus=1,
        actual_usb_address=2,
    )
    return journal, second


def test_continuation_loop_wires_hook_and_binds_finish_to_raw_sha(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _new_log()
    journal, second = _drive_continuation(
        tmp_path,
        monkeypatch,
        open_session=lambda *_a: RecordingStreamSession(log),
    )

    assert journal["status"] == "frame-complete"
    assert second.output.read_bytes() == b"x"
    # The continuation fine loop created a session, submitted its record, and
    # sealed it against the complete raw output SHA-256.
    assert len(log["sessions"]) == 1
    assert log["submit_calls"] == [(0, b"x")]
    assert log["finish_calls"] == [(0, hashlib.sha256(b"x").hexdigest(), 1)]


def test_continuation_meter_evidence_is_accepted_by_publication_consumer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    journal, second = _drive_continuation(
        tmp_path,
        monkeypatch,
        open_session=lambda *_a: None,
        full_meter_payload=True,
    )
    journal_payload = second.journal.read_bytes()
    attempt = SinglePassAttempt(
        session=SinglePassSession(root=tmp_path, session_id="continuation-consumer"),
        attempt_id=second.output.parent.name,
        directory=second.output.parent,
        stream_path=second.output,
        journal_path=second.journal,
        selected_slot=second.slot,
        worker_returncode=0,
        boundary_offset_rows=second.boundary_offset_rows,
    )
    finalization = SinglePassFinalizationResult(
        manifest_path=second.output.parent / "manifest.json",
        output_paths={},
        manifest={
            "sources": {
                "capture_journal": {
                    "path": second.journal.name,
                    "bytes": len(journal_payload),
                    "sha256": hashlib.sha256(journal_payload).hexdigest(),
                }
            },
            "exposure_evidence": {
                "accepted_contract": journal["meter_final_exposures"]
            },
        },
        resumed=False,
        scratch_deleted=False,
    )

    meter_rgbi, final_rgb = roll_module._read_exact_analyzer_source(
        attempt, finalization
    )

    assert meter_rgbi.shape == (425, 281, 4)
    assert int(meter_rgbi[0, 0, 0]) == 0x1234
    # The published final RGB is the commanded contract, which is now the
    # guarded nikon-parity authority (device-bound clamped), not the active
    # controller's solve.
    commanded = journal["active_exposure_authority"]["commanded_channels_raw_10ns"]
    assert final_rgb == (commanded["R"], commanded["G"], commanded["B"])
    assert final_rgb != (
        worker_module.DEFAULT_EXPOSURES["R"],
        worker_module.DEFAULT_EXPOSURES["G"],
        worker_module.DEFAULT_EXPOSURES["B"],
    )


def test_synchronous_decoder_exception_never_aborts_continuation_capture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    journal, second = _drive_continuation(
        tmp_path,
        monkeypatch,
        open_session=lambda *_a: RecordingStreamSession(_new_log(), submit_raises=True),
    )

    # Raw capture completes unchanged despite the decoder raising synchronously.
    assert journal["status"] == "frame-complete"
    assert journal["frame_complete"] is True
    assert second.output.read_bytes() == b"x"


def test_submit_exception_aborts_session_before_reference_is_dropped() -> None:
    log = _new_log()
    session = RecordingStreamSession(log, submit_raises=True)

    retained = worker_module._submit_fine_stream_record(session, b"record")

    assert retained is None
    assert log["abort_calls"] == [(0, "submit-exception")]


def test_continuation_read_failure_aborts_stream_and_preserves_original_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _new_log()

    with pytest.raises(RuntimeError, match="forced continuation fine-read failure"):
        _drive_continuation(
            tmp_path,
            monkeypatch,
            open_session=lambda *_a: RecordingStreamSession(log),
            fine_reads=2,
            fail_fine_read_index=1,
        )

    output = tmp_path / "continuation" / "frame-018" / "capture.bin"
    journal = json.loads(
        (tmp_path / "continuation" / "frame-018" / "journal.json").read_text(
            encoding="utf-8"
        )
    )
    assert output.read_bytes() == b"x"
    assert journal["status"] == "failed"
    assert journal["error"].startswith("RuntimeError: forced continuation")
    assert log["abort_calls"] == [(0, "capture-error:RuntimeError")]


def test_finish_exception_never_aborts_continuation_capture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    journal, second = _drive_continuation(
        tmp_path,
        monkeypatch,
        open_session=lambda *_a: RecordingStreamSession(_new_log(), finish_raises=True),
    )

    assert journal["status"] == "frame-complete"
    assert second.output.read_bytes() == b"x"


def test_worker_does_not_block_on_a_stuck_streaming_consumer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    block = threading.Event()

    class BlockingDecoder:
        def __init__(self, *, height, width, validate_padding=True, out=None) -> None:
            pass

        def push(self, _chunk) -> None:
            block.wait(timeout=10)

        def finish(self):
            raise ValueError("never reached")

    monkeypatch.setattr(sidecar_module, "StreamingFrameDecoder", BlockingDecoder)

    def open_session(output_path, _record_bytes, _read_count):
        return FineStreamSession(
            output_path, height=3, max_queue=1, finish_timeout_seconds=0.3
        )

    start = time.monotonic()
    journal, second = _drive_continuation(
        tmp_path, monkeypatch, open_session=open_session
    )
    elapsed = time.monotonic() - start
    block.set()

    assert elapsed < 5.0, "worker blocked on a wedged streaming consumer"
    assert journal["status"] == "frame-complete"
    assert second.output.read_bytes() == b"x"


def _drive_two_frame_batch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    open_session,
    fine_reads: int = 1,
    fail_first_fine_read_index: int | None = None,
) -> dict:
    records, base_mapping = _records_and_mapping()
    combined, resolved = apply_batch_boundary_offsets(
        base_mapping, records, ((7, 9), (18, -11))
    )
    geometry = SimpleNamespace(
        requested_resolution=97,
        native_resolution=4_000,
        pitch=41,
        native_width=3_946,
        native_height=250_278,
        width=96,
        height=len(worker_module.PREVIEW_READ_SEQUENCES),
        block_bytes=1,
        expected_stream_bytes=len(worker_module.PREVIEW_READ_SEQUENCES),
    )

    def selection_for(slot, offset, pair):
        base, selected, _rebase = pair
        return SimpleNamespace(
            frame=slot,
            frame_count=len(combined.origins),
            geometry=geometry,
            mapping=combined,
            base_selected=base,
            selected=selected,
            requested_boundary_offset_rows=offset,
            applied_boundary_offset_rows=offset,
            diagnostics=lambda: {"frame": slot, "prevalidated": True},
        )

    selections = (selection_for(7, 9, resolved[0]), selection_for(18, -11, resolved[1]))
    root = tmp_path / "both-loops-batch"
    root.mkdir()
    first = worker_module.BatchFrameSpec(
        7,
        9,
        root / "frame-007" / "capture.bin",
        root / "frame-007" / "journal.json",
        root / "frame-007" / "parent-ack.json",
    )
    second = worker_module.BatchFrameSpec(
        18,
        -11,
        root / "frame-018" / "capture.bin",
        root / "frame-018" / "journal.json",
        root / "frame-018" / "parent-ack.json",
    )
    first.output.parent.mkdir()
    batch = worker_module.LiveBatchJob(
        "both-loops-batch",
        root,
        (first, second),
        _reviewed_fingerprint(),
        1,
        2,
        CANONICAL_PLAN_SHA256,
        worker_module.CANONICAL_CONTINUATION_PLAN_SHA256,
        "c" * 64,
    )
    nonce = "both-loops-nonce"
    first.ack.write_text(
        json.dumps(
            {
                "ack_nonce": nonce,
                "action": "continue",
                "frame_index": 1,
                "schema_version": 1,
                "session_id": batch.session_id,
                "slot": first.slot,
            }
        ),
        encoding="utf-8",
    )

    startup = bytearray(10 + 40 * 8)
    startup[:4] = b"\x8f\0\0\0"
    startup[4:6] = (len(startup) - 6).to_bytes(2, "big")
    startup[6:8] = (len(startup) - 8).to_bytes(2, "big")
    startup[8] = 40
    header_8e = b"\0\x8e\0\0\0\x06"
    state = {"prevalidated": False}

    plan = load_canonical_plan()
    for sequence in worker_module.PREVIEW_READ_SEQUENCES:
        entry = plan[sequence - 1]
        entry["request_len"] = 1
        entry["request_parts"] = [1]

    ep_out = SimpleNamespace(bEndpointAddress=0x01)
    ep_in = SimpleNamespace(bEndpointAddress=0x82)
    interface = SimpleNamespace(bInterfaceNumber=0)

    class USBUtil:
        @staticmethod
        def release_interface(_device, _number):
            pass

        @staticmethod
        def dispose_resources(_device):
            pass

    def derive_batch(_plan, preview, table, frames, *, reviewed_fingerprint):
        state["prevalidated"] = True
        return selections

    fine_read_index = 0

    def perform(_ep_out, _ep_in, entry, **_kwargs):
        nonlocal fine_read_index
        sequence = entry["seq"]
        if sequence in (115, 116, 117):
            payload = b"window"
        elif sequence in worker_module.PREVIEW_READ_SEQUENCES:
            payload = b"p"
        elif sequence == 171:
            payload = header_8e
        elif sequence == 172:
            payload = header_8e
        elif sequence in (
            *worker_module.METER_GET_WINDOW_SEQUENCES,
            *worker_module.FINE_GET_WINDOW_SEQUENCES,
        ):
            payload = bytes.fromhex(entry["expected_data_in"])
        elif sequence in worker_module.METER_READ_SEQUENCES:
            payload = b"m"
        elif sequence == 607:
            if fine_read_index == fail_first_fine_read_index:
                raise RuntimeError("forced first-frame fine-read failure")
            fine_read_index += 1
            payload = b"f"
        else:
            payload = bytes.fromhex(entry.get("expected_data_in", ""))
        return TransactionResult(
            phase=entry.get("expected_phase", 1),
            payload=payload,
            status=bytes.fromhex(entry.get("expected_status", "00" * 8)),
            sense=entry.get("expected_sense", "000000"),
            stall_recoveries=0,
        )

    def perform_startup(_ep_out, _ep_in, entry, **_kwargs):
        return TransactionResult(3, bytes(startup), bytes(8), "000000", 0)

    def ready(_ep_out, _ep_in, entries, **_kwargs):
        return 1, 0

    real_wait_for_parent_ack = worker_module.wait_for_parent_ack

    def acknowledge(
        path,
        *,
        session_id,
        frame_index,
        slot,
        nonce,
        timeout_seconds=1_800.0,
        poll_seconds=0.1,
    ):
        del timeout_seconds, poll_seconds
        if frame_index == 2:
            path.write_text(
                json.dumps(
                    {
                        "ack_nonce": nonce,
                        "action": "continue",
                        "frame_index": frame_index,
                        "schema_version": 1,
                        "session_id": session_id,
                        "slot": slot,
                    }
                ),
                encoding="utf-8",
            )
        return real_wait_for_parent_ack(
            path,
            session_id=session_id,
            frame_index=frame_index,
            slot=slot,
            nonce=nonce,
            timeout_seconds=0,
            poll_seconds=0,
        )

    def release(_ep_out_value, _ep_in_value):
        return TransactionResult(1, b"", bytes(8), "000000", 0)

    preview_windows = [
        {
            "color_id": color,
            "resx": 97,
            "resy": 97,
            "upper_left_x": 0,
            "upper_left_y": 0,
            "width": 3_946,
            "height": 250_278,
            "bit_depth": 16,
            "exposure_raw_10ns": 70_000 + color,
        }
        for color in (1, 2, 3)
    ]
    _patch_continuation_common(monkeypatch, plan, fine_reads=fine_reads)
    monkeypatch.setattr(
        worker_module,
        "EXPECTED_PREVIEW_BYTES",
        len(worker_module.PREVIEW_READ_SEQUENCES),
    )
    monkeypatch.setattr(worker_module, "_derive_index_geometry", lambda _plan: geometry)
    monkeypatch.setattr(
        worker_module, "_validate_scanner_identity", lambda _payload: None
    )
    monkeypatch.setattr(
        worker_module, "_validate_live_preview_windows", lambda *_a: preview_windows
    )
    monkeypatch.setattr(
        worker_module,
        "_validate_preview_density_source_contract",
        lambda *_args: None,
    )
    monkeypatch.setattr(
        worker_module,
        "build_nikon_density_evidence",
        lambda *_args, **kwargs: SimpleNamespace(
            source_binding=SimpleNamespace(session_id=kwargs["session_id"]),
            preview_identity_sha256="d" * 64,
            to_dict=lambda: {"scope": "reservation-preview", "test_fixture": True},
        ),
    )
    monkeypatch.setattr(
        worker_module,
        "_density_frame_ownership_receipt",
        lambda *_args, **_kwargs: {"fixture": "owned"},
    )
    monkeypatch.setattr(worker_module, "_derive_live_batch_selections", derive_batch)
    monkeypatch.setattr(worker_module, "_perform_with_busy_retry", perform)
    monkeypatch.setattr(
        worker_module, "_perform_variable_frame_table_transaction", perform_startup
    )
    monkeypatch.setattr(worker_module, "_perform_ready_group", ready)
    monkeypatch.setattr(worker_module, "wait_for_parent_ack", acknowledge)
    monkeypatch.setattr(worker_module, "_release_unit", release)
    monkeypatch.setattr(worker_module.secrets, "token_hex", lambda _size: nonce)
    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        lambda **_kwargs: (
            SimpleNamespace(bus=1, address=2),
            interface,
            ep_out,
            ep_in,
            USBUtil,
        ),
    )
    monkeypatch.setattr(worker_module, "_open_fine_stream_session", open_session)

    session_journal_path = root / "session-journal.json"
    worker_module.run_live_capture(
        plan,
        tmp_path / "plan.jsonl",
        CANONICAL_PLAN_SHA256,
        first.output,
        first.journal,
        fine_reads,
        frame=first.slot,
        boundary_offset_rows=first.boundary_offset_rows,
        batch_job=batch,
        continuation_plan=load_canonical_continuation_plan(),
        continuation_plan_sha256=worker_module.CANONICAL_CONTINUATION_PLAN_SHA256,
        session_journal_path=session_journal_path,
    )
    return {
        "first": first,
        "second": second,
        "session_journal": json.loads(session_journal_path.read_text(encoding="utf-8")),
    }


def test_both_fine_loops_wire_the_shared_streaming_hook(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _new_log()
    result = _drive_two_frame_batch(
        tmp_path, monkeypatch, open_session=lambda *_a: RecordingStreamSession(log)
    )

    # Both frames captured; raw oracles are intact.
    assert result["first"].output.read_bytes() == b"f"
    assert result["second"].output.read_bytes() == b"f"
    assert result["session_journal"]["status"] == "complete"

    # One session per fine loop: frame 1 through the first-frame loop, frame 2
    # through the continuation-frame loop.
    assert len(log["sessions"]) == 2
    raw_sha = hashlib.sha256(b"f").hexdigest()
    assert log["submit_calls"] == [(0, b"f"), (1, b"f")]
    assert log["finish_calls"] == [(0, raw_sha, 1), (1, raw_sha, 1)]


def test_first_frame_read_failure_aborts_stream_and_preserves_original_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = _new_log()

    with pytest.raises(RuntimeError, match="forced first-frame fine-read failure"):
        _drive_two_frame_batch(
            tmp_path,
            monkeypatch,
            open_session=lambda *_a: RecordingStreamSession(log),
            fine_reads=2,
            fail_first_fine_read_index=1,
        )

    output = tmp_path / "both-loops-batch" / "frame-007" / "capture.bin"
    journal = json.loads(
        (tmp_path / "both-loops-batch" / "frame-007" / "journal.json").read_text(
            encoding="utf-8"
        )
    )
    assert output.read_bytes() == b"f"
    assert journal["status"] == "failed"
    assert journal["error"].startswith("RuntimeError: forced first-frame")
    assert log["abort_calls"] == [(0, "capture-error:RuntimeError")]


def test_streaming_kill_switch_and_geometry_gate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "capture.bin"
    # Abbreviated test geometry never engages streaming.
    assert worker_module._open_fine_stream_session(output, 1, 1) is None
    # Kill switch disables streaming even at full geometry.
    monkeypatch.setenv("COOLSCANPY_CAPTURE_STREAMING", "0")
    assert (
        worker_module._open_fine_stream_session(
            output,
            worker_module.EXPECTED_FINE_REQUEST,
            worker_module.EXPECTED_FINE_READS,
        )
        is None
    )
    # Full geometry with streaming enabled opens a real session.
    monkeypatch.setenv("COOLSCANPY_CAPTURE_STREAMING", "1")
    session = worker_module._open_fine_stream_session(
        output, worker_module.EXPECTED_FINE_REQUEST, worker_module.EXPECTED_FINE_READS
    )
    assert isinstance(session, FineStreamSession)
    assert session._consumer is not None
    session._consumer.disable("test-teardown")
