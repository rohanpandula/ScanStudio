"""Hardware-free contracts for the packaged LS-5000 capture worker."""

from __future__ import annotations

import errno
import hashlib
import json
import struct
import sys
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass import worker as worker_module
from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    ManualFrameApproval,
    ReviewedRollFingerprint,
    build_reviewed_roll_fingerprint,
)
from coolscanpy.protocol.ls5000_single_pass.roll_index import (
    NativeFrameOrigin,
    TransportMapping,
)
from coolscanpy.protocol.ls5000_single_pass.plan import (
    CANONICAL_PLAN_SHA256,
    load_canonical_plan,
)
from coolscanpy.protocol.ls5000_single_pass.continuation_plan import (
    load_canonical_continuation_plan,
)
from coolscanpy.protocol.ls5000_single_pass.worker import (
    DATA_PACKAGE,
    FRAME_TABLE_SEND_BYTES,
    FRAME_TABLE_SEND_RECORDS,
    ProtocolError,
    TransactionResult,
    _cleanup_synchronized,
    _bind_plan_to_live_selection,
    _derive_index_geometry,
    compile_continuation_steps,
    load_validated_batch_job,
    main,
    wait_for_parent_ack,
    _meter_controller_sha256,
    apply_boundary_offset,
    apply_batch_boundary_offsets,
    build_live_frame_table_payload,
)
from importlib.resources import files
from coolscanpy.protocol.ls5000_single_pass.roll_index import TransportRecord
from coolscanpy.protocol.ls5000_single_pass.window import decode_window_block


LIVE8_TRANSPORT_FIELDS = (
    (6202, 8, 22),
    (12250, 16, 22),
    (18326, 24, 26),
    (24360, 32, 24),
    (30436, 40, 28),
    (36484, 48, 28),
    (42532, 56, 28),
    (48608, 64, 32),
    (54614, 72, 26),
    (60676, 80, 28),
    (66710, 88, 26),
    (72758, 96, 26),
    (78778, 104, 22),
    (84896, 112, 32),
    (90916, 120, 28),
    (96992, 128, 32),
    (103026, 136, 30),
    (109046, 144, 26),
    (115136, 152, 32),
    (121156, 160, 28),
    (127176, 168, 24),
    (133280, 176, 32),
    (139286, 184, 26),
    (145362, 192, 30),
    (151396, 200, 28),
    (157416, 208, 24),
    (163464, 216, 24),
    (169526, 224, 26),
    (175560, 232, 24),
    (181636, 240, 28),
    (187684, 248, 28),
    (193746, 256, 30),
    (199794, 264, 30),
    (205842, 272, 30),
    (211904, 280, 32),
    (217924, 288, 28),
    (223958, 296, 260),
)

LIVE37_STARTUP_FRAME_TABLE_HEX = (
    "8f000000012c012a25000000039c0001001800001b4a0009001a000032f80011001c"
    "00004a980019001c000062380021001c000079a0002900140000915c003100180000"
    "a90a0039001a0000c0aa0041001a0000d84a0049001a0000efea0051001a000107"
    "440059001000011f2a0061001a000136ca0069001a00014e6a0071001a000165fc"
    "0079001800017db80081001c0001954a0089001a0001acea0091001a0001c47c0099"
    "01020001dc3800a1001c0001f3bc00a9001800020b4000b10014000222ee00b90016"
    "00023ab800c1001c0002523c00c90018000269c000d100140002816e00d900160002"
    "992a00e1001a0002b0ca00e9001a0002c85c00f100180002dfe000f900140002f78e"
    "0101001600030f3c01090102000326ea0111001a00033e7c01190018000356460121"
    "001e"
)
# Live 2026-07-31 matched-pair session after three Nikon Scan captures.  The
# scanner retained the same 37-frame capacity but represented the two film
# edges differently: the first boundary is selector 0, the second is selector
# 10, interior boundaries keep the normal +8 cadence, and the terminal record
# lands on the canonical final selector 289.  Every record independently
# satisfies Nikon's transport-coordinate identity.
LIVE37_EDGE_ADJUSTED_STARTUP_FRAME_TABLE_HEX = (
    "8f000000012c012a2500000000540000000c00001e06000a0012000035ec0012001c"
    "00004d62001a0016000065100022001800007ccc002a001c0000947a0032001e0000"
    "ac1a003a001e0000c3ac0042001c0000db5a004a001e0000f2ec0052001c00010a"
    "70005a00180001222c0062001c000139be006a001a0001517a0072001e000168f0"
    "007a0018000180820082001600019868008a00200001afde0092001a0001c79a009a"
    "001e0001df3a00a2001e0001f6da00aa001e00020e7a00b2001e0002261a00ba001e"
    "00023d9e00c2001a0002554c00ca001c00026cec00d2001c000284a800da00200002"
    "9c4800e200200002b3da00ea001e0002cb8800f200200002e31a00fa001e0002faba"
    "0102001e00031222010a0016000329ec0112001c00034170011a0018000358680121"
    "032a"
)
# Live 2026-07-31 ScanStudio restart after a completed fine capture of frame
# 12.  The scanner retained the same edge-adjusted full-roll table, but its
# first selector advanced from 0 to 2.  All 37 records independently satisfy
# Nikon's transport-coordinate identity and remain strictly ordered/in-bounds.
LIVE37_POST_FINE_SELECTOR2_STARTUP_FRAME_TABLE_HEX = (
    "8f000000012c012a2500000006ac0002001c00001e4c000a001c000035d000120018"
    "00004d7e001a001a0000653a0022001e00007ccc002a001c0000946c0032001c0000"
    "abfe003a001a0000c3ac0042001c0000db3e004a001a0000f3080052002000010a"
    "70005a00180001222c0062001c000139b0006a00180001516c0072001c0001690c"
    "007a001c000180820082001600019830008a00180001afde0092001a0001c77e009a"
    "001a0001df3a00a2001e0001f6da00aa001e00020e6c00b2001c000225f000ba0018"
    "00023d8200c200160002557600ca002200026cde00d2001a0002849a00da001e0002"
    "9c1e00e2001a0002b3da00ea001e0002cb7a00f2001e0002e30c00fa001c0002fa9e"
    "0102001a00031222010a0016000329de0112001a0003417e011a001a000356460121"
    "001e"
)
LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX = (
    "8f0000000034003206000000000000000000000017470008000000002e8e0010"
    "0000000045d50018000000005d1c002000000000746300280000"
)
# Three independent live observations of the parked-forward startup table:
# after capture activity the scanner's six-slot window slides (the from-zero
# record is gone, selectors start at 0x08) and the final record is a
# film-end terminal whose selector advances by ONE instead of eight. Every
# record — terminal included — satisfies the exact transport-coordinate
# identity; the film-end origin 31,206 is stable across all three sessions
# while the measured frame boundaries drift with re-registration.
LIVE6_PARKED_FORWARD_TERMINAL_TABLE_HEXES = (
    # 2026-07-28 03:24 fine-capture startup (batch-slot05 roh4gd65, failed)
    "8f000000003400320600000018640008001c00002fe80010001800004"
    "7b20018001e00005f520020001e000076e40028001c000079e60029001e",
    # 2026-07-30 14:04 preview startup (preview-pk0cv8qv, failed)
    "8f0000000034003206000000183a0008001600002fda001000160000473400"
    "18000c00005f1a00200016000076ba00280016000079e60029001e",
    # 2026-07-30 23:14 preview startup (preview-owwur7z9, failed)
    "8f0000000034003206000000182c0008001400002fda001000160000475000"
    "18001000005f360020001a0000769e00280012000079e60029001e",
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


def _reviewed_fingerprint_with_count(count: int) -> ReviewedRollFingerprint:
    """A reviewed fingerprint describing exactly ``count`` signed slots."""

    return ReviewedRollFingerprint(
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
        preview_shape=(6_104, 96, 3),
        frame_start_rows=tuple(100 + 143 * index for index in range(count)),
        frame_native_origins=tuple(6_000 + 6_000 * index for index in range(count)),
        frame_visual_hashes=tuple(f"{index:064x}" for index in range(count)),
        frame_visual_log_spans=(2.0,) * count,
    )


def _startup_frame_table(count: int) -> bytes:
    length = 10 + count * 8
    return (
        b"\x8f\x00\x00\x00"
        + (length - 6).to_bytes(2, "big")
        + (length - 8).to_bytes(2, "big")
        + bytes((count, 0))
        + bytes(count * 8)
    )


def _canonical_startup_frame_table(count: int) -> bytes:
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


def test_test_unit_ready_absolute_deadline_caps_every_usb_stage(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Clock:
        now = 10.0

        def monotonic(self) -> float:
            return self.now

        def advance(self) -> None:
            self.now += 0.125

    clock = Clock()
    events: list[tuple[str, bytes | int, int]] = []

    class OutEndpoint:
        def write(self, payload: bytes, *, timeout: int) -> int:
            events.append(("write", bytes(payload), timeout))
            clock.advance()
            return len(payload)

    class InEndpoint:
        phase_attempts = 0

        def read(self, size: int, *, timeout: int) -> bytes:
            events.append(("read", size, timeout))
            clock.advance()
            if size == 1:
                self.phase_attempts += 1
                if self.phase_attempts == 1:
                    error = OSError(errno.EPIPE, "counted zero-byte PIPE")
                    error.transferred = 0  # type: ignore[attr-defined]
                    raise error
                return b"\x01"
            assert size == 8
            return bytes(8)

        def clear_halt(self) -> None:
            events.append(("clear_halt", 0, 0))

    monkeypatch.setattr(worker_module.time, "monotonic", clock.monotonic)

    result = worker_module.perform_transaction(
        OutEndpoint(),
        InEndpoint(),
        {"seq": "deadline-test", "name": "TEST_UNIT_READY", "cdb": "00" * 6},
        data_timeout_ms=5_000,
        deadline_monotonic=12.0,
    )

    assert result.phase == 0x01
    assert result.stall_recoveries == 1
    assert events == [
        ("write", bytes(6), 2_000),
        ("write", b"\xd0", 1_875),
        ("read", 1, 1_750),
        ("clear_halt", 0, 0),
        ("read", 1, 1_625),
        ("write", b"\x06", 1_500),
        ("read", 8, 1_375),
    ]


def test_expired_transaction_deadline_performs_no_endpoint_io(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Endpoint:
        calls = 0

        def write(self, payload: bytes, *, timeout: int) -> int:
            self.calls += 1
            raise AssertionError((payload, timeout))

        def read(self, size: int, *, timeout: int) -> bytes:
            self.calls += 1
            raise AssertionError((size, timeout))

    ep_out = Endpoint()
    ep_in = Endpoint()
    monkeypatch.setattr(worker_module.time, "monotonic", lambda: 12.0)

    with pytest.raises(TimeoutError, match="transaction deadline expired"):
        worker_module.perform_transaction(
            ep_out,
            ep_in,
            {"seq": "expired-test", "name": "TEST_UNIT_READY", "cdb": "00" * 6},
            data_timeout_ms=5_000,
            deadline_monotonic=12.0,
        )

    assert ep_out.calls == 0
    assert ep_in.calls == 0


@pytest.mark.parametrize(
    "sequences",
    worker_module.PREVIEW_READY_CONFIRMATION_GROUPS,
)
def test_preview_ready_confirmation_groups_replay_every_observed_tur(
    monkeypatch: pytest.MonkeyPatch,
    sequences: tuple[int, ...],
) -> None:
    calls: list[int] = []
    sleeps: list[float] = []

    def ready(_ep_out, _ep_in, entry, *, data_timeout_ms):
        assert data_timeout_ms == 30_000
        calls.append(entry["seq"])
        return TransactionResult(
            phase=0x01,
            payload=b"",
            status=bytes(8),
            sense="000000",
            stall_recoveries=0,
        )

    monkeypatch.setattr(worker_module, "perform_transaction", ready)
    monkeypatch.setattr(worker_module.time, "sleep", sleeps.append)
    plan = load_canonical_plan()
    entries = [plan[sequence - 1] for sequence in sequences]

    polls, stalls = worker_module._perform_ready_group(
        object(),
        object(),
        entries,
    )

    assert polls == len(sequences)
    assert stalls == 0
    assert calls == [sequences[-1]] * len(sequences)
    assert sleeps == list(
        worker_module.PREVIEW_READY_CONFIRMATION_DELAYS_SECONDS[sequences]
    )


def test_other_ready_groups_still_collapse_at_the_terminal_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[int] = []

    def ready(_ep_out, _ep_in, entry, *, data_timeout_ms):
        assert data_timeout_ms == 30_000
        calls.append(entry["seq"])
        return TransactionResult(
            phase=0x01,
            payload=b"",
            status=bytes(8),
            sense="000000",
            stall_recoveries=0,
        )

    monkeypatch.setattr(worker_module, "perform_transaction", ready)
    plan = load_canonical_plan()
    entries = [plan[sequence - 1] for sequence in (79, 80)]
    for sequence, entry in zip((179, 180), entries, strict=True):
        entry = dict(entry)
        entry["seq"] = sequence
        entries[sequence - 179] = entry

    polls, stalls = worker_module._perform_ready_group(
        object(),
        object(),
        entries,
    )

    assert (polls, stalls) == (1, 0)
    assert calls == [180]


def test_startup_frame_table_accepts_complete_short_payload_underrun(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = _startup_frame_table(36)
    reads = iter(
        (
            (b"\x03", 0),
            (payload, 0),
            (worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS, 0),
        )
    )
    writes: list[bytes] = []
    monkeypatch.setattr(
        worker_module,
        "_read_with_one_stall_recovery",
        lambda *_args, **_kwargs: next(reads),
    )
    monkeypatch.setattr(
        worker_module,
        "_write_exact",
        lambda _endpoint, data, _timeout: writes.append(data),
    )
    entry = load_canonical_plan()[worker_module.VARIABLE_FRAME_TABLE_SEQUENCE - 1]

    result = worker_module._perform_variable_frame_table_transaction(
        object(),
        object(),
        entry,
        data_timeout_ms=30_000,
    )

    assert result.payload == payload
    assert result.status == worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS
    assert writes == [
        bytes.fromhex(worker_module.VARIABLE_FRAME_TABLE_CDB),
        b"\xd0",
        b"\x06",
    ]


def test_preview_binds_37_record_canonical_prefix_before_set_window() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = _canonical_startup_frame_table(37)

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        canonical_geometry,
    )

    assert binding.mode == "canonical-prefix-37-record"
    assert binding.active_read_sequences == tuple(range(118, 163))
    assert binding.skipped_read_sequences == (163, 164, 165)
    assert binding.geometry.native_height == 232_401
    assert binding.geometry.height == 5_668
    assert binding.geometry.expected_stream_bytes == 5_804_032
    assert worker_module._derive_index_geometry(plan) == binding.geometry
    for sequence in worker_module.PREVIEW_SET_WINDOW_SEQUENCES:
        window = decode_window_block(bytes.fromhex(plan[sequence - 1]["data_out"]))
        assert window is not None
        assert window["height"] == 232_401
    for sequence in worker_module.PREVIEW_GET_WINDOW_SEQUENCES:
        window = decode_window_block(
            bytes.fromhex(plan[sequence - 1]["expected_data_in"])
        )
        assert window is not None
        assert window["height"] == 232_401
    assert plan[161]["cdb"] == "28000000000000900080"
    assert plan[161]["request_len"] == 36_864
    assert plan[161]["drains_scan"] is True
    assert [plan[index - 1]["request_len"] for index in (163, 164, 165)] == [
        0,
        0,
        0,
    ]


def test_preview_binds_live_37_record_transport_table_before_set_window() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        bytes.fromhex(LIVE37_STARTUP_FRAME_TABLE_HEX),
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        canonical_geometry,
    )

    assert binding.mode == "canonical-prefix-37-record"
    assert binding.startup_records == 37
    assert binding.geometry.native_height == 232_401
    assert binding.geometry.expected_stream_bytes == 5_804_032


def test_preview_binds_live_37_record_edge_adjusted_transport_table() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        bytes.fromhex(LIVE37_EDGE_ADJUSTED_STARTUP_FRAME_TABLE_HEX),
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        canonical_geometry,
    )

    assert binding.mode == "canonical-prefix-37-record"
    assert binding.startup_records == 37
    assert binding.geometry.native_height == 232_401
    assert binding.geometry.expected_stream_bytes == 5_804_032


def test_preview_binds_live_37_record_post_fine_selector2_transport_table() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        bytes.fromhex(LIVE37_POST_FINE_SELECTOR2_STARTUP_FRAME_TABLE_HEX),
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        canonical_geometry,
    )

    assert binding.mode == "canonical-prefix-37-record"
    assert binding.startup_records == 37
    assert binding.geometry.native_height == 232_401
    assert binding.geometry.expected_stream_bytes == 5_804_032


@pytest.mark.parametrize(
    "payload_hex",
    LIVE6_PARKED_FORWARD_TERMINAL_TABLE_HEXES,
    ids=["fine-20260728", "preview-20260730-1404", "preview-20260730-2314"],
)
def test_preview_binds_live_parked_forward_table_with_terminal_record(
    payload_hex: str,
) -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        bytes.fromhex(payload_hex),
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        canonical_geometry,
    )

    assert binding.mode == "scanner-derived-6-record"
    assert binding.startup_records == 6


def _parked_forward_records() -> list[tuple[int, int, int]]:
    payload = bytes.fromhex(LIVE6_PARKED_FORWARD_TERMINAL_TABLE_HEXES[1])
    return [
        tuple(record)
        for record in struct.iter_unpack(">IHH", payload[10:])
    ]


def _rebuild_parked_forward_payload(records: list[tuple[int, int, int]]) -> bytes:
    header = bytes.fromhex(LIVE6_PARKED_FORWARD_TERMINAL_TABLE_HEXES[1])[:10]
    return header + b"".join(
        struct.pack(">IHH", origin, selector, code)
        for origin, selector, code in records
    )


def test_preview_refuses_terminal_record_before_the_final_position() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    records = _parked_forward_records()
    records[3], records[5] = records[5], records[3]

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            _rebuild_parked_forward_payload(records),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


def test_preview_refuses_terminal_record_with_wrong_selector_step() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    records = _parked_forward_records()
    origin, selector, code = records[-1]
    # +2 instead of the observed +1: identity-consistent origin for the
    # shifted selector so only the cadence discriminates.
    new_selector = selector + 1
    new_origin = 756 * new_selector + 7 * ((code & 0xFF) + 22 * (code >> 8))
    records[-1] = (new_origin, new_selector, code)

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            _rebuild_parked_forward_payload(records),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


def test_preview_refuses_terminal_record_identity_mismatch() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    records = _parked_forward_records()
    origin, selector, code = records[-1]
    records[-1] = (origin + 7, selector, code)

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            _rebuild_parked_forward_payload(records),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


@pytest.mark.parametrize("record_count", range(2, 41))
def test_preview_binds_every_supported_startup_table_capacity(
    record_count: int,
) -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = (
        bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)
        if record_count == 6
        else _canonical_startup_frame_table(record_count)
    )
    status = (
        bytes(8)
        if record_count == worker_module.FIXED_PREVIEW_FRAME_TABLE_RECORDS
        else worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS
    )

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        status,
        canonical_geometry,
    )
    startup_table = worker_module._validate_variable_frame_table_payload(payload)
    worker_module._validate_preview_density_source_contract(
        plan,
        startup_table,
        binding,
        binding.geometry,
    )

    assert binding.startup_records == record_count
    assert binding.geometry.height % 2 == 0
    assert (
        binding.geometry.native_height
        == worker_module._preview_native_height_for_startup_records(record_count)
    )
    assert binding.geometry.expected_stream_bytes == binding.geometry.height * 1_024
    assert binding.active_read_sequences == tuple(
        range(
            worker_module.PREVIEW_READ_SEQUENCES[0],
            binding.active_read_sequences[-1] + 1,
        )
    )
    assert binding.skipped_read_sequences == tuple(
        range(
            binding.active_read_sequences[-1] + 1,
            worker_module.PREVIEW_READ_SEQUENCES[-1] + 1,
        )
    )
    active_entries = [plan[sequence - 1] for sequence in binding.active_read_sequences]
    active_requests = [entry["request_len"] for entry in active_entries]
    assert sum(active_requests) == binding.geometry.expected_stream_bytes
    assert active_requests[:-1] == [
        worker_module.PREVIEW_READ_MAX_BYTES
    ] * (len(active_requests) - 1)
    assert 1 <= active_requests[-1] <= worker_module.PREVIEW_READ_MAX_BYTES
    skipped_entries = [
        plan[sequence - 1] for sequence in binding.skipped_read_sequences
    ]
    assert all(entry["request_len"] == 0 for entry in skipped_entries)
    assert all(entry["request_parts"] == [] for entry in skipped_entries)
    assert all(entry.get("preview_skipped") is True for entry in skipped_entries)
    if record_count == 40:
        assert binding.mode == "canonical-40-record"
        assert binding.skipped_read_sequences == ()
        assert all("drains_scan" not in entry for entry in active_entries)
    elif record_count == 37:
        assert binding.mode == "canonical-prefix-37-record"
    else:
        assert binding.mode == f"scanner-derived-{record_count}-record"
    if record_count < 40:
        assert [entry["drains_scan"] for entry in active_entries] == [False] * (
            len(active_entries) - 1
        ) + [True]
        assert all(
            entry["live_bound_request_len"] == entry["request_len"]
            for entry in active_entries
        )
        assert all("drains_scan" not in entry for entry in skipped_entries)


def test_preview_density_contract_refuses_geometry_or_read_receipt_tampering() -> None:
    payload = bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)
    startup_table = worker_module._validate_variable_frame_table_payload(payload)
    plan = load_canonical_plan()
    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        worker_module._derive_index_geometry(plan),
    )

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="geometry and READ receipt disagree",
    ):
        worker_module._validate_preview_density_source_contract(
            plan,
            startup_table,
            replace(binding, startup_records=7),
            binding.geometry,
        )

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="geometry and READ receipt disagree",
    ):
        worker_module._validate_preview_density_source_contract(
            plan,
            startup_table,
            binding,
            replace(
                binding.geometry,
                expected_stream_bytes=binding.geometry.expected_stream_bytes - 1,
            ),
        )


def test_preview_density_contract_refuses_compensating_read_mutations() -> None:
    payload = bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)
    startup_table = worker_module._validate_variable_frame_table_payload(payload)
    plan = load_canonical_plan()
    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        worker_module._derive_index_geometry(plan),
    )
    for sequence, delta in zip(
        binding.active_read_sequences[:2],
        (1, -1),
        strict=True,
    ):
        entry = plan[sequence - 1]
        mutated_request = entry["request_len"] + delta
        entry["request_len"] = mutated_request
        entry["request_parts"] = [mutated_request]
        entry["live_bound_request_len"] = mutated_request
        cdb = bytearray.fromhex(entry["cdb"])
        cdb[6:9] = mutated_request.to_bytes(3, "big")
        entry["cdb"] = cdb.hex()

    assert (
        sum(
            plan[sequence - 1]["request_len"]
            for sequence in binding.active_read_sequences
        )
        == binding.geometry.expected_stream_bytes
    )
    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="geometry and READ receipt disagree",
    ):
        worker_module._validate_preview_density_source_contract(
            plan,
            startup_table,
            binding,
            binding.geometry,
        )


@pytest.mark.parametrize(
    "tamper",
    (
        "request-parts",
        "live-bound-length",
        "cdb-transfer",
        "early-drain",
        "missing-final-drain",
        "active-skipped-marker",
    ),
)
def test_preview_density_contract_refuses_individual_active_read_tampering(
    tamper: str,
) -> None:
    payload = bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)
    startup_table = worker_module._validate_variable_frame_table_payload(payload)
    plan = load_canonical_plan()
    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        worker_module._derive_index_geometry(plan),
    )
    first = plan[binding.active_read_sequences[0] - 1]
    final = plan[binding.active_read_sequences[-1] - 1]
    if tamper == "request-parts":
        first["request_parts"] = [first["request_len"] - 1]
    elif tamper == "live-bound-length":
        first["live_bound_request_len"] += 1
    elif tamper == "cdb-transfer":
        cdb = bytearray.fromhex(first["cdb"])
        cdb[6:9] = (first["request_len"] - 1).to_bytes(3, "big")
        first["cdb"] = cdb.hex()
    elif tamper == "early-drain":
        first["drains_scan"] = True
    elif tamper == "missing-final-drain":
        final["drains_scan"] = False
    else:
        first["preview_skipped"] = True

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="geometry and READ receipt disagree",
    ):
        worker_module._validate_preview_density_source_contract(
            plan,
            startup_table,
            binding,
            binding.geometry,
        )


@pytest.mark.parametrize(
    "tamper",
    (
        "request-length",
        "request-parts",
        "live-bound-length",
        "skipped-marker",
        "drain-marker",
        "cdb-transfer",
        "cdb-shape",
    ),
)
def test_preview_density_contract_refuses_individual_skipped_read_tampering(
    tamper: str,
) -> None:
    payload = bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)
    startup_table = worker_module._validate_variable_frame_table_payload(payload)
    plan = load_canonical_plan()
    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
        worker_module._derive_index_geometry(plan),
    )
    skipped = plan[binding.skipped_read_sequences[0] - 1]
    if tamper == "request-length":
        skipped["request_len"] = 1
    elif tamper == "request-parts":
        skipped["request_parts"] = [0]
    elif tamper == "live-bound-length":
        skipped["live_bound_request_len"] = 1
    elif tamper == "skipped-marker":
        skipped["preview_skipped"] = False
    elif tamper == "drain-marker":
        skipped["drains_scan"] = False
    elif tamper == "cdb-transfer":
        cdb = bytearray.fromhex(skipped["cdb"])
        cdb[6:9] = (1).to_bytes(3, "big")
        skipped["cdb"] = cdb.hex()
    else:
        skipped["cdb"] = "00"

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="geometry and READ receipt disagree",
    ):
        worker_module._validate_preview_density_source_contract(
            plan,
            startup_table,
            binding,
            binding.geometry,
        )


@pytest.mark.parametrize("tamper", ("live-bound-length", "drain-marker"))
def test_preview_density_contract_preserves_canonical_40_read_sentinels(
    tamper: str,
) -> None:
    payload = _canonical_startup_frame_table(40)
    startup_table = worker_module._validate_variable_frame_table_payload(payload)
    plan = load_canonical_plan()
    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        bytes(8),
        worker_module._derive_index_geometry(plan),
    )
    first = plan[binding.active_read_sequences[0] - 1]
    if tamper == "live-bound-length":
        first["live_bound_request_len"] = first["request_len"]
    else:
        first["drains_scan"] = False

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="geometry and READ receipt disagree",
    ):
        worker_module._validate_preview_density_source_contract(
            plan,
            startup_table,
            binding,
            binding.geometry,
        )


@pytest.mark.parametrize("record_count", (0, 1, 41))
def test_preview_refuses_startup_table_count_outside_2_through_40(
    record_count: int,
) -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)

    with pytest.raises(worker_module.ProtocolError):
        worker_module._bind_preview_to_startup_table(
            plan,
            _startup_frame_table(record_count),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


def test_preview_refuses_truncated_or_malformed_6_record_short_strip_table() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)

    with pytest.raises(worker_module.ProtocolError, match="self-declared"):
        worker_module._bind_preview_to_startup_table(
            plan,
            payload[:-1],
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )

    malformed = bytearray(payload)
    malformed[-1] ^= 1
    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            bytes(malformed),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


@pytest.mark.parametrize(
    ("record_count", "wrong_status"),
    (
        (2, bytes(8)),
        (6, bytes(8)),
        (39, bytes(8)),
        (40, worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS),
    ),
)
def test_preview_refuses_wrong_startup_status_before_mutating_plan(
    record_count: int,
    wrong_status: bytes,
) -> None:
    plan = load_canonical_plan()
    original_plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = (
        bytes.fromhex(LIVE6_SHORT_STRIP_STARTUP_FRAME_TABLE_HEX)
        if record_count == 6
        else _canonical_startup_frame_table(record_count)
    )

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="short-table status",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            payload,
            wrong_status,
            canonical_geometry,
        )

    assert plan == original_plan


def test_preview_refuses_invalid_37_record_transport_table_before_set_window() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = bytearray(bytes.fromhex(LIVE37_STARTUP_FRAME_TABLE_HEX))
    payload[-1] ^= 1

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            bytes(payload),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )

    for sequence in worker_module.PREVIEW_SET_WINDOW_SEQUENCES:
        window = decode_window_block(bytes.fromhex(plan[sequence - 1]["data_out"]))
        assert window is not None
        assert window["height"] == 250_278


def test_preview_refuses_irregular_37_record_selector_ramp() -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = bytearray(bytes.fromhex(LIVE37_STARTUP_FRAME_TABLE_HEX))
    final_record = 10 + 36 * 8
    _origin, selector, code = struct.unpack_from(">IHH", payload, final_record)
    selector += 1
    origin = worker_module.transport_native_origin(code, selector)
    struct.pack_into(">IHH", payload, final_record, origin, selector, code)

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            bytes(payload),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


@pytest.mark.parametrize("record_index", (1, 36), ids=("leading-edge", "terminal"))
def test_preview_refuses_near_miss_37_record_edge_adjusted_selector_ramp(
    record_index: int,
) -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = bytearray(
        bytes.fromhex(LIVE37_EDGE_ADJUSTED_STARTUP_FRAME_TABLE_HEX)
    )
    record_offset = 10 + record_index * 8
    _origin, selector, code = struct.unpack_from(">IHH", payload, record_offset)
    selector += 1
    origin = worker_module.transport_native_origin(code, selector)
    struct.pack_into(">IHH", payload, record_offset, origin, selector, code)

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            bytes(payload),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


@pytest.mark.parametrize(
    "record_index", (0, 1, 36), ids=("first", "leading-edge", "terminal")
)
def test_preview_refuses_near_miss_37_record_post_fine_selector2_ramp(
    record_index: int,
) -> None:
    plan = load_canonical_plan()
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = bytearray(
        bytes.fromhex(LIVE37_POST_FINE_SELECTOR2_STARTUP_FRAME_TABLE_HEX)
    )
    record_offset = 10 + record_index * 8
    _origin, selector, code = struct.unpack_from(">IHH", payload, record_offset)
    selector += -1 if record_index == 36 else 1
    origin = worker_module.transport_native_origin(code, selector)
    struct.pack_into(">IHH", payload, record_offset, origin, selector, code)

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="not a valid Nikon transport record table",
    ):
        worker_module._bind_preview_to_startup_table(
            plan,
            bytes(payload),
            worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS,
            canonical_geometry,
        )


def test_dynamic_preview_final_read_marks_scan_drained() -> None:
    result = TransactionResult(
        phase=3,
        payload=b"",
        status=bytes(8),
        sense="000000",
        stall_recoveries=0,
    )

    scan_active, ready_required = worker_module._scan_lifecycle_after_transaction(
        {"seq": 162, "name": "READ", "drains_scan": True},
        result,
        scan_active=True,
        ready_required=False,
    )

    assert scan_active is False
    assert ready_required is True


def test_preview_accepts_complete_canonical_startup_table() -> None:
    plan = load_canonical_plan()
    original_plan = json.dumps(plan, sort_keys=True, separators=(",", ":"))
    canonical_geometry = worker_module._derive_index_geometry(plan)
    payload = _startup_frame_table(40)

    binding = worker_module._bind_preview_to_startup_table(
        plan,
        payload,
        bytes(8),
        canonical_geometry,
    )

    assert binding.mode == "canonical-40-record"
    assert binding.geometry == canonical_geometry
    assert binding.active_read_sequences == worker_module.PREVIEW_READ_SEQUENCES
    assert binding.skipped_read_sequences == ()
    assert json.dumps(plan, sort_keys=True, separators=(",", ":")) == original_plan


def test_startup_frame_table_rejects_nonzero_status_without_a_short_payload(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = _startup_frame_table(40)
    reads = iter(
        (
            (b"\x03", 0),
            (payload, 0),
            (worker_module.VARIABLE_FRAME_TABLE_SHORT_STATUS, 0),
        )
    )
    monkeypatch.setattr(
        worker_module,
        "_read_with_one_stall_recovery",
        lambda *_args, **_kwargs: next(reads),
    )
    monkeypatch.setattr(
        worker_module,
        "_write_exact",
        lambda *_args, **_kwargs: None,
    )
    entry = load_canonical_plan()[worker_module.VARIABLE_FRAME_TABLE_SEQUENCE - 1]

    with pytest.raises(
        worker_module.SynchronizedProtocolError,
        match="command 64 status 022b4b",
    ):
        worker_module._perform_variable_frame_table_transaction(
            object(),
            object(),
            entry,
            data_timeout_ms=30_000,
        )


@pytest.mark.parametrize(
    "status",
    (
        bytes.fromhex("022b4a0000000000"),
        bytes.fromhex("012b4b0000000000"),
        bytes.fromhex("022b4b0000000001"),
    ),
)
def test_startup_frame_table_rejects_other_statuses_for_a_short_payload(
    monkeypatch: pytest.MonkeyPatch,
    status: bytes,
) -> None:
    reads = iter(((b"\x03", 0), (_startup_frame_table(36), 0), (status, 0)))
    monkeypatch.setattr(
        worker_module,
        "_read_with_one_stall_recovery",
        lambda *_args, **_kwargs: next(reads),
    )
    monkeypatch.setattr(worker_module, "_write_exact", lambda *_args: None)
    entry = load_canonical_plan()[worker_module.VARIABLE_FRAME_TABLE_SEQUENCE - 1]

    with pytest.raises(worker_module.SynchronizedProtocolError):
        worker_module._perform_variable_frame_table_transaction(
            object(),
            object(),
            entry,
            data_timeout_ms=30_000,
        )


def test_startup_frame_table_status_cannot_bypass_a_malformed_short_payload(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    malformed = bytearray(_startup_frame_table(36))
    malformed[8] = 0
    reads = iter(((b"\x03", 0), (bytes(malformed), 0)))
    monkeypatch.setattr(
        worker_module,
        "_read_with_one_stall_recovery",
        lambda *_args, **_kwargs: next(reads),
    )
    monkeypatch.setattr(worker_module, "_write_exact", lambda *_args: None)
    entry = load_canonical_plan()[worker_module.VARIABLE_FRAME_TABLE_SEQUENCE - 1]

    with pytest.raises(
        worker_module.DesynchronizedProtocolError,
        match="malformed bounded 0x8f response",
    ):
        worker_module._perform_variable_frame_table_transaction(
            object(),
            object(),
            entry,
            data_timeout_ms=30_000,
        )


def test_frozen_worker_uses_pinned_meter_identity_without_loose_source(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    missing_source = Path("/frozen/NegPy.app/Contents/Resources/meter.py")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(
        "coolscanpy.protocol.ls5000_single_pass.worker.meter_module.__file__",
        str(missing_source),
    )


def test_usb_device_selection_requires_exact_reviewed_sane_topology() -> None:
    wrong = SimpleNamespace(bus=1, address=9)
    exact = SimpleNamespace(bus=1, address=2)
    calls: list[dict[str, object]] = []

    def find(**kwargs: object) -> tuple[object, ...]:
        calls.append(kwargs)
        return wrong, exact

    selected = worker_module._find_ls5000_usb_device(
        SimpleNamespace(find=find),
        expected_bus=1,
        expected_address=2,
    )

    assert selected is exact
    assert calls == [
        {
            "idVendor": 0x04B0,
            "idProduct": 0x4002,
            "find_all": True,
            "backend": None,
        }
    ]


def test_usb_device_selection_refuses_missing_or_ambiguous_exact_topology() -> None:
    for devices in (
        (SimpleNamespace(bus=1, address=9),),
        (
            SimpleNamespace(bus=1, address=2),
            SimpleNamespace(bus=1, address=2),
        ),
    ):
        core = SimpleNamespace(find=lambda **_kwargs: devices)
        with pytest.raises(ProtocolError, match="exact USB topology"):
            worker_module._find_ls5000_usb_device(
                core,
                expected_bus=1,
                expected_address=2,
            )


@pytest.mark.parametrize("meter_only", (False, True))
def test_live_full_and_meter_refuse_usb_first_device_fallback(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    meter_only: bool,
) -> None:
    connect_calls: list[dict[str, object]] = []
    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        lambda **kwargs: connect_calls.append(kwargs),
    )

    with pytest.raises(ProtocolError, match="require exact USB bus and address"):
        worker_module.run_live_capture(
            load_canonical_plan(),
            tmp_path / "plan.jsonl",
            CANONICAL_PLAN_SHA256,
            tmp_path / "capture.bin",
            tmp_path / "journal.json",
            worker_module.EXPECTED_FINE_READS,
            frame=17,
            meter_only=meter_only,
        )

    assert connect_calls == []


def test_live_child_rejects_altered_self_consistent_plan_before_usb(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plan_path = tmp_path / "plan.jsonl"
    manifest_path = tmp_path / "manifest.json"
    plan = load_canonical_plan()
    plan[1] = {**plan[1], "cdb": "1b0000000000"}
    plan_payload = b"".join(
        (json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode()
        for entry in plan
    )
    plan_path.write_bytes(plan_payload)
    manifest = json.loads(
        (worker_module.HERE / "data" / "replay-first-rgbi4-manifest.json").read_text(
            encoding="utf-8"
        )
    )
    manifest["plan_sha256"] = hashlib.sha256(plan_payload).hexdigest()
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    connect_calls: list[dict[str, object]] = []
    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        lambda **kwargs: connect_calls.append(kwargs),
    )

    with pytest.raises(ProtocolError, match="packaged canonical plan"):
        main(
            [
                "--plan",
                str(plan_path),
                "--manifest",
                str(manifest_path),
                "--output",
                str(tmp_path / "capture.bin"),
                "--journal",
                str(tmp_path / "journal.json"),
                "--preview-only",
                "--expected-usb-bus",
                "1",
                "--expected-usb-address",
                "2",
                "--live",
            ]
        )

    assert connect_calls == []


def test_live_child_revalidates_parent_bundle_identity_before_usb(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plan_path = worker_module.HERE / "data" / "replay-first-rgbi4-plan.jsonl"
    manifest_path = worker_module.HERE / "data" / "replay-first-rgbi4-manifest.json"
    connect_calls: list[dict[str, object]] = []
    monkeypatch.setattr(
        worker_module, "verify_capture_bundle", lambda **_kwargs: "0" * 64
    )
    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        lambda **kwargs: connect_calls.append(kwargs),
    )

    with pytest.raises(ProtocolError, match="changed after parent verification"):
        main(
            [
                "--plan",
                str(plan_path),
                "--manifest",
                str(manifest_path),
                "--output",
                str(tmp_path / "capture.bin"),
                "--journal",
                str(tmp_path / "journal.json"),
                "--preview-only",
                "--expected-usb-bus",
                "1",
                "--expected-usb-address",
                "2",
                "--expected-capture-bundle-sha256",
                worker_module.CAPTURE_BUNDLE_SHA256,
                "--live",
            ]
        )

    assert connect_calls == []


def test_continuation_compiler_emits_the_pinned_89_steps_without_session_commands() -> (
    None
):
    steps = compile_continuation_steps(
        load_canonical_plan(),
        load_canonical_continuation_plan(),
    )

    assert len(steps) == 89
    assert [step.code for step in steps] == [
        raw[0]
        for raw in load_canonical_continuation_plan()["trace_equivalence"][
            "semantic_steps"
        ]
    ]
    sequences = [entry["seq"] for step in steps for entry in step.entries]
    assert sequences[0] == 225
    assert sequences[-1] == 606
    assert 500 not in sequences
    assert not {
        "RESERVE_UNIT",
        "RELEASE_UNIT",
        "VENDOR_E0:EJECT",
        "SEND:sub_008f",
    }.intersection(entry["name"] for step in steps for entry in step.entries)
    assert [step.code for step in steps].count("R") == 15


def test_batch_job_loader_binds_ordered_frame_paths_and_parent_ack_contract(
    tmp_path: Path,
) -> None:
    session_id = "batch-slot17-slot19-session"
    fingerprint = _reviewed_fingerprint()
    approval = ManualFrameApproval(
        reviewed_fingerprint_sha256=fingerprint.binding_sha256,
        slot=17,
        boundary_offset_rows=-12,
        thumbnail_sha256="3" * 64,
        reviewed_lookup_row=2_400,
        reviewed_native_origin=100_000,
        review_reasons=("transport-origin-inferred",),
    )
    job_path = tmp_path / "batch-job.json"
    job_path.write_text(
        json.dumps(
            {
                "apply_all_boundary_offsets_before_first_frame": True,
                "capture_plan_sha256": "a" * 64,
                "continuation_plan_sha256": "b" * 64,
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
                "session_contract": "one-process-one-reservation",
                "session_id": session_id,
            }
        ),
        encoding="utf-8",
    )

    job = load_validated_batch_job(
        job_path,
        expected_job_sha256=hashlib.sha256(job_path.read_bytes()).hexdigest(),
        expected_plan_sha256="a" * 64,
        expected_continuation_sha256="b" * 64,
    )

    assert job.session_id == session_id
    assert job.selected_slots == (17, 19)
    assert job.reviewed_fingerprint == fingerprint
    assert (job.expected_usb_bus, job.expected_usb_address) == (1, 2)
    assert job.frames[0].manual_review_approval == approval
    assert job.frames[1].manual_review_approval is None
    assert [frame.boundary_offset_rows for frame in job.frames] == [-12, 8]
    assert job.job_sha256 == hashlib.sha256(job_path.read_bytes()).hexdigest()
    assert job.frames[0].output == tmp_path / "frame-017" / "capture.bin"
    assert job.frames[0].journal == tmp_path / "frame-017" / "journal.json"
    assert job.frames[0].ack == tmp_path / "frame-017" / "parent-ack.json"


def test_parent_ack_is_bound_to_session_frame_slot_and_fresh_nonce(
    tmp_path: Path,
) -> None:
    ack_path = tmp_path / "parent-ack.json"
    ack_path.write_text(
        json.dumps(
            {
                "ack_nonce": "fresh-nonce-17",
                "action": "continue",
                "frame_index": 1,
                "schema_version": 1,
                "session_id": "batch-session",
                "slot": 17,
            }
        ),
        encoding="utf-8",
    )

    action = wait_for_parent_ack(
        ack_path,
        session_id="batch-session",
        frame_index=1,
        slot=17,
        nonce="fresh-nonce-17",
        timeout_seconds=0,
        poll_seconds=0,
    )

    assert action == "continue"

    assert _meter_controller_sha256() == (
        "6b17a06fd1baf1be872a19e819d4e642d42e542601c82b506891bb943969a25c"
    )


def test_batch_cli_dry_run_validates_one_session_without_single_frame_flags(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    data = files(DATA_PACKAGE)
    plan_path = Path(data.joinpath("replay-first-rgbi4-plan.jsonl"))
    manifest_path = Path(data.joinpath("replay-first-rgbi4-manifest.json"))
    continuation_path = Path(data.joinpath("replay-next-rgbi4-plan.json"))
    fingerprint = _reviewed_fingerprint()
    job_path = tmp_path / "batch-job.json"
    job_path.write_text(
        json.dumps(
            {
                "apply_all_boundary_offsets_before_first_frame": True,
                "capture_plan_sha256": hashlib.sha256(
                    plan_path.read_bytes()
                ).hexdigest(),
                "continuation_plan_sha256": hashlib.sha256(
                    continuation_path.read_bytes()
                ).hexdigest(),
                "expected_usb_address": 2,
                "expected_usb_bus": 1,
                "frames": [
                    {
                        "ack": "frame-017/parent-ack.json",
                        "boundary_offset_rows": -12,
                        "journal": "frame-017/journal.json",
                        "manual_review_approval": None,
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
                "session_contract": "one-process-one-reservation",
                "session_id": "batch-dry-run",
            }
        ),
        encoding="utf-8",
    )

    main(
        [
            "--batch-job",
            str(job_path),
            "--expected-batch-job-sha256",
            hashlib.sha256(job_path.read_bytes()).hexdigest(),
            "--plan",
            str(plan_path),
            "--continuation-plan",
            str(continuation_path),
            "--manifest",
            str(manifest_path),
            "--session-journal",
            str(tmp_path / "session-journal.json"),
        ]
    )

    output = capsys.readouterr().out
    assert "validated RGBI4x batch" in output
    assert "slots 17, 19" in output
    assert "dry run only; scanner was not accessed" in output
    assert not (tmp_path / "frame-017").exists()


def test_batch_cli_refuses_a_topology_rewrite_before_any_usb_access(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data = files(DATA_PACKAGE)
    plan_path = Path(data.joinpath("replay-first-rgbi4-plan.jsonl"))
    manifest_path = Path(data.joinpath("replay-first-rgbi4-manifest.json"))
    continuation_path = Path(data.joinpath("replay-next-rgbi4-plan.json"))
    fingerprint = _reviewed_fingerprint()
    job_path = tmp_path / "batch-job.json"
    job = {
        "apply_all_boundary_offsets_before_first_frame": True,
        "capture_plan_sha256": hashlib.sha256(plan_path.read_bytes()).hexdigest(),
        "continuation_plan_sha256": hashlib.sha256(
            continuation_path.read_bytes()
        ).hexdigest(),
        "expected_usb_address": 2,
        "expected_usb_bus": 1,
        "frames": [
            {
                "ack": "frame-017/parent-ack.json",
                "boundary_offset_rows": 0,
                "journal": "frame-017/journal.json",
                "manual_review_approval": None,
                "output": "frame-017/capture.bin",
                "slot": 17,
            }
        ],
        "parent_ack_required_after_every_frame": True,
        "release_once_after_last_frame": True,
        "reviewed_roll_fingerprint": fingerprint.to_payload(),
        "schema_version": 3,
        "session_contract": "one-process-one-reservation",
        "session_id": "batch-tampered-topology",
    }
    job_path.write_text(json.dumps(job), encoding="utf-8")
    prepared_sha256 = hashlib.sha256(job_path.read_bytes()).hexdigest()

    job["expected_usb_address"] = 9
    job_path.write_text(json.dumps(job), encoding="utf-8")
    connect_calls: list[object] = []
    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        lambda **kwargs: connect_calls.append(kwargs),
    )

    with pytest.raises(ProtocolError, match="SHA-256 mismatch before USB access"):
        main(
            [
                "--batch-job",
                str(job_path),
                "--expected-batch-job-sha256",
                prepared_sha256,
                "--plan",
                str(plan_path),
                "--continuation-plan",
                str(continuation_path),
                "--manifest",
                str(manifest_path),
                "--session-journal",
                str(tmp_path / "session-journal.json"),
                "--live",
            ]
        )

    assert connect_calls == []
    assert not (tmp_path / "session-journal.json").exists()


def test_synchronized_cleanup_receipt_records_the_single_release_attempt(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    releases: list[tuple[object, object]] = []

    def release(ep_out: object, ep_in: object) -> TransactionResult:
        releases.append((ep_out, ep_in))
        return TransactionResult(1, b"", bytes.fromhex("0000000000000000"), "000000", 2)

    monkeypatch.setattr(
        "coolscanpy.protocol.ls5000_single_pass.worker._release_unit",
        release,
    )

    receipt = _cleanup_synchronized(
        "out",
        "in",
        scan_active=False,
        ready_required=False,
        reserved=True,
    )

    assert releases == [("out", "in")]
    assert receipt == {
        "attempted": True,
        "complete": True,
        "release_attempted": True,
        "release_status": "0000000000000000",
        "release_succeeded": True,
    }


def test_live_batch_connect_failure_records_no_reservation_and_no_recovery(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = tmp_path / "batch-connect-failure"
    root.mkdir()
    frame = worker_module.BatchFrameSpec(
        slot=17,
        boundary_offset_rows=0,
        output=root / "frame-017" / "capture.bin",
        journal=root / "frame-017" / "journal.json",
        ack=root / "frame-017" / "parent-ack.json",
    )
    frame.output.parent.mkdir()
    batch = worker_module.LiveBatchJob(
        session_id="batch-connect-failure",
        root=root,
        frames=(frame,),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
        plan_sha256=CANONICAL_PLAN_SHA256,
        continuation_plan_sha256=(worker_module.CANONICAL_CONTINUATION_PLAN_SHA256),
        job_sha256="c" * 64,
    )
    session_journal = root / "session-journal.json"
    connect_calls: list[dict[str, int | None]] = []

    def fail_connect(**kwargs: int | None) -> object:
        connect_calls.append(kwargs)
        raise ProtocolError("USB device absent")

    monkeypatch.setattr(
        worker_module,
        "_connect_device",
        fail_connect,
    )

    with pytest.raises(ProtocolError, match="USB device absent"):
        worker_module.run_live_capture(
            load_canonical_plan(),
            tmp_path / "plan.jsonl",
            CANONICAL_PLAN_SHA256,
            frame.output,
            frame.journal,
            worker_module.EXPECTED_FINE_READS,
            frame=17,
            boundary_offset_rows=0,
            batch_job=batch,
            continuation_plan=load_canonical_continuation_plan(),
            continuation_plan_sha256=(worker_module.CANONICAL_CONTINUATION_PLAN_SHA256),
            session_journal_path=session_journal,
        )

    receipt = json.loads(session_journal.read_text(encoding="utf-8"))
    assert connect_calls == [{"expected_usb_bus": 1, "expected_usb_address": 2}]
    assert receipt["status"] == "failed"
    assert receipt["reservation_acquired"] is False
    assert receipt["unit_release_attempts"] == 0
    assert receipt["unit_released"] is False
    assert receipt["recovery_required"] == "none"


def test_live_batch_refuses_a_connected_scanner_that_changed_topology(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = tmp_path / "batch-topology-mismatch"
    root.mkdir()
    frame = worker_module.BatchFrameSpec(
        slot=17,
        boundary_offset_rows=0,
        output=root / "frame-017" / "capture.bin",
        journal=root / "frame-017" / "journal.json",
        ack=root / "frame-017" / "parent-ack.json",
    )
    frame.output.parent.mkdir()
    batch = worker_module.LiveBatchJob(
        session_id="batch-topology-mismatch",
        root=root,
        frames=(frame,),
        reviewed_fingerprint=_reviewed_fingerprint(),
        expected_usb_bus=1,
        expected_usb_address=2,
        plan_sha256=CANONICAL_PLAN_SHA256,
        continuation_plan_sha256=(worker_module.CANONICAL_CONTINUATION_PLAN_SHA256),
        job_sha256="c" * 64,
    )

    class USBUtil:
        @staticmethod
        def release_interface(_device: object, _interface_number: int) -> None:
            return None

        @staticmethod
        def dispose_resources(_device: object) -> None:
            return None

    connect_calls: list[dict[str, int | None]] = []

    def connect(**kwargs: int | None) -> tuple[object, object, object, object, object]:
        connect_calls.append(kwargs)
        return (
            SimpleNamespace(bus=1, address=9),
            SimpleNamespace(bInterfaceNumber=0),
            object(),
            object(),
            USBUtil,
        )

    monkeypatch.setattr(worker_module, "_connect_device", connect)
    session_journal = root / "session-journal.json"

    with pytest.raises(ProtocolError, match="exact requested USB topology"):
        worker_module.run_live_capture(
            load_canonical_plan(),
            tmp_path / "plan.jsonl",
            CANONICAL_PLAN_SHA256,
            frame.output,
            frame.journal,
            worker_module.EXPECTED_FINE_READS,
            frame=17,
            boundary_offset_rows=0,
            batch_job=batch,
            continuation_plan=load_canonical_continuation_plan(),
            continuation_plan_sha256=(worker_module.CANONICAL_CONTINUATION_PLAN_SHA256),
            session_journal_path=session_journal,
        )

    assert connect_calls == [{"expected_usb_bus": 1, "expected_usb_address": 2}]
    receipt = json.loads(session_journal.read_text(encoding="utf-8"))
    assert receipt["expected_usb_bus"] == 1
    assert receipt["expected_usb_address"] == 2
    assert receipt["actual_usb_bus"] is None
    assert receipt["actual_usb_address"] is None
    assert receipt["reservation_acquired"] is False
    assert receipt["recovery_required"] == "none"


def _mapping(fields: tuple[tuple[int, int, int], ...]) -> TransportMapping:
    origins = tuple(
        NativeFrameOrigin(
            frame=frame,
            boundary_index=frame - 1,
            boundary_output_row=frame * 144,
            lookup_row=frame * 144,
            code=code,
            selector=selector,
            native_origin=native_origin,
            method="test-fixture",
            automatic=True,
            manual_review=False,
            review_reasons=(),
            affine_residual_rows=0.0,
        )
        for frame, (native_origin, selector, code) in enumerate(fields, start=1)
    )
    return TransportMapping(
        record_count=len(origins),
        native_intercept=0.0,
        native_units_per_preview_row=42.0,
        anchor_mae_rows=0.0,
        anchor_max_error_rows=0.0,
        origins=origins,
    )


def _short_strip_mapping(
    count: int,
    *,
    non_addressable_trailing: int = 0,
) -> tuple[TransportMapping, tuple[TransportRecord, ...]]:
    """A live-shaped mapping/records pair shorter than a full roll.

    ``non_addressable_trailing`` marks that many of the last ``count``
    origins as outside the index raster, the same way a real detector would
    flag a candidate slot build_live_frame_table_payload must not address.
    """

    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    lookup_rows = tuple(100 + 143 * index for index in range(count))
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
            review_reasons=(
                ("outside-index-raster",)
                if frame > count - non_addressable_trailing
                else ()
            ),
            affine_residual_rows=0.0,
        )
        for frame, row in enumerate(lookup_rows, start=1)
    )
    return TransportMapping(6_000, 168.0, 42.0, 0.0, 0.0, origins), records


def _with_reviewed_leading_anchor(
    mapping: TransportMapping,
    *,
    residual_rows: float = -3.924,
) -> TransportMapping:
    leading = replace(
        mapping.origins[0],
        method="direct-gap-trailing-row",
        automatic=False,
        manual_review=True,
        review_reasons=("leading-anchor-divergence",),
        affine_residual_rows=residual_rows,
    )
    return replace(mapping, origins=(leading, *mapping.origins[1:]))


def test_reviewed_leading_anchor_remains_a_table_prefix_for_later_frames() -> None:
    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping)

    adjusted, resolved = apply_batch_boundary_offsets(
        mapping,
        records,
        ((19, 0),),
        approved_manual_slots=frozenset(),
    )

    assert resolved[0][1].frame == 19
    assert len(worker_module._addressable_frame_origins(adjusted)) == 36


def test_reviewed_leading_anchor_still_requires_approval_when_selected() -> None:
    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping)

    with pytest.raises(ProtocolError, match="frame 1 transport origin requires manual review"):
        apply_batch_boundary_offsets(
            mapping,
            records,
            ((1, 0),),
            approved_manual_slots=frozenset(),
        )


@pytest.mark.parametrize(
    ("frame", "residual_rows"),
    [
        (1, -5.001),
        (2, 2.001),
    ],
)
def test_addressable_prefix_keeps_leading_exception_narrow(
    frame: int,
    residual_rows: float,
) -> None:
    mapping, _records = _short_strip_mapping(6)
    mapping = _with_reviewed_leading_anchor(mapping)
    changed = replace(
        mapping.origins[frame - 1],
        affine_residual_rows=residual_rows,
    )
    mapping = replace(
        mapping,
        origins=(
            *mapping.origins[: frame - 1],
            changed,
            *mapping.origins[frame:],
        ),
    )

    with pytest.raises(ProtocolError, match="fewer than 2 scanner-addressable"):
        worker_module._addressable_frame_origins(mapping)


# -- narrow leading-anchor-divergence auto-acceptance ------------------------
#
# The live capture that motivated this exception (attempt 4, 2026-07-23) had
# its preserved binaries removed by a later tmp-directory cleanup, so there is
# no original preview/table capture left to replay. These tests instead build
# the same synthetic mapping/records/fingerprint shapes the rest of this file
# already uses (`_short_strip_mapping`, `_with_reviewed_leading_anchor`,
# `_reviewed_fingerprint_with_count`), but pinned to attempt 4's own measured
# numbers: 36 scanner-addressable slots, a fresh scan-time leading residual of
# -2.497 preview rows (inside the five-row hard bound), and a reviewed-preview
# leading residual of -1.525 preview rows (inside the two-row interior bound,
# hence "automatic" at preflight).


def test_leading_anchor_divergence_narrowly_auto_accepted_when_reviewed_automatic() -> (
    None
):
    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping, residual_rows=-2.497)

    adjusted, resolved = apply_batch_boundary_offsets(
        mapping,
        records,
        ((1, 0),),
        approved_manual_slots=frozenset(),
        reviewed_automatic_slots=frozenset({1}),
    )

    assert resolved[0][1].frame == 1
    assert len(worker_module._addressable_frame_origins(adjusted)) == 36


def test_leading_anchor_divergence_still_manual_beyond_five_row_bound() -> None:
    # -5.001 rows is a residual derive_transport_mapping would never actually
    # hand back (it raises IndexDecodeError first, above the five-row bound);
    # this proves apply_batch_boundary_offsets's own narrow-acceptance check
    # re-verifies the bound rather than trusting reviewed_automatic_slots alone.
    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping, residual_rows=-5.001)

    with pytest.raises(
        ProtocolError, match="frame 1 transport origin requires manual review"
    ):
        apply_batch_boundary_offsets(
            mapping,
            records,
            ((1, 0),),
            approved_manual_slots=frozenset(),
            reviewed_automatic_slots=frozenset({1}),
        )


def test_leading_anchor_divergence_still_manual_with_second_origin_issue() -> None:
    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping, residual_rows=-2.497)
    origin = mapping.origins[0]
    changed = replace(
        origin,
        # A second, unrelated review reason from the same gap boundary --
        # leading-anchor divergence must be the *only* fresh-origin issue.
        review_reasons=(*origin.review_reasons, "narrow-gap-evidence"),
    )
    mapping = replace(mapping, origins=(changed, *mapping.origins[1:]))

    with pytest.raises(
        ProtocolError, match="frame 1 transport origin requires manual review"
    ):
        apply_batch_boundary_offsets(
            mapping,
            records,
            ((1, 0),),
            approved_manual_slots=frozenset(),
            reviewed_automatic_slots=frozenset({1}),
        )


def test_leading_anchor_divergence_still_manual_when_not_reviewed_automatic() -> None:
    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping, residual_rows=-2.497)

    with pytest.raises(
        ProtocolError, match="frame 1 transport origin requires manual review"
    ):
        apply_batch_boundary_offsets(
            mapping,
            records,
            ((1, 0),),
            approved_manual_slots=frozenset(),
            # Empty: the reviewed session's own preflight did not classify
            # this slot automatic (or this call did not say so), so the
            # narrow exception must not fire no matter how clean the fresh
            # residual is.
            reviewed_automatic_slots=frozenset(),
        )


def test_batch_selections_derive_reviewed_automatic_slots_from_missing_approvals(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """_derive_live_batch_selections must derive condition 5 itself.

    Roll.scan_many() -- the sole production constructor of the request a
    batch job comes from -- already refuses (ManualReviewRequired) any slot
    its own reviewed session marked manual_review without a valid approval,
    and RollPreviewSession.approve_manual_origin refuses to approve a slot
    that is not manual_review. A slot with no manual_review_approval reaching
    this function therefore already proves its reviewed session classified
    it automatic at preflight.
    """

    mapping, records = _short_strip_mapping(36)
    mapping = _with_reviewed_leading_anchor(mapping, residual_rows=-2.497)
    reviewed = _reviewed_fingerprint_with_count(36)
    context = _batch_selection_context(mapping, records, reviewed)
    frames = _one_slot_batch(tmp_path, "leading-anchor-wiring", 1)

    monkeypatch.setattr(
        worker_module, "_derive_live_frame_selection", lambda *_a, **_k: context
    )
    monkeypatch.setattr(
        worker_module,
        "compare_selected_roll_fingerprint",
        lambda *_a, **_k: SimpleNamespace(matches=True, reason="matched"),
        raising=False,
    )
    monkeypatch.setattr(
        worker_module,
        "validate_live_0x8e_bytes",
        lambda table, _height: (table, context.geometry.height),
    )
    monkeypatch.setattr(
        worker_module,
        "parse_live_transport_records_bytes",
        lambda *_a, **_k: records,
    )
    monkeypatch.setattr(
        worker_module, "_bind_plan_to_live_selection", lambda *_a, **_k: None
    )

    selections = worker_module._derive_live_batch_selections(
        [],
        b"fresh-preview",
        b"fresh-table",
        frames,
        reviewed_fingerprint=reviewed,
    )

    # This helper's mocked compare_selected_roll_fingerprint returns a bare
    # SimpleNamespace without a to_payload() method, so this checks the
    # underlying fields directly rather than the full diagnostics() dict --
    # test_derive_live_frame_selection_accepts_full_incident_shape above
    # already exercises the real journal payload end to end.
    assert len(selections) == 1
    assert selections[0].leading_anchor_divergence_accepted is True
    assert selections[0].base_selected.affine_residual_rows == pytest.approx(-2.497)


def _leading_anchor_gate_fixture(
    monkeypatch: pytest.MonkeyPatch,
    *,
    frame_count: int = 36,
    mismatched: bool,
) -> ReviewedRollFingerprint:
    """Same shape as ``test_fresh_batch_index_refuses_a_different_roll_...``
    above, with frame 1's origin rebuilt as a bounded leading-anchor-only
    divergence (fresh residual -2.497 rows) instead of a plain automatic
    origin. ``mismatched`` reuses the same reversed-frame-order trick that
    test already relies on to force a visual-content mismatch; otherwise the
    fresh raster is bit-identical to the reviewed one.
    """

    frame_height = 20
    intervals = tuple(
        (slot * frame_height, (slot + 1) * frame_height) for slot in range(frame_count)
    )
    reviewed_frames = []
    for slot in range(frame_count):
        rng = np.random.default_rng(70_000 + slot)
        reviewed_frames.append(
            np.repeat(
                np.repeat(
                    rng.integers(2_000, 50_000, size=(10, 10, 3), dtype=np.uint16),
                    2,
                    axis=0,
                ),
                2,
                axis=1,
            )
        )
    reviewed_rgb = np.concatenate(reviewed_frames, axis=0)
    fresh_rgb = (
        np.concatenate(list(reversed(reviewed_frames)), axis=0)
        if mismatched
        else reviewed_rgb
    )
    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    lookup_rows = tuple(100 + 143 * index for index in range(frame_count))
    origins = [
        NativeFrameOrigin(
            frame=frame,
            boundary_index=frame - 1,
            boundary_output_row=intervals[frame - 1][0],
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
        for frame, row in enumerate(lookup_rows, start=1)
    ]
    origins[0] = replace(
        origins[0],
        automatic=False,
        manual_review=True,
        review_reasons=(worker_module.LEADING_ANCHOR_REVIEW_REASON,),
        affine_residual_rows=-2.497,
    )
    origins_tuple = tuple(origins)
    mapping = TransportMapping(
        6_000,
        origins_tuple[0].native_origin - 42.0 * origins_tuple[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins_tuple,
    )
    reviewed = build_reviewed_roll_fingerprint(
        reviewed_rgb,
        frame_intervals=intervals,
        frame_native_origins=tuple(origin.native_origin for origin in origins_tuple),
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )
    geometry = SimpleNamespace(
        requested_resolution=97,
        native_resolution=4_000,
        pitch=41,
        native_width=3_946,
        native_height=250_278,
        width=20,
        height=len(fresh_rgb),
        block_bytes=1,
        expected_stream_bytes=1,
    )
    detection = SimpleNamespace(
        confidence="high",
        intervals=tuple(
            SimpleNamespace(start_row=start, end_row=end) for start, end in intervals
        ),
        boundaries=(),
        diagnostics=lambda: {},
    )
    monkeypatch.setattr(worker_module, "_derive_index_geometry", lambda _plan: geometry)
    monkeypatch.setattr(
        worker_module,
        "validate_live_0x8e_bytes",
        lambda table, _height: (table, len(fresh_rgb)),
    )
    monkeypatch.setattr(
        worker_module,
        "decode_full_index_bytes",
        lambda *_args, **_kwargs: (
            fresh_rgb,
            np.ones(len(fresh_rgb), dtype=bool),
            {},
        ),
    )
    monkeypatch.setattr(
        worker_module, "detect_roll_frames", lambda *_args, **_kwargs: detection
    )
    monkeypatch.setattr(
        worker_module,
        "parse_live_transport_records_bytes",
        lambda *_args, **_kwargs: records,
    )
    monkeypatch.setattr(
        worker_module, "derive_transport_mapping", lambda *_args, **_kwargs: mapping
    )
    return reviewed


def test_derive_live_frame_selection_accepts_full_incident_shape(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """End-to-end gate acceptance encoding attempt 4's exact parameters: 36
    addressable slots, fresh leading residual -2.497 rows against the
    5.0-row hard bound, a reviewed-preflight residual of -1.525 rows
    (automatic), and matching global and selected visual fingerprints on
    both traversals.
    """

    reviewed = _leading_anchor_gate_fixture(monkeypatch, mismatched=False)

    selection = worker_module._derive_live_frame_selection(
        [],
        b"fresh-preview",
        b"fresh-table",
        frame=1,
        reviewed_fingerprint=reviewed,
        manual_review_approved=False,
        reviewed_as_automatic=True,
        reviewed_leading_residual_rows=-1.525,
    )

    assert selection.frame == 1
    assert selection.frame_count == 36
    assert selection.leading_anchor_divergence_accepted is True
    assert selection.fingerprint_comparison is not None
    assert selection.fingerprint_comparison.matches
    assert selection.selected_fingerprint_comparison is not None
    assert selection.selected_fingerprint_comparison.matches
    accepted = selection.diagnostics()["leading_anchor_divergence_accepted"]
    assert accepted == {
        "origin": worker_module.LEADING_ANCHOR_DIVERGENCE_ACCEPTED_ORIGIN,
        "fresh_residual_rows": pytest.approx(-2.497),
        "reviewed_residual_rows": pytest.approx(-1.525),
    }


def test_derive_live_frame_selection_still_refuses_on_fingerprint_mismatch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An otherwise-eligible, bounded, reviewed-automatic leading-anchor-only
    frame 1 must still refuse when the fresh visual fingerprint does not
    match -- and with the pre-existing fingerprint-mismatch message, proving
    the fingerprint checks still run first, in their unchanged order, ahead
    of this narrow exception.
    """

    reviewed = _leading_anchor_gate_fixture(monkeypatch, mismatched=True)

    with pytest.raises(
        ProtocolError, match="does not match the reviewed roll fingerprint"
    ):
        worker_module._derive_live_frame_selection(
            [],
            b"fresh-preview",
            b"fresh-table",
            frame=1,
            reviewed_fingerprint=reviewed,
            manual_review_approved=False,
            reviewed_as_automatic=True,
            reviewed_leading_residual_rows=-1.525,
        )


def test_live8_frame_table_is_the_exact_firmware_accepted_payload() -> None:
    payload = build_live_frame_table_payload(_mapping(LIVE8_TRANSPORT_FIELDS))
    send = next(entry for entry in load_canonical_plan() if entry["seq"] == 174)

    assert FRAME_TABLE_SEND_RECORDS == 37
    assert FRAME_TABLE_SEND_BYTES == 300
    assert send["cdb"] == "2a008f00000300012c00"
    assert len(payload) == FRAME_TABLE_SEND_BYTES
    assert payload[:4] == bytes.fromhex("012a2500")
    assert (
        hashlib.sha256(payload).hexdigest()
        == "b78f6d8a1df1e0d5b242eda27eca88d121a6db2d2e64cf55ae9305142e39fc08"
    )


def test_frame_table_refuses_fewer_than_two_origins() -> None:
    with pytest.raises(ProtocolError, match="fewer than 2"):
        build_live_frame_table_payload(_mapping(LIVE8_TRANSPORT_FIELDS[:1]))


def test_frame_table_keeps_short_strip_prefix_in_the_fixed_nikon_page() -> None:
    """A short strip keeps its live entries but never shortens SEND(0x8f).

    The 2026-07-22 LS-5000 receipt proves that the firmware rejects the
    otherwise well-formed six-record / 52-byte transfer with 05/26/00.  The
    short-strip preview trace proves that the canonical unused tail is accepted
    with the same physical media.  Retain the six live records used by the
    later autofocus/window commands and fill the remaining page positions from
    that Nikon-accepted tail.
    """

    payload = build_live_frame_table_payload(_mapping(LIVE8_TRANSPORT_FIELDS[:6]))
    canonical = bytes.fromhex(
        next(entry for entry in load_canonical_plan() if entry["seq"] == 174)[
            "data_out"
        ]
    )

    assert payload[:4] == bytes.fromhex("012a2500")
    assert len(payload) == FRAME_TABLE_SEND_BYTES
    assert payload[4 : 4 + 6 * 8] == b"".join(
        struct.pack(">IHH", *field) for field in LIVE8_TRANSPORT_FIELDS[:6]
    )
    assert payload[4 + 6 * 8 :] == canonical[4 + 6 * 8 :]


def test_long_roll_addressable_prefix_is_not_capped_by_the_send_page() -> None:
    """39 proven origins stay selectable; only SEND(0x8f) truncates to 37.

    The 2026-07-25 owner roll: five independent traversals each proved 39
    clean origins, yet every batch refused frame 38 with "outside the
    scanner-addressable table 1..37" -- the page capacity leaking into
    selection legality.  Frame addressing crosses the wire as an absolute
    native origin (dynamic SET_WINDOW / autofocus / GET_WINDOW), never a
    page index, and Nikon Scan scans frame 38+ of the same roll while
    sending the same fixed 300-byte page (observed live, 2026-07-25).
    """

    mapping, records = _short_strip_mapping(39)

    assert len(worker_module._addressable_frame_origins(mapping)) == 39

    payload = build_live_frame_table_payload(mapping)
    assert len(payload) == FRAME_TABLE_SEND_BYTES
    assert payload[:4] == bytes.fromhex("012a2500")
    assert payload[4:] == b"".join(
        struct.pack(">IHH", origin.native_origin, origin.selector, origin.code)
        for origin in mapping.origins[:37]
    )

    adjusted, resolved = apply_batch_boundary_offsets(
        mapping,
        records,
        ((38, 0), (39, 0)),
        approved_manual_slots=frozenset(),
    )
    assert [item[1].frame for item in resolved] == [38, 39]
    assert len(worker_module._addressable_frame_origins(adjusted)) == 39


def test_long_roll_selection_still_stops_at_the_proven_prefix() -> None:
    """The flag-break gate survives the page-cap removal: a long roll whose
    trailing origins are genuinely non-addressable still refuses them."""

    mapping, records = _short_strip_mapping(39, non_addressable_trailing=2)

    with pytest.raises(
        ProtocolError,
        match=r"outside the scanner-addressable table 1\.\.37",
    ):
        apply_batch_boundary_offsets(
            mapping,
            records,
            ((38, 0),),
            approved_manual_slots=frozenset(),
        )


def _with_terminal_sixth_origin(
    mapping: TransportMapping,
) -> TransportMapping:
    terminal = replace(
        mapping.origins[5],
        code=0x8330,
        selector=31,
        native_origin=43_946,
        automatic=False,
        manual_review=True,
        review_reasons=("terminal-transport-tail",),
    )
    return replace(mapping, origins=(*mapping.origins[:5], terminal))


def test_frame_table_stops_before_terminal_transport_tail() -> None:
    mapping, _records = _short_strip_mapping(6)

    payload = build_live_frame_table_payload(_with_terminal_sixth_origin(mapping))
    canonical = bytes.fromhex(
        next(entry for entry in load_canonical_plan() if entry["seq"] == 174)[
            "data_out"
        ]
    )

    assert payload[:4] == bytes.fromhex("012a2500")
    assert len(payload) == FRAME_TABLE_SEND_BYTES
    assert payload[4 + 5 * 8 :] == canonical[4 + 5 * 8 :]


def test_manual_approval_cannot_address_terminal_transport_tail() -> None:
    mapping, records = _short_strip_mapping(6)

    with pytest.raises(ProtocolError, match="terminal transport tail"):
        apply_batch_boundary_offsets(
            _with_terminal_sixth_origin(mapping),
            records,
            ((6, 0),),
            approved_manual_slots=frozenset({6}),
        )


def test_boundary_offset_cannot_enter_terminal_transport_tail() -> None:
    mapping, original_records = _short_strip_mapping(6)
    records = list(original_records)
    for row in range(800, len(records)):
        records[row] = TransportRecord(
            row=row,
            code=0x8330,
            selector=31,
            native_origin=43_946,
        )

    with pytest.raises(ProtocolError, match="resolves into the terminal"):
        apply_boundary_offset(
            mapping,
            records,
            frame=5,
            offset_rows=128,
        )


def test_frame_table_ignores_advisory_slots_after_the_fixed_37_records() -> None:
    extra = (230000, 304, 24)
    payload = build_live_frame_table_payload(_mapping((*LIVE8_TRANSPORT_FIELDS, extra)))

    assert len(payload) == FRAME_TABLE_SEND_BYTES
    assert (
        hashlib.sha256(payload).hexdigest()
        == "b78f6d8a1df1e0d5b242eda27eca88d121a6db2d2e64cf55ae9305142e39fc08"
    )


def test_boundary_offset_resolves_raw_identity_from_the_same_transport_table() -> None:
    mapping, records = _short_strip_mapping(37)

    adjusted, selected, _rebase_info = apply_boundary_offset(
        mapping,
        records,
        frame=18,
        offset_rows=-73,
    )

    assert selected.lookup_row == mapping.origins[17].lookup_row - 73
    source_record = records[selected.lookup_row]
    assert (selected.code, selected.selector, selected.native_origin) == (
        source_record.code,
        source_record.selector,
        source_record.native_origin,
    )
    assert adjusted.origins[17] is selected
    assert selected.automatic is True
    assert adjusted.origins[:17] == mapping.origins[:17]
    assert adjusted.origins[18:] == mapping.origins[18:]


@pytest.mark.parametrize("offset_rows", [-115, 28])
def test_boundary_offset_rejects_interior_high_bit_origin_jump(
    offset_rows: int,
) -> None:
    mapping, original_records = _short_strip_mapping(6)
    records = list(original_records)
    resolved_row = mapping.origins[5].lookup_row + offset_rows
    records[resolved_row] = TransportRecord(
        row=resolved_row,
        code=0x8330,
        selector=31,
        native_origin=43_946,
    )

    with pytest.raises(ProtocolError, match="outside the affine mapping"):
        apply_boundary_offset(
            mapping,
            records,
            frame=6,
            offset_rows=offset_rows,
        )


def test_boundary_offset_accepts_coordinate_valid_interior_high_bit_record() -> None:
    mapping, original_records = _short_strip_mapping(6)
    records = list(original_records)
    resolved_row = 700
    records[resolved_row] = TransportRecord(
        row=resolved_row,
        code=0x8058,
        selector=12,
        native_origin=29_400,
    )

    _adjusted, selected, _rebase_info = apply_boundary_offset(
        mapping,
        records,
        frame=6,
        offset_rows=resolved_row - mapping.origins[5].lookup_row,
    )

    assert selected.lookup_row == resolved_row
    assert selected.native_origin == 29_400
    assert selected.affine_residual_rows == pytest.approx(0.0)


def test_internal_window_decoder_reads_the_fields_the_worker_patches() -> None:
    payload = bytearray(58)
    payload[7] = 50
    payload[8] = 9
    payload[10:14] = bytes.fromhex("0fa00fa0")
    payload[14:18] = (12).to_bytes(4, "big")
    payload[18:22] = (109_060).to_bytes(4, "big")
    payload[22:26] = (3_946).to_bytes(4, "big")
    payload[26:30] = (5_959).to_bytes(4, "big")
    payload[34] = 16
    payload[48] = 0x30
    payload[50] = 0x01
    payload[51] = 0x10
    payload[54:58] = (120_000).to_bytes(4, "big")

    decoded = decode_window_block(payload)

    assert decoded is not None
    assert decoded["color_name"] == "IR"
    assert decoded["upper_left_y"] == 109_060
    assert decoded["width"] == 3_946
    assert decoded["height"] == 5_959
    assert decoded["samples_per_scan_minus1_nibble"] == 3
    assert decoded["is_multi_sample"] is True
    assert decoded["exposure_raw_10ns"] == 120_000
    assert decode_window_block(payload[:-1]) is None


def test_resolved_offset_is_encoded_into_the_selected_fixed_table_record() -> None:
    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    lookup_rows = tuple(100 + 143 * index for index in range(37))
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
        for frame, row in enumerate(lookup_rows, start=1)
    )
    mapping = TransportMapping(
        6_000,
        origins[0].native_origin - 42.0 * origins[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins,
    )

    adjusted, selected, _rebase_info = apply_boundary_offset(
        mapping,
        records,
        frame=18,
        offset_rows=10,
    )
    payload = build_live_frame_table_payload(adjusted)

    encoded = struct.unpack_from(">IHH", payload, 4 + 17 * 8)
    assert encoded == (selected.native_origin, selected.selector, selected.code)
    assert selected.lookup_row == lookup_rows[17] + 10


def test_batch_offsets_share_the_one_retained_table_and_later_frame_origins() -> None:
    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    lookup_rows = tuple(100 + 143 * index for index in range(37))
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
        for frame, row in enumerate(lookup_rows, start=1)
    )
    mapping = TransportMapping(
        6_000,
        origins[0].native_origin - 42.0 * origins[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins,
    )

    combined, resolved = apply_batch_boundary_offsets(
        mapping,
        records,
        ((7, 9), (18, -11), (23, 6)),
    )

    assert [selected.lookup_row for _base, selected, _rebase in resolved] == [
        lookup_rows[6] + 9,
        lookup_rows[17] - 11,
        lookup_rows[22] + 6,
    ]
    plan = load_canonical_plan()
    geometry = _derive_index_geometry(plan)
    bindings = []
    for slot in (7, 18, 23):
        selection = SimpleNamespace(
            frame=slot,
            frame_count=len(combined.origins),
            geometry=geometry,
            mapping=combined,
            selected=combined.origins[slot - 1],
        )
        bindings.append(_bind_plan_to_live_selection(plan, selection))

    # The first and only transmitted frame table already contains every
    # selected frame's operator-adjusted raw transport identity.
    retained_table = bytes.fromhex(bindings[0][173]["data_out"])
    for slot in (7, 18, 23):
        selected = combined.origins[slot - 1]
        assert struct.unpack_from(">IHH", retained_table, 4 + (slot - 1) * 8) == (
            selected.native_origin,
            selected.selector,
            selected.code,
        )

    # Every later continuation binds autofocus and all RGBI windows to the
    # exact same origin already stored in that retained table.
    for slot, bound in zip((7, 18, 23), bindings, strict=True):
        origin = combined.origins[slot - 1].native_origin
        autofocus = bytes.fromhex(bound[230]["data_out"])
        assert int.from_bytes(autofocus[5:9], "big") == origin + 2_979
        for sequence in (
            503,
            504,
            505,
            506,
            530,
            531,
            532,
            533,
            556,
            557,
            558,
            559,
            581,
            582,
            583,
            584,
        ):
            window = decode_window_block(bytes.fromhex(bound[sequence - 1]["data_out"]))
            assert window is not None
            assert window["upper_left_y"] == origin


def test_inferred_batch_origin_requires_its_receipt_bound_operator_approval() -> None:
    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    lookup_rows = tuple(100 + 143 * index for index in range(37))
    origins = tuple(
        NativeFrameOrigin(
            frame=frame,
            boundary_index=frame - 1,
            boundary_output_row=row - 4,
            lookup_row=row,
            code=records[row].code,
            selector=records[row].selector,
            native_origin=records[row].native_origin,
            method=(
                "affine-guided-local-lookup"
                if frame == 18
                else "direct-gap-trailing-row"
            ),
            automatic=frame != 18,
            manual_review=frame == 18,
            review_reasons=(("transport-origin-inferred",) if frame == 18 else ()),
            affine_residual_rows=0.0,
        )
        for frame, row in enumerate(lookup_rows, start=1)
    )
    mapping = TransportMapping(
        6_000,
        origins[0].native_origin - 42.0 * origins[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins,
    )

    with pytest.raises(ProtocolError, match="requires manual review"):
        apply_batch_boundary_offsets(mapping, records, ((18, -11),))

    combined, resolved = apply_batch_boundary_offsets(
        mapping,
        records,
        ((18, -11),),
        approved_manual_slots=frozenset({18}),
    )

    assert resolved[0][0] is origins[17]
    assert resolved[0][1].lookup_row == origins[17].lookup_row - 11
    assert combined.origins[17] is resolved[0][1]


def test_batch_offsets_accept_every_requested_slot_in_a_short_strip_mapping() -> None:
    mapping, records = _short_strip_mapping(6)

    combined, resolved = apply_batch_boundary_offsets(
        mapping, records, ((1, 0), (6, 0))
    )

    assert len(combined.origins) == 6
    assert [selected.frame for _base, selected, _rebase in resolved] == [1, 6]

    bound_plan = load_canonical_plan()
    geometry = _derive_index_geometry(bound_plan)
    for slot in (1, 6):
        selection = SimpleNamespace(
            frame=slot,
            frame_count=len(combined.origins),
            geometry=geometry,
            mapping=combined,
            selected=combined.origins[slot - 1],
        )
        bound = _bind_plan_to_live_selection(bound_plan, selection)

        # The logical six-frame strip must still transmit Nikon's full page;
        # only the first six records are physical and selectable.
        assert bound[173]["cdb"] == "2a008f00000300012c00"
        assert len(bytes.fromhex(bound[173]["data_out"])) == FRAME_TABLE_SEND_BYTES


def test_short_strip_offset_replaces_its_prefix_record_not_the_nikon_tail() -> None:
    mapping, records = _short_strip_mapping(6)

    adjusted, selected, _rebase_info = apply_boundary_offset(
        mapping,
        records,
        frame=6,
        offset_rows=-1,
    )
    payload = build_live_frame_table_payload(adjusted)
    canonical = bytes.fromhex(
        next(entry for entry in load_canonical_plan() if entry["seq"] == 174)[
            "data_out"
        ]
    )

    assert struct.unpack_from(">IHH", payload, 4 + 5 * 8) == (
        selected.native_origin,
        selected.selector,
        selected.code,
    )
    assert payload[4 + 6 * 8 :] == canonical[4 + 6 * 8 :]


def test_batch_offsets_refuse_a_requested_slot_beyond_the_addressable_short_table() -> (
    None
):
    # 7 candidate origins, but the 7th lies outside the index raster the same
    # way a real detector would flag an inflated preview candidate -- so the
    # scanner-addressable table this mapping can produce is only 1..6, even
    # though frame 7 exists structurally in `mapping.origins`.
    mapping, records = _short_strip_mapping(7, non_addressable_trailing=1)

    with pytest.raises(
        ProtocolError,
        match=r"requested frame 7 is outside the scanner-addressable table 1\.\.6",
    ):
        apply_batch_boundary_offsets(mapping, records, ((7, 0),))


def test_fresh_batch_index_refuses_a_different_roll_before_plan_binding(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    frame_height = 20
    intervals = tuple(
        (slot * frame_height, (slot + 1) * frame_height) for slot in range(37)
    )
    reviewed_frames = []
    for slot in range(37):
        rng = np.random.default_rng(20_000 + slot)
        reviewed_frames.append(
            np.repeat(
                np.repeat(
                    rng.integers(2_000, 50_000, size=(10, 10, 3), dtype=np.uint16),
                    2,
                    axis=0,
                ),
                2,
                axis=1,
            )
        )
    reviewed_rgb = np.concatenate(reviewed_frames, axis=0)
    fresh_rgb = np.concatenate(list(reversed(reviewed_frames)), axis=0)
    records = tuple(
        TransportRecord(
            row=row,
            code=6 * (row % 18),
            selector=row // 18,
            native_origin=42 * row,
        )
        for row in range(6_000)
    )
    lookup_rows = tuple(100 + 143 * index for index in range(37))
    origins = tuple(
        NativeFrameOrigin(
            frame=frame,
            boundary_index=frame - 1,
            boundary_output_row=intervals[frame - 1][0],
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
        for frame, row in enumerate(lookup_rows, start=1)
    )
    mapping = TransportMapping(
        6_000,
        origins[0].native_origin - 42.0 * origins[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins,
    )
    reviewed = build_reviewed_roll_fingerprint(
        reviewed_rgb,
        frame_intervals=intervals,
        frame_native_origins=tuple(origin.native_origin for origin in origins),
        source_preview_sha256="1" * 64,
        source_table_sha256="2" * 64,
    )
    geometry = SimpleNamespace(
        requested_resolution=97,
        native_resolution=4_000,
        pitch=41,
        native_width=3_946,
        native_height=250_278,
        width=20,
        height=len(fresh_rgb),
        block_bytes=1,
        expected_stream_bytes=1,
    )
    detection = SimpleNamespace(
        confidence="high",
        intervals=tuple(
            SimpleNamespace(start_row=start, end_row=end) for start, end in intervals
        ),
        boundaries=(),
        diagnostics=lambda: {},
    )
    frame_root = tmp_path / "batch"
    frame = worker_module.BatchFrameSpec(
        slot=17,
        boundary_offset_rows=0,
        manual_review_approval=None,
        output=frame_root / "frame-017" / "capture.bin",
        journal=frame_root / "frame-017" / "journal.json",
        ack=frame_root / "frame-017" / "parent-ack.json",
    )
    monkeypatch.setattr(worker_module, "_derive_index_geometry", lambda _plan: geometry)
    monkeypatch.setattr(
        worker_module,
        "validate_live_0x8e_bytes",
        lambda table, _height: (table, len(fresh_rgb)),
    )
    monkeypatch.setattr(
        worker_module,
        "decode_full_index_bytes",
        lambda *_args, **_kwargs: (
            fresh_rgb,
            np.ones(len(fresh_rgb), dtype=bool),
            {},
        ),
    )
    monkeypatch.setattr(
        worker_module, "detect_roll_frames", lambda *_args, **_kwargs: detection
    )
    monkeypatch.setattr(
        worker_module,
        "parse_live_transport_records_bytes",
        lambda *_args, **_kwargs: records,
    )
    monkeypatch.setattr(
        worker_module, "derive_transport_mapping", lambda *_args, **_kwargs: mapping
    )

    with pytest.raises(ProtocolError, match="reviewed roll fingerprint"):
        worker_module._derive_live_batch_selections(
            [],
            b"fresh-preview",
            b"fresh-table",
            (frame,),
            reviewed_fingerprint=reviewed,
        )


def test_batch_selected_slot_gate_runs_for_every_slot_before_plan_binding(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    reviewed = _reviewed_fingerprint()
    fresh = _reviewed_fingerprint()
    context = SimpleNamespace(
        fresh_fingerprint=fresh,
        fingerprint_comparison=worker_module.compare_reviewed_roll_fingerprints(
            reviewed,
            fresh,
        ),
    )
    frame_root = tmp_path / "selected-slot-gate"
    frames = tuple(
        worker_module.BatchFrameSpec(
            slot=slot,
            boundary_offset_rows=0,
            manual_review_approval=None,
            output=frame_root / f"frame-{slot:03d}" / "capture.bin",
            journal=frame_root / f"frame-{slot:03d}" / "journal.json",
            ack=frame_root / f"frame-{slot:03d}" / "parent-ack.json",
        )
        for slot in (7, 17)
    )
    checked: list[int] = []
    plan_bound = False

    def compare_selected(
        _reviewed: ReviewedRollFingerprint,
        _fresh: ReviewedRollFingerprint,
        *,
        slot: int,
    ) -> SimpleNamespace:
        checked.append(slot)
        return SimpleNamespace(
            matches=slot != 17,
            reason=("matched" if slot != 17 else "selected-visual-content-mismatch"),
        )

    def bind_plan(*_args: object, **_kwargs: object) -> None:
        nonlocal plan_bound
        plan_bound = True

    monkeypatch.setattr(
        worker_module,
        "_derive_live_frame_selection",
        lambda *_args, **_kwargs: context,
    )
    monkeypatch.setattr(
        worker_module,
        "compare_selected_roll_fingerprint",
        compare_selected,
        raising=False,
    )
    monkeypatch.setattr(worker_module, "_bind_plan_to_live_selection", bind_plan)

    with pytest.raises(
        ProtocolError,
        match="selected frame 17.*selected-visual-content-mismatch",
    ):
        worker_module._derive_live_batch_selections(
            [],
            b"fresh-preview",
            b"fresh-table",
            frames,
            reviewed_fingerprint=reviewed,
        )

    assert checked == [7, 17]
    assert plan_bound is False


def _batch_selection_context(
    mapping: TransportMapping,
    records: tuple[TransportRecord, ...],
    reviewed: ReviewedRollFingerprint,
) -> SimpleNamespace:
    fresh = reviewed
    return SimpleNamespace(
        mapping=mapping,
        geometry=SimpleNamespace(height=len(records), native_height=1_000_000),
        usable_rows=0,
        detection=None,
        preview_sha256="a" * 64,
        table_sha256="b" * 64,
        decode_report={},
        reviewed_fingerprint_sha256=reviewed.binding_sha256,
        fresh_fingerprint=fresh,
        fingerprint_comparison=worker_module.compare_reviewed_roll_fingerprints(
            reviewed, fresh
        ),
    )


def _one_slot_batch(
    tmp_path: Path, root_name: str, slot: int
) -> tuple[worker_module.BatchFrameSpec, ...]:
    frame_root = tmp_path / root_name
    return (
        worker_module.BatchFrameSpec(
            slot=slot,
            boundary_offset_rows=0,
            manual_review_approval=None,
            output=frame_root / f"frame-{slot:03d}" / "capture.bin",
            journal=frame_root / f"frame-{slot:03d}" / "journal.json",
            ack=frame_root / f"frame-{slot:03d}" / "parent-ack.json",
        ),
    )


def test_batch_selections_refuse_when_live_table_count_is_far_above_reviewed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The comparison is one-directional: a live count above the reviewed
    # count by more than the one-frame sliver tolerance has no benign
    # explanation and must still be refused, even though a live count below
    # the reviewed count is tolerated without limit elsewhere in this suite.
    mapping, records = _short_strip_mapping(9)
    reviewed = _reviewed_fingerprint_with_count(6)
    context = _batch_selection_context(mapping, records, reviewed)
    frames = _one_slot_batch(tmp_path, "far-from-reviewed", 1)

    monkeypatch.setattr(
        worker_module, "_derive_live_frame_selection", lambda *_a, **_k: context
    )
    monkeypatch.setattr(
        worker_module,
        "compare_selected_roll_fingerprint",
        lambda *_a, **_k: SimpleNamespace(matches=True, reason="matched"),
        raising=False,
    )
    monkeypatch.setattr(
        worker_module,
        "validate_live_0x8e_bytes",
        lambda table, _height: (table, len(records)),
    )
    monkeypatch.setattr(
        worker_module,
        "parse_live_transport_records_bytes",
        lambda *_a, **_k: records,
    )

    with pytest.raises(
        ProtocolError,
        match=r"live table has 9 scanner-addressable frame records, more than "
        r"one above the 6",
    ):
        worker_module._derive_live_batch_selections(
            [],
            b"fresh-preview",
            b"fresh-table",
            frames,
            reviewed_fingerprint=reviewed,
        )


def test_batch_selections_accept_one_addressable_sliver_beyond_reviewed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The live table has one more addressable record than the reviewed
    # fingerprint described -- exactly the shape of a trailing sliver that
    # was too short to visually sign on the reviewed traversal but is still
    # an addressable transport slot on this one.
    mapping, records = _short_strip_mapping(7)
    reviewed = _reviewed_fingerprint_with_count(6)
    context = _batch_selection_context(mapping, records, reviewed)
    frames = _one_slot_batch(tmp_path, "one-sliver-beyond-reviewed", 1)
    bound_frames: list[int] = []

    monkeypatch.setattr(
        worker_module, "_derive_live_frame_selection", lambda *_a, **_k: context
    )
    monkeypatch.setattr(
        worker_module,
        "compare_selected_roll_fingerprint",
        lambda *_a, **_k: SimpleNamespace(matches=True, reason="matched"),
        raising=False,
    )
    monkeypatch.setattr(
        worker_module,
        "validate_live_0x8e_bytes",
        lambda table, _height: (table, len(records)),
    )
    monkeypatch.setattr(
        worker_module,
        "parse_live_transport_records_bytes",
        lambda *_a, **_k: records,
    )
    monkeypatch.setattr(
        worker_module,
        "_bind_plan_to_live_selection",
        lambda _plan, selection: bound_frames.append(selection.frame),
    )

    selections = worker_module._derive_live_batch_selections(
        [],
        b"fresh-preview",
        b"fresh-table",
        frames,
        reviewed_fingerprint=reviewed,
    )

    assert [selection.frame for selection in selections] == [1]
    assert bound_frames == [1]


def test_batch_selections_accept_a_live_count_several_frames_below_reviewed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Regression: a live batch run over slots 3 and 20 of a reviewed
    # 40-frame roll, where the transport's trailing edge cleared the feeder
    # a few frames before the end and every record built from that jump was
    # excluded as unaddressable -- leaving 37 scanner-addressable records
    # against the reviewed fingerprint's 40. 0.1.3's plus-or-minus-one
    # comparison refused this batch outright even though both requested
    # slots were well within the addressable table; a live count several
    # frames below the reviewed count is the ordinary shape of a roll
    # ending, not a sign of a wrong or reordered roll, and must succeed.
    mapping, records = _short_strip_mapping(40, non_addressable_trailing=3)
    assert build_live_frame_table_payload(mapping)[2] == 37
    reviewed = _reviewed_fingerprint_with_count(40)
    context = _batch_selection_context(mapping, records, reviewed)
    frame_root = tmp_path / "several-below-reviewed"
    frames = tuple(
        worker_module.BatchFrameSpec(
            slot=slot,
            boundary_offset_rows=0,
            manual_review_approval=None,
            output=frame_root / f"frame-{slot:03d}" / "capture.bin",
            journal=frame_root / f"frame-{slot:03d}" / "journal.json",
            ack=frame_root / f"frame-{slot:03d}" / "parent-ack.json",
        )
        for slot in (3, 20)
    )
    bound_frames: list[int] = []

    monkeypatch.setattr(
        worker_module, "_derive_live_frame_selection", lambda *_a, **_k: context
    )
    monkeypatch.setattr(
        worker_module,
        "compare_selected_roll_fingerprint",
        lambda *_a, **_k: SimpleNamespace(matches=True, reason="matched"),
        raising=False,
    )
    monkeypatch.setattr(
        worker_module,
        "validate_live_0x8e_bytes",
        lambda table, _height: (table, len(records)),
    )
    monkeypatch.setattr(
        worker_module,
        "parse_live_transport_records_bytes",
        lambda *_a, **_k: records,
    )
    monkeypatch.setattr(
        worker_module,
        "_bind_plan_to_live_selection",
        lambda _plan, selection: bound_frames.append(selection.frame),
    )

    selections = worker_module._derive_live_batch_selections(
        [],
        b"fresh-preview",
        b"fresh-table",
        frames,
        reviewed_fingerprint=reviewed,
    )

    assert [selection.frame for selection in selections] == [3, 20]
    assert bound_frames == [3, 20]


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


def test_nikon_parity_calculation_failure_refuses_the_fine_scan(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Since the guarded parity solve became the RGB command authority, a
    calculation failure must refuse the fine scan — never fall back silently
    to the active solve — and must journal exactly what refused."""

    journal: dict[str, object] = {}
    monkeypatch.setattr(
        worker_module,
        "calculate_nikon_parity_shadow",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            ValueError("diagnostic fixture failure")
        ),
    )

    final_result = SimpleNamespace(
        final_exposures=dict(worker_module.DEFAULT_EXPOSURES)
    )
    with pytest.raises(
        worker_module.SynchronizedProtocolError, match="nikon-parity"
    ):
        worker_module._resolve_parity_active_exposures(
            journal,
            observation=_synthetic_meter_observation(),
            final_result=final_result,
        )

    assert journal["meter_shadow_profiles"] == {
        "nikon-parity": {
            "profile": "nikon-parity",
            "status": "calculation-error",
            "armed": False,
            "scanner_route": "none",
            "error": {
                "type": "ValueError",
                "message": "diagnostic fixture failure",
            },
        }
    }
    assert "active_exposure_authority" not in journal


def test_continuation_executor_runs_all_89_steps_with_fake_usb(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
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
    mapping = TransportMapping(
        6_000,
        origins[0].native_origin - 42.0 * origins[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins,
    )
    combined, _resolved = apply_batch_boundary_offsets(
        mapping,
        records,
        ((7, 9), (18, -11)),
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
    canonical_target = worker_module.validate_plan(plan)
    tiny_target = {
        **canonical_target,
        "repeat": 1,
        "request_len": 1,
        "request_parts": [1],
    }
    monkeypatch.setattr(worker_module, "EXPECTED_FINE_READS", 1)
    monkeypatch.setattr(worker_module, "METER_GROUP_BYTES", 5)
    monkeypatch.setattr(worker_module, "METER_CAPTURE_BYTES", 15)
    monkeypatch.setattr(worker_module, "validate_plan", lambda _plan: tiny_target)
    ready_groups: list[tuple[int, ...]] = []
    transactions: list[int] = []

    def ready(
        _ep_out: object,
        _ep_in: object,
        entries: list[dict],
        **_kwargs: object,
    ) -> tuple[int, int]:
        ready_groups.append(tuple(entry["seq"] for entry in entries))
        return 1, 0

    def perform(
        _ep_out: object,
        _ep_in: object,
        entry: dict,
        **_kwargs: object,
    ) -> TransactionResult:
        sequence = entry["seq"]
        transactions.append(sequence)
        if sequence in (
            *worker_module.METER_GET_WINDOW_SEQUENCES,
            *worker_module.FINE_GET_WINDOW_SEQUENCES,
        ):
            payload = bytes.fromhex(entry["expected_data_in"])
        elif sequence in worker_module.METER_READ_SEQUENCES or sequence == 607:
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
    monkeypatch.setattr(worker_module, "_perform_ready_group", ready)
    monkeypatch.setattr(worker_module, "_perform_with_busy_retry", perform)
    monkeypatch.setattr(
        worker_module,
        "observe_meter_pass",
        lambda *_args, **_kwargs: _synthetic_meter_observation(),
    )
    monkeypatch.setattr(
        worker_module,
        "propose_next_exposures",
        lambda *_args, **_kwargs: accepted_proposal,
    )
    monkeypatch.setattr(
        worker_module,
        "verify_final_convergence",
        lambda *_args, **_kwargs: accepted_final,
    )
    monkeypatch.setattr(
        worker_module,
        "_wait_post_scan_ready",
        lambda *_args, **_kwargs: (1, 0),
    )
    density_evidence = SimpleNamespace(
        source_binding=SimpleNamespace(session_id=batch.session_id)
    )
    monkeypatch.setattr(
        worker_module,
        "_density_frame_ownership_receipt",
        lambda *_args, **_kwargs: {"fixture": "owned"},
    )

    with pytest.raises(ProtocolError, match="another reservation"):
        worker_module._run_live_continuation_frame(
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
            density_calibration=_density_calibration("another-reservation"),
            density_evidence=density_evidence,
            actual_usb_bus=1,
            actual_usb_address=2,
        )
    assert not second.output.parent.exists()

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

    assert len(ready_groups) == 15
    assert len(transactions) - 1 + len(ready_groups) == 89
    assert 174 not in transactions
    assert 500 not in transactions
    assert transactions[-1] == 607
    assert journal["status"] == "frame-complete"
    assert journal["frame_complete"] is True
    assert journal["session_reservation_retained"] is True
    assert journal["unit_released"] is False
    assert journal["density_calibration_session_id"] == batch.session_id
    shadow = journal["meter_shadow_profiles"]["nikon-parity"]
    assert shadow["armed"] is True
    assert shadow["scanner_route"] == "fine-rgb-set-window"
    assert (
        shadow["infrared"]["current_metered_exposure_raw_10ns"]
        == worker_module.DEFAULT_EXPOSURES["IR"]
    )
    candidate_rgb = shadow["candidate_rgb_exposures_raw_10ns"]
    assert candidate_rgb != {
        channel: worker_module.DEFAULT_EXPOSURES[channel]
        for channel in ("R", "G", "B")
    }
    # The guarded parity candidates (after the journaled device-bound clamp)
    # ARE the commanded fine RGB exposures; infrared stays with the active
    # controller.
    authority = journal["active_exposure_authority"]
    assert authority["rgb_source"] == "nikon-parity-guarded-v2"
    assert authority["ir_source"] == "active-controller"
    commanded = authority["commanded_channels_raw_10ns"]
    for channel in ("R", "G", "B"):
        assert commanded[channel] == min(
            max(candidate_rgb[channel], worker_module.EXPOSURE_MIN),
            worker_module.EXPOSURE_MAX,
        )
    assert {
        window["color_id"]: window["exposure_raw_10ns"]
        for window in journal["fine_windows"]
    } == {
        1: commanded["R"],
        2: commanded["G"],
        3: commanded["B"],
        9: worker_module.DEFAULT_EXPOSURES["IR"],
    }
    assert second.output.read_bytes() == b"x"
    assert second.journal.read_text(encoding="utf-8") == (
        json.dumps(journal, indent=2, sort_keys=True) + "\n"
    )


def test_live_two_frame_batch_uses_one_combined_table_and_one_release(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    plan = load_canonical_plan()
    canonical_target = worker_module.validate_plan(plan)
    tiny_target = {
        **canonical_target,
        "repeat": 1,
        "request_len": 1,
        "request_parts": [1],
    }
    for sequence in worker_module.PREVIEW_READ_SEQUENCES:
        entry = plan[sequence - 1]
        entry["request_len"] = 1
        entry["request_parts"] = [1]

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
    base_mapping = TransportMapping(
        6_000,
        origins[0].native_origin - 42.0 * origins[0].boundary_output_row,
        42.0,
        0.0,
        0.0,
        origins,
    )
    combined, resolved = apply_batch_boundary_offsets(
        base_mapping,
        records,
        ((7, 9), (18, -11)),
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

    def selection_for(
        slot: int,
        offset: int,
        pair: tuple[NativeFrameOrigin, NativeFrameOrigin],
    ) -> SimpleNamespace:
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
            diagnostics=lambda: {
                "frame": slot,
                "boundary_offset": {
                    "requested_rows": offset,
                    "applied_rows": offset,
                },
                "selected": {
                    "frame": slot,
                    "lookup_row": selected.lookup_row,
                    "native_origin": selected.native_origin,
                },
            },
        )

    selections = (
        selection_for(7, 9, resolved[0]),
        selection_for(18, -11, resolved[1]),
    )
    root = tmp_path / "successful-batch"
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
        "successful-batch",
        root,
        (first, second),
        _reviewed_fingerprint(),
        1,
        2,
        CANONICAL_PLAN_SHA256,
        worker_module.CANONICAL_CONTINUATION_PLAN_SHA256,
        "c" * 64,
    )
    nonce = "offline-batch-nonce"
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

    startup = _startup_frame_table(40)
    header_8e = b"\0\x8e\0\0\0\x06"
    prevalidated = False
    reserves: list[int] = []
    sent_tables: list[bytes] = []
    transactions: list[int] = []
    fine_reads: list[int] = []
    ready_groups: list[tuple[int, ...]] = []
    ack_boundaries: list[tuple[int, int, int, int]] = []
    releases: list[tuple[object, object]] = []
    usb_events: list[str] = []

    class USBUtil:
        @staticmethod
        def release_interface(_device: object, _number: int) -> None:
            usb_events.append("interface-released")

        @staticmethod
        def dispose_resources(_device: object) -> None:
            usb_events.append("resources-disposed")

    ep_out = SimpleNamespace(bEndpointAddress=0x01)
    ep_in = SimpleNamespace(bEndpointAddress=0x82)
    interface = SimpleNamespace(bInterfaceNumber=0)

    def derive_batch(
        _plan: list[dict],
        preview: bytes,
        table: bytes,
        frames: tuple[worker_module.BatchFrameSpec, ...],
        *,
        reviewed_fingerprint: ReviewedRollFingerprint,
    ) -> tuple[SimpleNamespace, ...]:
        nonlocal prevalidated
        assert len(preview) == len(worker_module.PREVIEW_READ_SEQUENCES)
        assert table == header_8e
        assert frames == batch.frames
        assert reviewed_fingerprint == batch.reviewed_fingerprint
        prevalidated = True
        return selections

    def perform(
        _ep_out: object,
        _ep_in: object,
        entry: dict,
        **_kwargs: object,
    ) -> TransactionResult:
        sequence = entry["seq"]
        transactions.append(sequence)
        if sequence == 17:
            reserves.append(sequence)
        if sequence == 174:
            assert prevalidated is True
            sent_tables.append(bytes.fromhex(entry["data_out"]))
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
            fine_reads.append(sequence)
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

    def perform_startup(
        _ep_out: object,
        _ep_in: object,
        entry: dict,
        **_kwargs: object,
    ) -> TransactionResult:
        assert entry["seq"] == worker_module.VARIABLE_FRAME_TABLE_SEQUENCE
        return TransactionResult(
            phase=3,
            payload=startup,
            status=bytes(8),
            sense="000000",
            stall_recoveries=0,
        )

    def ready(
        _ep_out: object,
        _ep_in: object,
        entries: list[dict],
        **_kwargs: object,
    ) -> tuple[int, int]:
        ready_groups.append(tuple(entry["seq"] for entry in entries))
        return 1, 0

    real_wait_for_parent_ack = worker_module.wait_for_parent_ack

    def acknowledge(
        path: Path,
        *,
        session_id: str,
        frame_index: int,
        slot: int,
        nonce: str,
        timeout_seconds: float = 1_800.0,
        poll_seconds: float = 0.1,
    ) -> str:
        del timeout_seconds, poll_seconds
        ack_boundaries.append((frame_index, slot, len(transactions), len(ready_groups)))
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

    def release(ep_out_value: object, ep_in_value: object) -> TransactionResult:
        releases.append((ep_out_value, ep_in_value))
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
    monkeypatch.setattr(worker_module, "EXPECTED_FINE_READS", 1)
    monkeypatch.setattr(
        worker_module,
        "EXPECTED_PREVIEW_BYTES",
        len(worker_module.PREVIEW_READ_SEQUENCES),
    )
    monkeypatch.setattr(worker_module, "METER_GROUP_BYTES", 5)
    monkeypatch.setattr(worker_module, "METER_CAPTURE_BYTES", 15)
    monkeypatch.setattr(worker_module, "validate_plan", lambda _plan: tiny_target)
    monkeypatch.setattr(worker_module, "_derive_index_geometry", lambda _plan: geometry)
    monkeypatch.setattr(
        worker_module, "_validate_scanner_identity", lambda _payload: None
    )
    monkeypatch.setattr(
        worker_module, "_validate_live_preview_windows", lambda *_args: preview_windows
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
    monkeypatch.setattr(
        worker_module, "_wait_post_scan_ready", lambda *_args, **_kwargs: (1, 0)
    )
    monkeypatch.setattr(
        worker_module,
        "observe_meter_pass",
        lambda *_args, **_kwargs: _synthetic_meter_observation(),
    )
    monkeypatch.setattr(
        worker_module,
        "propose_next_exposures",
        lambda *_args, **_kwargs: accepted_proposal,
    )
    monkeypatch.setattr(
        worker_module,
        "verify_final_convergence",
        lambda *_args, **_kwargs: accepted_final,
    )
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

    session_journal_path = root / "session-journal.json"
    worker_module.run_live_capture(
        plan,
        tmp_path / "plan.jsonl",
        CANONICAL_PLAN_SHA256,
        first.output,
        first.journal,
        1,
        frame=first.slot,
        boundary_offset_rows=first.boundary_offset_rows,
        batch_job=batch,
        continuation_plan=load_canonical_continuation_plan(),
        continuation_plan_sha256=(worker_module.CANONICAL_CONTINUATION_PLAN_SHA256),
        session_journal_path=session_journal_path,
    )

    assert reserves == [17]
    assert len(sent_tables) == 1
    retained_table = sent_tables[0]
    for slot in (7, 18):
        origin = combined.origins[slot - 1]
        assert struct.unpack_from(">IHH", retained_table, 4 + (slot - 1) * 8) == (
            origin.native_origin,
            origin.selector,
            origin.code,
        )
    assert fine_reads == [607, 607]
    assert [(frame, slot) for frame, slot, _tx, _ready in ack_boundaries] == [
        (1, 7),
        (2, 18),
    ]
    first_boundary = ack_boundaries[0]
    second_boundary = ack_boundaries[1]
    continuation_transactions = second_boundary[2] - first_boundary[2]
    continuation_ready_groups = second_boundary[3] - first_boundary[3]
    assert continuation_transactions - 1 + continuation_ready_groups == 89
    assert 174 not in transactions[first_boundary[2] : second_boundary[2]]
    assert releases == [(ep_out, ep_in)]
    first_receipt = json.loads(first.journal.read_text(encoding="utf-8"))
    assert first_receipt["status"] == "frame-complete"
    assert first_receipt["live_startup_0x8f"]["count"] == 40
    assert first_receipt["live_startup_0x8f_status"] == "0000000000000000"
    assert first_receipt["live_startup_0x8f_short_underrun_accepted"] is False
    assert first_receipt["session_reservation_retained"] is True
    assert first_receipt["unit_released"] is False
    assert first_receipt["nikon_density_calibration"]["numerators_rgb"] == [
        57_980,
        48_356,
        32_854,
    ]
    assert first_receipt["nikon_density_calibration"]["payload_hex_rgb"] == [
        "8c20000000040000e27c",
        "8c20000000040000bce4",
        "8c200000000400008056",
    ]
    assert first_receipt["nikon_density_calibration"]["session_id"] == (
        batch.session_id
    )
    assert first_receipt["density_calibration_session_id"] == batch.session_id
    first_shadow = first_receipt["meter_shadow_profiles"]["nikon-parity"]
    assert first_shadow["armed"] is True
    assert first_shadow["scanner_route"] == "fine-rgb-set-window"
    second_receipt = json.loads(second.journal.read_text(encoding="utf-8"))
    assert second_receipt["status"] == "frame-complete"
    assert second_receipt["batch_session"] == {
        "frame_index": 2,
        "frame_total": 2,
        "selected_slots": [7, 18],
        "session_id": batch.session_id,
    }
    assert second_receipt["continuation_plan_sha256"] == (
        worker_module.CANONICAL_CONTINUATION_PLAN_SHA256
    )
    assert second_receipt["session_reservation_retained"] is True
    assert second_receipt["unit_released"] is False
    assert (
        second_receipt["nikon_density_calibration"]
        == first_receipt["nikon_density_calibration"]
    )
    assert second_receipt["density_calibration_session_id"] == batch.session_id
    second_shadow = second_receipt["meter_shadow_profiles"]["nikon-parity"]
    assert second_shadow["armed"] is True
    assert second_shadow["scanner_route"] == "fine-rgb-set-window"
    assert (
        first_shadow["candidate_rgb_exposures_raw_10ns"]
        == second_shadow["candidate_rgb_exposures_raw_10ns"]
    )
    for receipt, shadow in (
        (first_receipt, first_shadow),
        (second_receipt, second_shadow),
    ):
        candidate_rgb = shadow["candidate_rgb_exposures_raw_10ns"]
        assert candidate_rgb != {
            channel: worker_module.DEFAULT_EXPOSURES[channel]
            for channel in ("R", "G", "B")
        }
        # Guarded parity candidates (after the journaled device-bound clamp)
        # command the fine RGB windows; infrared stays with the active
        # controller's solve.
        authority = receipt["active_exposure_authority"]
        assert authority["rgb_source"] == "nikon-parity-guarded-v2"
        assert authority["ir_source"] == "active-controller"
        commanded = authority["commanded_channels_raw_10ns"]
        for channel in ("R", "G", "B"):
            assert commanded[channel] == min(
                max(candidate_rgb[channel], worker_module.EXPOSURE_MIN),
                worker_module.EXPOSURE_MAX,
            )
        assert {
            window["color_id"]: window["exposure_raw_10ns"]
            for window in receipt["fine_windows"]
        } == {
            1: commanded["R"],
            2: commanded["G"],
            3: commanded["B"],
            9: worker_module.DEFAULT_EXPOSURES["IR"],
        }
    assert second.output.read_bytes() == b"f"
    session = json.loads(session_journal_path.read_text(encoding="utf-8"))
    assert session["status"] == "complete"
    assert session["completed_slots"] == [7, 18]
    assert session["reservation_acquired"] is True
    assert session["unit_release_attempts"] == 1
    assert session["unit_released"] is True
    assert session["recovery_required"] == "none"
    assert session["batch_job_sha256"] == batch.job_sha256
    assert session["capture_engine_sha256"] == worker_module.CAPTURE_WORKER_SHA256
    assert session["capture_bundle_sha256"] == worker_module.CAPTURE_BUNDLE_SHA256
    assert (
        session["nikon_density_calibration"]
        == first_receipt["nikon_density_calibration"]
    )
    assert session["density_calibration_session_id"] == batch.session_id
    assert usb_events == ["interface-released", "resources-disposed"]


# ---------------------------------------------------------------------------
# Active RGB exposure authority: guarded nikon-parity candidates command the
# fine scan; infrared stays with the active controller; nothing but the
# guarded per-channel value can ever reach a scanner window.
# ---------------------------------------------------------------------------

from coolscanpy.protocol.ls5000_single_pass.meter import (  # noqa: E402
    DEFAULT_EXPOSURES as _PARITY_DEFAULT_EXPOSURES,
    METER_ROWS as _PARITY_METER_ROWS,
    METER_TAIL_SAMPLES as _PARITY_METER_TAIL_SAMPLES,
    METER_WIDTH as _PARITY_METER_WIDTH,
    EXPOSURE_MAX as _PARITY_EXPOSURE_MAX,
    NikonParityShadowChannel,
    NikonParityShadowResult,
    observe_meter_pass as _parity_observe_meter_pass,
)


def _parity_meter_payload() -> bytes:
    # Near-converged brightness: high enough that the reviewed-high guard cap
    # stays inside the scanner's exposure bounds, like a real pass-3 raster.
    yy, xx = np.mgrid[0:_PARITY_METER_ROWS, 0:_PARITY_METER_WIDTH]
    field = 0.06 + 0.94 * (
        0.53 * xx / (_PARITY_METER_WIDTH - 1) + 0.47 * yy / (_PARITY_METER_ROWS - 1)
    )
    image = np.empty((_PARITY_METER_ROWS, _PARITY_METER_WIDTH, 4), dtype=np.uint16)
    for channel, peak in enumerate((60_000, 59_000, 61_500, 55_000)):
        image[:, :, channel] = np.round(900 + peak * field).astype(np.uint16)
    rows = np.zeros((_PARITY_METER_ROWS, 1280), dtype=">u2")
    rows[:, :1124] = image.transpose(0, 2, 1).reshape(_PARITY_METER_ROWS, 1124)
    tails = (
        np.arange(_PARITY_METER_ROWS * _PARITY_METER_TAIL_SAMPLES, dtype=np.uint32)
        % 65536
    )
    rows[:, 1124:] = tails.reshape(_PARITY_METER_ROWS, _PARITY_METER_TAIL_SAMPLES)
    return rows.tobytes()


def _parity_final_result(exposures: dict[str, int]):
    return SimpleNamespace(final_exposures=dict(exposures))


def _crafted_parity_channel(
    channel: str, *, guarded: int, uncapped: int, active: int
) -> NikonParityShadowChannel:
    return NikonParityShadowChannel(
        channel=channel,
        target_fraction=0.95,
        observed_central_fraction=0.9,
        pass_3_exposure_raw_10ns=active,
        current_metered_exposure_raw_10ns=active,
        candidate_exposure_raw_10ns=guarded,
        uncapped_candidate_exposure_raw_10ns=uncapped,
        reviewed_high_guard_cap_raw_10ns=guarded,
        uncapped_update_ratio=uncapped / active,
        update_ratio=guarded / active,
        uncapped_predicted_full_high=67_000.0,
        predicted_full_high=64_000.0,
        limiting_reason="reviewed-high-q99_99-64880-guard",
        active_controller_limiting_reason="none-active-controller-limit",
    )


def _crafted_parity_result(
    *, guarded: dict[str, int], uncapped: dict[str, int], active: dict[str, int]
) -> NikonParityShadowResult:
    return NikonParityShadowResult(
        current_metered_exposures=tuple(
            (channel, active[channel]) for channel in ("R", "G", "B", "IR")
        ),
        channels=tuple(
            _crafted_parity_channel(
                channel,
                guarded=guarded[channel],
                uncapped=uncapped[channel],
                active=active[channel],
            )
            for channel in ("R", "G", "B")
        ),
        source_observation_hashes=(("meter_pass_sha256", "0" * 64),),
    )


def test_active_rgb_commands_are_guarded_parity_and_ir_is_active() -> None:
    observation = _parity_observe_meter_pass(
        _parity_meter_payload(), _PARITY_DEFAULT_EXPOSURES
    )
    active = {"R": 97_000, "G": 194_000, "B": 177_000, "IR": 283_000}
    journal: dict = {}

    commanded = worker_module._resolve_parity_active_exposures(
        journal,
        observation=observation,
        final_result=_parity_final_result(active),
    )

    profile = journal["meter_shadow_profiles"]["nikon-parity"]
    assert profile["armed"] is True
    assert profile["mode"] == "active-rgb-authority"
    assert profile["scanner_route"] == "fine-rgb-set-window"
    for channel in ("R", "G", "B"):
        assert commanded[channel] == profile["candidate_rgb_exposures_raw_10ns"][channel]
    assert commanded["IR"] == active["IR"]
    authority = journal["active_exposure_authority"]
    assert authority["rgb_source"] == "nikon-parity-guarded-v2"
    assert authority["ir_source"] == "active-controller"
    assert authority["commanded_channels_raw_10ns"] == commanded
    assert authority["active_controller_channels_raw_10ns"] == active


def test_active_rgb_commands_never_use_the_uncapped_diagnostic(monkeypatch) -> None:
    guarded = {"R": 110_000, "G": 300_000, "B": 350_000}
    uncapped = {"R": 130_000, "G": 340_000, "B": 397_000}
    active = {"R": 100_000, "G": 280_000, "B": 330_000, "IR": 283_000}
    crafted = _crafted_parity_result(guarded=guarded, uncapped=uncapped, active=active)
    monkeypatch.setattr(
        worker_module, "calculate_nikon_parity_shadow", lambda *a, **k: crafted
    )
    journal: dict = {}

    commanded = worker_module._resolve_parity_active_exposures(
        journal,
        observation=object(),
        final_result=_parity_final_result(active),
    )

    for channel in ("R", "G", "B"):
        assert commanded[channel] == guarded[channel]
        assert commanded[channel] != uncapped[channel]
    assert commanded["IR"] == active["IR"]
    profile = journal["meter_shadow_profiles"]["nikon-parity"]
    assert (
        profile["uncapped_nikon_like_rgb_exposures_raw_10ns"]["B"] == uncapped["B"]
    )  # journaled for diagnostics, never commanded


def test_guarded_candidate_outside_scanner_bounds_is_clamped_and_journaled(
    monkeypatch,
) -> None:
    """A guarded candidate past the device contract clamps to the bound —
    one more named guard, so dim frames stay scannable — and the clamp is
    journaled.  The uncapped diagnostic still never reaches the command."""

    guarded = {"R": 110_000, "G": 300_000, "B": _PARITY_EXPOSURE_MAX + 1}
    uncapped = {"R": 130_000, "G": 340_000, "B": _PARITY_EXPOSURE_MAX + 5_000}
    active = {"R": 100_000, "G": 280_000, "B": 330_000, "IR": 283_000}
    crafted = _crafted_parity_result(guarded=guarded, uncapped=uncapped, active=active)
    monkeypatch.setattr(
        worker_module, "calculate_nikon_parity_shadow", lambda *a, **k: crafted
    )
    journal: dict = {}

    commanded = worker_module._resolve_parity_active_exposures(
        journal,
        observation=object(),
        final_result=_parity_final_result(active),
    )

    assert commanded["B"] == _PARITY_EXPOSURE_MAX
    assert commanded["R"] == guarded["R"]
    assert commanded["G"] == guarded["G"]
    assert commanded["IR"] == active["IR"]
    for channel in ("R", "G", "B"):
        assert commanded[channel] != uncapped[channel]
    authority = journal["active_exposure_authority"]
    assert authority["device_bound_clamped_channels_raw_10ns"] == {
        "B": _PARITY_EXPOSURE_MAX + 1
    }
    assert authority["device_exposure_bounds_raw_10ns"] == [
        worker_module.EXPOSURE_MIN,
        worker_module.EXPOSURE_MAX,
    ]
