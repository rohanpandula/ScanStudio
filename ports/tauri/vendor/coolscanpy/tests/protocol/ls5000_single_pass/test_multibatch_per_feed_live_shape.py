"""One reservation, feed to eject, two batches -- the exact live shape.

This is the test whose absence cost four consecutive live attempts on
2026-08-06. Every other held-preview test in this suite drives the real
parent (``CaptureProcessAdapter``) against a *hand-written* child that
publishes journals and artifacts the way the real worker is believed to.
Four times in a row that belief was wrong in a way no fixture modelled --
where the density source raster is written, which capture-attempt id a
resumed frame claims, which journal fields survive a resume transition,
which frame carries the reservation's evidence receipt -- and each was found
by moving real film.

So this test runs the **real worker** as the child: ``worker.main(argv)`` on
a thread, driven by the same ``batch_spawner`` seam every other test uses,
with only the USB transport faked. The parent is the real
``CaptureProcessAdapter`` with every real validator; the preview half is the
real ``Roll.preview()`` over the real roll-index detector, real reviewed
fingerprint, real density calibration and real density evidence built from
real preview bytes.

Shape, reproducing driver11.log's own plan for the 2026-08-06 SA-30 roll:

    open -> preview-and-hold (36 exposures on a 40-slot addressable strip;
            slot 1 and slot 36 flagged, 37..40 the empty tail)
         -> scan_many(2..21,  20 slots)              [ack CONTINUE_HOLD]
         -> scan_many(22..35, 14 slots, eject_after) [ack EJECT]

-- the same split, the same excluded slots, and the same warnings that live
run produced ("slots flagged needs_approval/warnings: {1:
('start-broad-clear-region', 'broad-clear-region',
'transport-origin-inferred'), 36: ('end-broad-clear-region',)}").

The claim it proves, by counting wire transactions: one RESERVE_UNIT, one
command-64 frame-table transaction, one eject, one RELEASE_UNIT -- all at
the ends, none in between -- across 34 fine scans in two separate batches on
one physical feed.

What is faked, and why:

* the USB transport itself (``_perform_with_busy_retry`` and friends), the
  same seam ``test_worker.py`` has always used -- this suite is hardware
  free;
* the fine READ stream, shrunk to one 1-byte read per frame on *both* sides
  (the worker's plan target and the parent's canonical read constants), so
  35 frames cost bytes instead of 21 GB. Shrinking only one side would be a
  fixture lying about the contract, which is this file's whole subject, so
  both move together;
* the AE meter controller's own numerics (``observe_meter_pass``,
  ``propose_next_exposures``, ``verify_final_convergence``), which have
  their own dedicated tests and no bearing on reservation continuity.

Everything the four live failures touched is real: artifact paths, journal
contents, identity threading, the parent's frame and session-journal
validators, and every density binding.
"""

from __future__ import annotations

import json
import struct
import sys
import threading
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Sequence

import numpy as np
import pytest

from coolscanpy import Material
from coolscanpy._roll import Roll
from coolscanpy.protocol.ls5000_single_pass import capture_process as capture
from coolscanpy.protocol.ls5000_single_pass import roll_index
from coolscanpy.protocol.ls5000_single_pass import worker as worker_module
from coolscanpy.protocol.ls5000_single_pass.bundle import (
    CAPTURE_BUNDLE_SHA256,
    CAPTURE_WORKER_SHA256,
    canonical_manifest_bytes,
)
from coolscanpy.protocol.ls5000_single_pass.plan import load_canonical_plan


PREVIEW_HEIGHT = 6_104
# The strip carries 36 exposures; the scanner's canonical command-64 reply
# describes 40 addressable slots either way, so 37..40 come back as empty
# tail -- exactly what the live roll did.
EXPOSURE_COUNT = 36
ADDRESSABLE_SLOTS = 40
BATCH_ONE_SIZE = 20
BATCH_TWO_SIZE = 14


# --------------------------------------------------------------------------
# synthetic film: 36 exposures with a clear leader and a long clear tail --
# the same shape that made the live roll flag slot 1 and slot 36.
# --------------------------------------------------------------------------


def _synthetic_index() -> np.ndarray:
    """``EXPOSURE_COUNT`` textured cells separated by clear-film gaps.

    Adapted from tests/test_facade.py's own ``_synthetic_index`` (which
    lays out 40); the only change is the boundary count, so the strip ends
    in the broad clear region a 36-exposure roll really leaves -- the
    region that made the live run flag slot 36 and the empty tail.
    """

    pitch = 143
    leader = 128
    boundaries = [leader + index * pitch for index in range(EXPOSURE_COUNT + 1)]
    y = np.arange(PREVIEW_HEIGHT, dtype=np.int64)[:, None]
    x = np.arange(90, dtype=np.int64)[None, :]
    texture = (x * 173 + y * 71 + (x * y) % 997) % 7_000
    aperture = np.empty((PREVIEW_HEIGHT, 90, 3), dtype=np.int64)
    for channel, base in enumerate((7_000, 5_500, 4_000)):
        aperture[:, :, channel] = base + texture * (3 - channel) // 2
    clear_base = np.asarray((34_200, 25_500, 17_800), dtype=np.int64)
    clear_noise = ((x * 19 + y * 13) % 301 - 150)[:, :, None]
    aperture[: boundaries[0]] = clear_base + clear_noise[: boundaries[0]]
    aperture[boundaries[-1] :] = clear_base + clear_noise[boundaries[-1] :]
    for boundary in boundaries:
        aperture[boundary - 3 : boundary + 3] = (
            clear_base + clear_noise[boundary - 3 : boundary + 3]
        )
    rgb = np.empty((PREVIEW_HEIGHT, 96, 3), dtype=np.int64)
    rgb[:, 2:92] = aperture
    rgb[:, :2] = np.asarray((1_300, 1_000, 700))
    rgb[:, 92:] = np.asarray((1_100, 850, 600))
    return rgb.clip(0, 65_535).astype(np.uint16)


def _encode_index(rgb16: np.ndarray) -> bytes:
    """Pack a preview raster into the scanner's own 97-dpi wire blocks."""

    blocks = np.zeros(
        (rgb16.shape[0] // 2, roll_index.INDEX_BLOCK_WORDS), dtype=np.uint16
    )
    blocks[:, 0:96] = rgb16[0::2, :, 0]
    blocks[:, 96:192] = rgb16[0::2, :, 1]
    blocks[:, 192:288] = rgb16[0::2, :, 2]
    blocks[:, 512:608] = rgb16[1::2, :, 0]
    blocks[:, 608:704] = rgb16[1::2, :, 1]
    blocks[:, 704:800] = rgb16[1::2, :, 2]
    blocks[:, 800::2] = roll_index.INDEX_TRAILER_MARK
    blocks[:, 801::2] = np.arange(
        roll_index.INDEX_TRAILER_COUNTER0,
        roll_index.INDEX_TRAILER_COUNTER0 + roll_index.INDEX_TRAILER_WORDS // 2,
        dtype=np.uint16,
    )
    return blocks.astype(">u2", copy=False).tobytes()


def _transport_table(rows: int) -> bytes:
    records = bytearray()
    for row in range(rows):
        records.extend(struct.pack(">HH", 6 * (row % 18), row // 18))
    total = 8 + len(records)
    return b"\x00\x8e\x00\x00" + total.to_bytes(2, "big") + b"\x00\x00" + bytes(records)


def _canonical_startup_frame_table(count: int) -> bytes:
    """The real command-64 reply, retargeted to ``count`` records."""

    canonical = bytes.fromhex(
        load_canonical_plan()[worker_module.VARIABLE_FRAME_TABLE_SEQUENCE - 1][
            "expected_data_in"
        ]
    )
    length = 10 + count * 8
    return (
        canonical[:4]
        + (length - 6).to_bytes(2, "big")
        + (length - 8).to_bytes(2, "big")
        + bytes((count, 0))
        + canonical[10:length]
    )


# --------------------------------------------------------------------------
# the fake wire, and the real worker running behind it
# --------------------------------------------------------------------------


class _Wire:
    """Counts the transactions this test exists to count, and answers them."""

    def __init__(self, preview_bytes: bytes, table: bytes) -> None:
        self.preview_bytes = preview_bytes
        self.table = table
        self.startup_table = _canonical_startup_frame_table(40)
        self.reserves: list[int] = []
        self.frame_tables: list[int] = []
        self.fine_reads: list[int] = []
        self.releases: list[str] = []
        self.ejects: list[str] = []
        self._preview_offset = 0

    def perform(
        self,
        _ep_out: object,
        _ep_in: object,
        entry: dict,
        **_kwargs: object,
    ) -> worker_module.TransactionResult:
        sequence = entry["seq"]
        if sequence == 17:
            self.reserves.append(sequence)
        if sequence in worker_module.PREVIEW_READ_SEQUENCES:
            request = entry["request_len"]
            payload = self.preview_bytes[
                self._preview_offset : self._preview_offset + request
            ]
            self._preview_offset += request
        elif sequence in (171, 172):
            payload = self.table if sequence == 172 else self.table[:6]
        elif sequence in worker_module.METER_READ_SEQUENCES:
            # One byte per READ: five reads per group, three groups, which
            # is the shrunk METER_GROUP_BYTES/METER_CAPTURE_BYTES below.
            payload = b"m"
        elif sequence == 607:
            self.fine_reads.append(sequence)
            payload = b"f"
        else:
            payload = bytes.fromhex(entry.get("expected_data_in", ""))
        return worker_module.TransactionResult(
            phase=entry.get("expected_phase", 1),
            payload=payload,
            status=bytes.fromhex(entry.get("expected_status", "00" * 8)),
            sense=entry.get("expected_sense", "000000"),
            stall_recoveries=0,
        )

    def perform_startup(
        self,
        _ep_out: object,
        _ep_in: object,
        entry: dict,
        **_kwargs: object,
    ) -> worker_module.TransactionResult:
        assert entry["seq"] == worker_module.VARIABLE_FRAME_TABLE_SEQUENCE
        self.frame_tables.append(entry["seq"])
        return worker_module.TransactionResult(
            phase=3,
            payload=self.startup_table,
            status=bytes(8),
            sense="000000",
            stall_recoveries=0,
        )

    def release(self, _ep_out: object, _ep_in: object) -> worker_module.TransactionResult:
        self.releases.append("release")
        return worker_module.TransactionResult(1, b"", bytes(8), "000000", 0)

    def eject(self, _ep_out: object, _ep_in: object) -> dict[str, object]:
        self.ejects.append("eject")
        return {
            "eject_cdb_status": "0000000000000000",
            "eject_execute_status": "0000000000000000",
            "terminal_sense": worker_module.EJECT_TERMINAL_SENSE,
            "wait_polls": 5,
            "stall_recoveries": 0,
        }


class _RealWorkerChild:
    """``RunningBatchProcess`` over a real ``worker.main(argv)`` on a thread.

    The adapter only ever calls ``poll()``/``wait()`` and reads files, so a
    thread is a faithful stand-in for the subprocess: the parent/child
    rendezvous is entirely on-disk (journals, ack files, hold-job files) and
    is exercised exactly as it is against a real child.
    """

    def __init__(self, worker_argv: Sequence[str]) -> None:
        self.argv = tuple(worker_argv)
        self.error: BaseException | None = None
        self._returncode: int | None = None
        self._thread = threading.Thread(
            target=self._run, name="real-worker-child", daemon=True
        )
        self._thread.start()

    def _run(self) -> None:
        try:
            worker_module.main(list(self.argv))
        except BaseException as error:  # noqa: BLE001 - mirrors a child exit code
            self.error = error
            self._returncode = 1
        else:
            self._returncode = 0

    def poll(self) -> int | None:
        return self._returncode

    def wait(self, timeout: float | None = None) -> int:
        self._thread.join(timeout)
        if self._returncode is None:
            raise TimeoutError("real worker child did not exit")
        return self._returncode

    def terminate(self) -> None:
        """A thread cannot be signalled; the failed-preview teardown ladder
        treats an ignored terminate exactly like a wedged child, which is
        the honest stand-in behavior (this suite never exercises it -- a
        parked real worker takes the ladder's release decision first)."""

    def kill(self) -> None:
        """See terminate()."""


class _DeviceDouble:
    """The handful of private hooks ``Roll`` uses on its owning Device.

    ``Roll``'s own docstring sanctions direct construction for tests that
    inject an adapter; this supplies the locking/identity surface it reaches
    for, and nothing else.
    """

    def __init__(self) -> None:
        self._info = SimpleNamespace(id="coolscan3:usb:libusb:2:11")
        self.io_locks: list[str] = []

    def _acquire_io_lock(self, reason: str) -> None:
        self.io_locks.append(reason)

    def _release_io_lock(self) -> None:
        self.io_locks.pop()

    def _release_roll_lock(self) -> None:
        pass

    def _mark_fault_if_cleanup_error(self, error: BaseException) -> None:
        del error


def _install_fake_hardware(
    monkeypatch: pytest.MonkeyPatch,
    wire: _Wire,
) -> None:
    """Fake exactly the transport and the meter numerics, nothing else."""

    plan = load_canonical_plan()
    canonical_target = worker_module.validate_plan(plan)
    tiny_target = {
        **canonical_target,
        "repeat": 1,
        "request_len": 1,
        "request_parts": [1],
    }
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
        to_dict=lambda: {"accepted": True},
    )

    # One 1-byte fine READ per frame, on the worker side.
    monkeypatch.setattr(worker_module, "EXPECTED_FINE_READS", 1)
    monkeypatch.setattr(
        worker_module, "validate_plan", lambda _plan, *_manifest: tiny_target
    )
    # ... and the identical shrink on the parent side, so its own
    # frame-completion invariants describe the same capture. Faking only one
    # side is the failure mode this whole file is about.
    monkeypatch.setattr(capture, "CANONICAL_FINE_READ_COUNT", 1)
    monkeypatch.setattr(capture, "CANONICAL_FINE_READ_BYTES", 1)
    monkeypatch.setattr(worker_module, "METER_GROUP_BYTES", 5)
    monkeypatch.setattr(worker_module, "METER_CAPTURE_BYTES", 15)

    monkeypatch.setattr(
        worker_module,
        "_validate_scanner_identity",
        lambda _payload: "Nikon LS-5000 ED 2.07",
    )
    monkeypatch.setattr(
        worker_module, "_validate_live_preview_windows", lambda *_args: preview_windows
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
    monkeypatch.setattr(worker_module, "_perform_with_busy_retry", wire.perform)
    monkeypatch.setattr(
        worker_module,
        "_perform_variable_frame_table_transaction",
        wire.perform_startup,
    )
    monkeypatch.setattr(
        worker_module, "_perform_ready_group", lambda *_a, **_k: (1, 0)
    )
    monkeypatch.setattr(worker_module, "_wait_post_scan_ready", lambda *_a, **_k: (1, 0))
    monkeypatch.setattr(worker_module, "_release_unit", wire.release)
    monkeypatch.setattr(worker_module, "_perform_vendor_eject", wire.eject)
    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        lambda **_kwargs: (
            SimpleNamespace(bus=2, address=11),
            SimpleNamespace(bInterfaceNumber=0),
            SimpleNamespace(bEndpointAddress=0x01),
            SimpleNamespace(bEndpointAddress=0x82),
            SimpleNamespace(
                release_interface=lambda *_a: None,
                dispose_resources=lambda *_a: None,
            ),
        ),
    )


def _synthetic_meter_observation() -> object:
    meter = worker_module.meter_module
    yy, xx = np.mgrid[0 : meter.METER_ROWS, 0 : meter.METER_WIDTH]
    field = 0.08 + 0.82 * (
        0.55 * xx / (meter.METER_WIDTH - 1) + 0.45 * yy / (meter.METER_ROWS - 1)
    )
    image = np.empty((meter.METER_ROWS, meter.METER_WIDTH, 4), dtype=np.uint16)
    for channel_index, peak in enumerate((28_000, 31_000, 34_000, 29_000)):
        image[:, :, channel_index] = np.round(900 + peak * field).astype(np.uint16)
    return meter.observe_meter_pass(
        meter.DecodedMeterPass(
            image=image,
            row_tail=np.zeros((meter.METER_ROWS, meter.METER_TAIL_SAMPLES), dtype=">u2"),
        ),
        worker_module.DEFAULT_EXPOSURES,
    )


def _roll_ack(
    *,
    frame_slot: int,
    last_slot: int,
    eject_after: bool,
    resumed: bool,
) -> capture.BatchAckAction:
    """``Roll._scan_many``'s own terminal-ack rule, isolated.

    A batch that resumed a held reservation and was asked for neither a
    safe-stop nor an eject keeps the reservation held (CONTINUE_HOLD);
    ``eject_after`` ends the feed (EJECT); everything before the terminal
    slot is CONTINUE. Reproduced here rather than reached through
    ``Roll.scan_many`` because driving that requires a full decode/finalize
    of every frame -- 35 real 619 MB streams -- which is orthogonal to
    reservation continuity and already covered by tests/test_facade.py.
    """

    if frame_slot != last_slot:
        return capture.BatchAckAction.CONTINUE
    if eject_after:
        return capture.BatchAckAction.EJECT
    if resumed:
        return capture.BatchAckAction.CONTINUE_HOLD
    return capture.BatchAckAction.CONTINUE


def test_one_reservation_feed_to_eject_survives_two_batches(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    preview_raster = _synthetic_index()
    wire = _Wire(_encode_index(preview_raster), _transport_table(PREVIEW_HEIGHT))
    _install_fake_hardware(monkeypatch, wire)

    spawned: list[tuple[str, ...]] = []
    children: list[_RealWorkerChild] = []

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> _RealWorkerChild:
        del cwd, stdout, stderr
        spawned.append(tuple(argv))
        # argv[0] is the launcher (this interpreter); the worker's own
        # argument vector follows, and goes through the real main().
        child = _RealWorkerChild(argv[1:])
        children.append(child)
        return child

    attempts_root = tmp_path / "attempts"
    adapter = capture.CaptureProcessAdapter(
        worker_path=Path(worker_module.__file__).resolve(),
        expected_worker_sha256=CAPTURE_WORKER_SHA256,
        expected_bundle_sha256=CAPTURE_BUNDLE_SHA256,
        manifest_payload=canonical_manifest_bytes(),
        attempts_root=attempts_root,
        launcher=(sys.executable,),
        batch_spawner=spawn,
        batch_poll_seconds=0.005,
    )
    device = _DeviceDouble()
    roll = Roll(
        device,
        Material.COLOR_NEGATIVE,
        adapter=adapter,
        attempts_root=attempts_root,
    )

    # ---- preview-and-hold: the real Roll, the real detector -------------
    thumbnails = roll.preview()
    assert len(thumbnails) == ADDRESSABLE_SLOTS, [t.slot for t in thumbnails]
    flagged = {thumb.slot for thumb in thumbnails if thumb.needs_approval}
    warnings = {thumb.slot: thumb.warnings for thumb in thumbnails}
    # driver11.log's own reported flags, reproduced by the real detector.
    assert warnings[1] == (
        "start-broad-clear-region",
        "broad-clear-region",
        "transport-origin-inferred",
    )
    assert warnings[EXPOSURE_COUNT][0] == "end-broad-clear-region"
    assert flagged >= {1, EXPOSURE_COUNT}, (
        "the live roll flagged both edge slots (broad clear regions); a "
        "fixture that flags neither is not the shape under test"
    )
    assert len(spawned) == 1, "preview-and-hold spawns exactly one child"
    assert "--preview-and-hold" in spawned[0]

    held = roll._held_session
    assert held is not None and held.usable
    # The reservation's density source raster: written by the preview
    # traversal into the *attempt* directory, before any frame directory
    # existed, and never rewritten by any later round of this feed.
    source_path = held.reservation_density_source_path
    assert source_path.parent == held.directory
    assert source_path.is_file()
    assert source_path.stat().st_size == len(wire.preview_bytes)

    session = roll._session
    assert session is not None
    reviewed_fingerprint = session.reviewed_fingerprint()
    scannable = [
        slot for slot in range(1, ADDRESSABLE_SLOTS + 1) if slot not in flagged
    ]
    assert scannable == list(range(2, 36)), scannable
    assert len(scannable) == BATCH_ONE_SIZE + BATCH_TWO_SIZE
    batch_one = tuple(scannable[:BATCH_ONE_SIZE])
    batch_two = tuple(scannable[BATCH_ONE_SIZE:])
    assert batch_one == tuple(range(2, 22)) and batch_two == tuple(range(22, 36)), (
        "driver11.log's own split: batch1 2..21 (20), batch2 22..35 (14)"
    )

    def run_batch(
        slots: tuple[int, ...],
        held_session: capture.HeldPreviewSession,
        *,
        eject_after: bool,
    ) -> capture.CaptureBatchResult:
        request = capture.CaptureBatchRequest(
            frames=tuple(
                capture.CaptureRequest(
                    capture.CaptureMode.FULL,
                    slot,
                    session.slots[slot - 1].boundary_offset_rows,
                )
                for slot in slots
            ),
            reviewed_fingerprint=reviewed_fingerprint,
            expected_usb_bus=2,
            expected_usb_address=11,
        )
        seen: list[capture.CaptureAttemptResult] = []
        reservation_evidence: list[Any] = []

        def frame_handler(result: capture.CaptureAttemptResult):
            # Exactly the density contract Roll._scan_many's own frame
            # handler enforces, on exactly the same public accessors.
            evidence = result.density_evidence
            if evidence is not None:
                if reservation_evidence and evidence != reservation_evidence[0]:
                    raise AssertionError(
                        "batch attempts disagree on Nikon preview density evidence"
                    )
                reservation_evidence.append(evidence)
            assert reservation_evidence, "no reservation density evidence yet"
            ownership = result.density_ownership
            assert ownership is not None
            ownership.validate_evidence(reservation_evidence[0])
            assert ownership.frame_capture_attempt_id == result.paths.directory.name
            seen.append(result)
            return _roll_ack(
                frame_slot=result.request.selected_slot,
                last_slot=slots[-1],
                eject_after=eject_after,
                resumed=True,
            )

        result = adapter.resume_held_session(
            held_session, request, frame_handler=frame_handler
        )
        assert [item.request.selected_slot for item in seen] == list(slots)
        # One reservation, one density result -- proven per frame, from the
        # bytes on disk, by the real parent validator.
        assert len(reservation_evidence) == 1
        return result

    # ---- batch one: 20 slots, ends still holding ------------------------
    first = run_batch(batch_one, held, eject_after=False)
    assert first.outcome is capture.CaptureOutcome.COMPLETE
    assert first.stopped is False and first.ejected is False
    assert first.session_journal["status"] == "held"
    assert first.session_journal["unit_released"] is False
    assert first.held_again is not None
    assert first.held_again.process is held.process
    assert first.held_again.reservation_density_source_path == source_path
    assert len(spawned) == 1, "a resumed batch must never spawn a second child"
    assert wire.releases == [], "nothing may be released between batches"
    assert wire.ejects == []

    # ---- batch two: 15 slots, ends the feed ------------------------------
    second = run_batch(batch_two, first.held_again, eject_after=True)
    assert second.outcome is capture.CaptureOutcome.COMPLETE
    assert second.ejected is True
    assert second.held_again is None
    assert second.session_journal["status"] == "ejected"
    assert second.session_journal["unit_released"] is True
    assert second.session_journal["unit_release_attempts"] == 1
    assert second.session_journal["completed_slots"] == list(batch_two)

    # ---- the wire-level claim -------------------------------------------
    assert wire.reserves == [17], "exactly one RESERVE_UNIT for the whole feed"
    assert wire.frame_tables == [worker_module.VARIABLE_FRAME_TABLE_SEQUENCE], (
        "exactly one command-64 frame-table transaction for the whole feed"
    )
    assert len(wire.fine_reads) == BATCH_ONE_SIZE + BATCH_TWO_SIZE
    assert wire.ejects == ["eject"], "exactly one eject, at the very end"
    assert wire.releases == ["release"], "exactly one RELEASE_UNIT, at the very end"
    assert len(spawned) == 1, "one child owned the reservation from feed to eject"

    child = children[0]
    assert child.wait(timeout=30) == 0, child.error

    # ---- every frame's identity and evidence, across both batches -------
    calibration_session_id = held.preview_attempt.journal[
        "density_calibration_session_id"
    ]
    assert calibration_session_id.startswith("single-reservation-")
    # The reservation-wide calibration identity is NOT any round's own
    # session id -- confirm this run actually exercises that divergence.
    assert first.session_journal["session_id"] != calibration_session_id
    assert second.session_journal["session_id"] != calibration_session_id
    assert first.session_journal["session_id"] != second.session_journal["session_id"]
    assert (
        first.session_journal["density_calibration_session_id"]
        == calibration_session_id
    )
    assert (
        second.session_journal["density_calibration_session_id"]
        == calibration_session_id
    )

    for result in (*first.frames, *second.frames):
        journal = result.journal
        assert journal is not None
        slot = result.request.selected_slot
        assert journal["density_calibration_session_id"] == calibration_session_id
        ownership = journal["nikon_density_frame_ownership"]
        assert ownership["reservation_id"] == calibration_session_id
        assert ownership["batch_session_id"] == calibration_session_id
        assert ownership["frame_capture_attempt_id"] == f"frame-{slot:03d}"
        assert journal["session_reservation_retained"] is True
        assert journal["unit_released"] is False
        # Every frame publishes the revision this feed's own INQUIRY read,
        # never a hard-coded literal.
        assert journal["scanner_identity"] == "Nikon LS-5000 ED 2.07"
        assert journal["expected_usb_bus"] == 2
        assert journal["expected_usb_address"] == 11
        assert journal["actual_usb_bus"] == 2
        assert journal["actual_usb_address"] == 11
        # No frame directory holds a density source raster of its own: the
        # one this reservation owns lives in the attempt directory.
        assert not (result.paths.directory / "capture-preview.bin").exists()

    # Frame 1 of *each* batch carries the reservation's evidence receipt --
    # including batch two's, which is a continuation frame captured rounds
    # after the traversal that produced it.
    receipt = held.preview_attempt.journal["nikon_density_evidence"]
    for batch in (first, second):
        assert batch.frames[0].journal["nikon_density_evidence"] == receipt
        for later in batch.frames[1:]:
            assert "nikon_density_evidence" not in later.journal

    # The batch-level accessors agree with the session journal in both
    # shapes, over the real on-disk raster.
    for batch in (first, second):
        assert batch.density_evidence is not None
        assert batch.density_evidence.to_dict() == receipt
        assert len(batch.density_ownership) == len(batch.frames)

    roll.close()
    assert device.io_locks == []


def test_batch_frame_journals_are_accepted_by_the_real_session_validator(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The terminal release receipt, checked by the real parent validator.

    ``_load_and_validate_batch_session_journal`` is what refused live
    attempt 10 ("expected_usb_bus=None, expected 2"). Drive it against the
    session journal the real worker actually leaves after a resumed batch
    that ends the feed -- not a hand-written field list, which is the same
    failure mode one remove.
    """

    preview_raster = _synthetic_index()
    wire = _Wire(_encode_index(preview_raster), _transport_table(PREVIEW_HEIGHT))
    _install_fake_hardware(monkeypatch, wire)

    def spawn(
        argv: Sequence[str],
        *,
        cwd: Path,
        stdout: object,
        stderr: object,
    ) -> _RealWorkerChild:
        del cwd, stdout, stderr
        return _RealWorkerChild(argv[1:])

    attempts_root = tmp_path / "attempts"
    adapter = capture.CaptureProcessAdapter(
        worker_path=Path(worker_module.__file__).resolve(),
        expected_worker_sha256=CAPTURE_WORKER_SHA256,
        expected_bundle_sha256=CAPTURE_BUNDLE_SHA256,
        manifest_payload=canonical_manifest_bytes(),
        attempts_root=attempts_root,
        launcher=(sys.executable,),
        batch_spawner=spawn,
        batch_poll_seconds=0.005,
    )
    roll = Roll(
        _DeviceDouble(),
        Material.COLOR_NEGATIVE,
        adapter=adapter,
        attempts_root=attempts_root,
    )
    thumbnails = roll.preview()
    flagged = {thumb.slot for thumb in thumbnails if thumb.needs_approval}
    slots = tuple(
        slot for slot in range(1, ADDRESSABLE_SLOTS + 1) if slot not in flagged
    )[:2]
    session = roll._session
    held = roll._held_session
    assert held is not None

    request = capture.CaptureBatchRequest(
        frames=tuple(
            capture.CaptureRequest(
                capture.CaptureMode.FULL,
                slot,
                session.slots[slot - 1].boundary_offset_rows,
            )
            for slot in slots
        ),
        reviewed_fingerprint=session.reviewed_fingerprint(),
        expected_usb_bus=2,
        expected_usb_address=11,
    )
    result = adapter.resume_held_session(
        held,
        request,
        frame_handler=lambda frame: (
            capture.BatchAckAction.EJECT
            if frame.request.selected_slot == slots[-1]
            else capture.BatchAckAction.CONTINUE
        ),
    )
    assert result.outcome is capture.CaptureOutcome.COMPLETE
    assert result.ejected is True
    assert [frame.request.selected_slot for frame in result.frames] == list(slots)

    # Every field the real validator demands, straight off disk.
    journal = json.loads(
        (held.directory / "session-journal.json").read_text(encoding="utf-8")
    )
    assert journal["expected_usb_bus"] == 2
    assert journal["expected_usb_address"] == 11
    assert journal["continuation_plan_sha256"]
    assert journal["nikon_density_preview_identity"]["reservation_id"] == (
        journal["density_calibration_session_id"]
    )
    assert result.session_journal == journal
    roll.close()
