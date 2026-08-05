"""Synthetic contracts for the LS-5000 streaming decoder and fail-open sidecar.

Covers the streaming ``StreamingFrameDecoder`` (arbitrary fragmentation,
exact-length enforcement, fail-closed padding, byte-for-byte offline
equivalence, bounded staging, no partial reveal), the generic
``FailOpenStreamConsumer`` (nonblocking bounded submission, fail-open on
consumer failure), and the LS-5000 ``FineStreamSession`` advisory publication.
All fixtures are synthetic; no hardware and no committed image are involved.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
from pathlib import Path

import numpy as np
import pytest

from coolscanpy.protocol.ls5000_single_pass.packed import (
    FULL_IR_BYTE_OFFSET,
    FULL_RECORD_BYTES,
    FULL_RECORD_WORDS,
    FULL_RGB_SAMPLE_BYTE_OFFSETS,
    UNIT_WORDS,
    WIDTH,
    StreamingFrameDecoder,
    decode_full_records,
)
from coolscanpy.protocol.ls5000_single_pass.streaming_sidecar import (
    DEFAULT_FINISH_TIMEOUT_SECONDS,
    STREAM_DATA_SUFFIX,
    STREAM_RECEIPT_KEYS,
    STREAM_RECEIPT_SUFFIX,
    FailOpenStreamConsumer,
    FineStreamSession,
)
from coolscanpy.protocol.ls5000_single_pass import streaming_sidecar as sidecar_module


def _counter_train(words: np.ndarray, first_counter: int) -> None:
    words[0::2] = 0xAA55
    words[1::2] = (first_counter + np.arange(words.size // 2, dtype=np.uint32)) & 0xFFFF


def _e9ea_prefixed_counter_train(words: np.ndarray) -> None:
    words[:4] = (0xE9EA, 0xE9EA, 0xE9EA, 0xD894)
    _counter_train(words[4:], 0xD895)


def _e004_prefixed_counter_train(words: np.ndarray) -> None:
    words[:4] = (0xE004, 0xE004, 0xE004, 0xD894)
    _counter_train(words[4:], 0xD895)


def _dc4c_prefixed_counter_train(words: np.ndarray) -> None:
    words[:4] = (0xDC4C, 0xDC4C, 0xDC4C, 0xD894)
    _counter_train(words[4:], 0xD895)


def _synthetic_full_records(height: int = 3) -> tuple[np.ndarray, np.ndarray]:
    records = (height + 1) // 2
    base = (
        np.arange(records * 2 * WIDTH * 4, dtype=np.uint32).reshape(records * 2, WIDTH, 4) % 20_000
    ).astype(np.uint16)
    wire_rows = np.concatenate(
        [base[:height, ::-1], np.zeros((records * 2 - height, WIDTH, 4), dtype=np.uint16)],
        axis=0,
    )
    paired = wire_rows.reshape(records, 2, WIDTH, 4)
    full = np.zeros((records, FULL_RECORD_WORDS), dtype=np.uint16)
    for sample, byte_offsets in enumerate(FULL_RGB_SAMPLE_BYTE_OFFSETS):
        for channel, byte_offset in enumerate(byte_offsets):
            unit = paired[..., channel].transpose(0, 2, 1).reshape(records, UNIT_WORDS)
            full[:, byte_offset // 2 : byte_offset // 2 + UNIT_WORDS] = unit + sample
    ir_unit = paired[..., 3].transpose(0, 2, 1).reshape(records, UNIT_WORDS)
    ir_start = FULL_IR_BYTE_OFFSET // 2
    full[:, ir_start : ir_start + UNIT_WORDS] = ir_unit
    for record in full:
        _counter_train(record[63_136 // 2 : 63_488 // 2], 0xE7FD)
        _counter_train(record[110_840 // 2 : 111_616 // 2], 0xD893)
        record[158_968 // 2 : 159_744 // 2] = record[ir_start : ir_start + 388]
        _counter_train(record[207_096 // 2 : 207_872 // 2], 0xD893)
    return base[:height], full


def _stream_bytes(height: int = 3) -> tuple[np.ndarray, bytes]:
    base, full = _synthetic_full_records(height)
    return base, full.astype(">u2").tobytes()


def _feed(decoder: StreamingFrameDecoder, stream: bytes, chunk: int) -> None:
    if chunk >= len(stream):
        decoder.push(stream)
        return
    for offset in range(0, len(stream), chunk):
        decoder.push(stream[offset : offset + chunk])


class TestStreamingFrameDecoder:
    def test_matches_offline_decode_byte_for_byte(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        path = tmp_path / "capture.bin"
        path.write_bytes(stream)
        offline, _ = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        decoder.push(stream)
        decoded, layout = decoder.finish()

        np.testing.assert_array_equal(offline, decoded)
        assert layout["padding_validated_records"] == 2
        assert layout["rgb_samples_decoded"] == 4
        assert layout["ir_planes_transferred"] == 1
        assert layout["rgb_average"] == "round-half-up uint16 average"

    @pytest.mark.parametrize(
        "chunk",
        [7, 4095, 4096, 65_535, 207_871, 207_872, 207_873, 10_000_000],
    )
    def test_arbitrary_fragmentation_is_equivalent(self, tmp_path: Path, chunk: int) -> None:
        _base, stream = _stream_bytes(height=3)
        path = tmp_path / "capture.bin"
        path.write_bytes(stream)
        offline, _ = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        _feed(decoder, stream, chunk)
        decoded, _ = decoder.finish()

        np.testing.assert_array_equal(offline, decoded)

    def test_byte_at_a_time_is_equivalent(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        path = tmp_path / "capture.bin"
        path.write_bytes(stream)
        offline, _ = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        for byte in stream:
            decoder.push(bytes([byte]))
        decoded, _ = decoder.finish()

        np.testing.assert_array_equal(offline, decoded)
        assert decoder.max_staged_bytes <= FULL_RECORD_BYTES

    def test_record_boundary_splits_are_equivalent(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        path = tmp_path / "capture.bin"
        path.write_bytes(stream)
        offline, _ = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        decoder.push(stream[:FULL_RECORD_BYTES])
        decoder.push(stream[FULL_RECORD_BYTES:])
        decoded, _ = decoder.finish()

        np.testing.assert_array_equal(offline, decoded)

    def test_e9ea_prefixed_padding_counter_dialect_is_accepted(self) -> None:
        base, full = _synthetic_full_records(height=3)
        for record in full:
            _e9ea_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
            _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
        decoder = StreamingFrameDecoder(height=3)

        _feed(decoder, full.astype(">u2").tobytes(), 65_535)
        decoded, layout = decoder.finish()

        expected = base.copy()
        expected[..., :3] += 2
        np.testing.assert_array_equal(expected, decoded)
        assert layout["padding_validated_records"] == 2

    def test_e004_prefixed_padding_counter_dialect_is_accepted(self) -> None:
        base, full = _synthetic_full_records(height=3)
        for record in full:
            _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
            _e004_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
        decoder = StreamingFrameDecoder(height=3)

        _feed(decoder, full.astype(">u2").tobytes(), 65_535)
        decoded, layout = decoder.finish()

        expected = base.copy()
        expected[..., :3] += 2
        np.testing.assert_array_equal(expected, decoded)
        assert layout["padding_validated_records"] == 2

    def test_e004_prefixed_stream_matches_offline_decode_byte_for_byte(
        self, tmp_path: Path
    ) -> None:
        _base, full = _synthetic_full_records(height=3)
        for record in full:
            _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
            _e004_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
        stream = full.astype(">u2").tobytes()
        path = tmp_path / "e004-capture.bin"
        path.write_bytes(stream)
        offline, offline_report = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        _feed(decoder, stream, 4_096)
        decoded, _ = decoder.finish()

        np.testing.assert_array_equal(offline, decoded)
        assert offline_report["padding_1_3_counter_dialect"] == "e004-prefixed"

    def test_dc4c_prefixed_stream_matches_offline_decode_byte_for_byte(
        self, tmp_path: Path
    ) -> None:
        _base, full = _synthetic_full_records(height=3)
        for record in full:
            _dc4c_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
            _dc4c_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
        stream = full.astype(">u2").tobytes()
        path = tmp_path / "dc4c-capture.bin"
        path.write_bytes(stream)
        offline, offline_report = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        _feed(decoder, stream, 4_096)
        decoded, _ = decoder.finish()

        np.testing.assert_array_equal(offline, decoded)
        assert offline_report["padding_1_3_counter_dialect"] == "dc4c-prefixed"

    @pytest.mark.parametrize(
        "corrupt_word_offset,match",
        [
            (110_840 // 2, "padding 1 counter train mismatch"),
            (110_840 // 2 + 4, "padding 1 counter train mismatch"),
            (207_096 // 2, "padding 3 counter train mismatch"),
            (207_872 // 2 - 1, "padding 3 counter train mismatch"),
        ],
        ids=["pad1-sentinel", "pad1-train-head", "pad3-sentinel", "pad3-train-tail"],
    )
    def test_corrupt_e004_prefixed_padding_fails_closed(
        self, corrupt_word_offset: int, match: str
    ) -> None:
        _base, full = _synthetic_full_records(height=5)  # 3 records
        for record in full:
            _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
            _e004_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
        full[1, corrupt_word_offset] ^= 1
        stream = full.astype(">u2").tobytes()
        decoder = StreamingFrameDecoder(height=5)
        with pytest.raises(ValueError, match=match):
            _feed(decoder, stream, 65_535)

    def test_mixed_e004_and_e9ea_padding_dialects_fail_closed(self) -> None:
        _base, full = _synthetic_full_records(height=3)
        for record in full:
            _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
            _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
        decoder = StreamingFrameDecoder(height=3)
        with pytest.raises(ValueError, match="padding 3 counter train mismatch"):
            _feed(decoder, full.astype(">u2").tobytes(), 65_535)

    def test_empty_pushes_are_no_ops(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        path = tmp_path / "capture.bin"
        path.write_bytes(stream)
        offline, _ = decode_full_records(path, height=3)

        decoder = StreamingFrameDecoder(height=3)
        decoder.push(b"")
        decoder.push(stream[:100])
        decoder.push(b"")
        decoder.push(stream[100:])
        decoder.push(b"")
        decoded, _ = decoder.finish()

        assert decoder.received == len(stream)
        np.testing.assert_array_equal(offline, decoded)

    def test_extra_bytes_overrun_is_refused_mid_push(self) -> None:
        _base, stream = _stream_bytes(height=3)
        decoder = StreamingFrameDecoder(height=3)
        with pytest.raises(ValueError, match="overruns"):
            decoder.push(stream + b"\x00")

    def test_trailing_extra_byte_after_complete_stream_is_refused(self) -> None:
        _base, stream = _stream_bytes(height=3)
        decoder = StreamingFrameDecoder(height=3)
        decoder.push(stream)
        with pytest.raises(ValueError, match="overruns"):
            decoder.push(b"\x00")

    def test_short_finish_one_record_short_is_refused(self) -> None:
        _base, stream = _stream_bytes(height=3)
        decoder = StreamingFrameDecoder(height=3)
        decoder.push(stream[:FULL_RECORD_BYTES])  # 1 of 2 records
        with pytest.raises(ValueError, match="expected"):
            decoder.finish()

    def test_short_finish_one_byte_short_is_refused(self) -> None:
        _base, stream = _stream_bytes(height=3)
        decoder = StreamingFrameDecoder(height=3)
        decoder.push(stream[:-1])
        with pytest.raises(ValueError, match="expected"):
            decoder.finish()

    @pytest.mark.parametrize("region_word,match", [
        (63_136 // 2, "padding 0 counter train mismatch"),
        (110_840 // 2, "padding 1 counter train mismatch"),
        (158_968 // 2, "padding 2 is not the expected IR-head copy"),
        (207_096 // 2, "padding 3 counter train mismatch"),
    ])
    @pytest.mark.parametrize("record_index", [0, 1, 2], ids=["early", "middle", "late"])
    def test_corrupt_padding_fails_closed_anywhere(
        self, region_word: int, match: str, record_index: int
    ) -> None:
        _base, full = _synthetic_full_records(height=5)  # 3 records
        full[record_index, region_word] ^= 1
        stream = full.astype(">u2").tobytes()
        decoder = StreamingFrameDecoder(height=5)
        with pytest.raises(ValueError, match=match):
            _feed(decoder, stream, 65_535)

    def test_no_partial_result_is_revealed_on_late_corruption(self) -> None:
        _base, full = _synthetic_full_records(height=5)  # 3 records
        full[2, 63_136 // 2] ^= 1  # corrupt the late record
        stream = full.astype(">u2").tobytes()
        decoder = StreamingFrameDecoder(height=5)
        # First two records decode into the private buffer without revealing it.
        decoder.push(stream[: 2 * FULL_RECORD_BYTES])
        with pytest.raises(ValueError, match="padding 0"):
            decoder.push(stream[2 * FULL_RECORD_BYTES :])
        assert not decoder.finished
        with pytest.raises(ValueError):
            decoder.finish()

    def test_trailing_surplus_row_is_dropped_for_odd_height(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=5)  # 3 records -> 6 slots, keep 5
        path = tmp_path / "capture.bin"
        path.write_bytes(stream)
        offline, _ = decode_full_records(path, height=5)

        decoder = StreamingFrameDecoder(height=5)
        decoder.push(stream)
        decoded, _ = decoder.finish()

        assert decoded.shape == (5, WIDTH, 4)
        np.testing.assert_array_equal(offline, decoded)

    def test_staging_never_exceeds_one_record(self) -> None:
        _base, stream = _stream_bytes(height=3)
        for chunk in (1, 7, 4096, 207_871, 207_872, 207_873):
            decoder = StreamingFrameDecoder(height=3)
            _feed(decoder, stream, chunk)
            decoder.finish()
            assert 0 < decoder.max_staged_bytes <= FULL_RECORD_BYTES

    def test_decoder_is_single_use_with_no_reset(self) -> None:
        _base, stream = _stream_bytes(height=3)
        decoder = StreamingFrameDecoder(height=3)
        assert not hasattr(decoder, "reset")
        decoder.push(stream)
        decoder.finish()
        with pytest.raises(ValueError, match="push after finish"):
            decoder.push(stream)
        with pytest.raises(ValueError, match="finish already called"):
            decoder.finish()

    def test_rejects_nonstandard_width(self) -> None:
        with pytest.raises(ValueError, match="width"):
            StreamingFrameDecoder(width=WIDTH + 1)


class _ToyDecoder:
    def __init__(
        self,
        *,
        fail_on_push: int | None = None,
        fail_on_finish: bool = False,
        block_event: threading.Event | None = None,
    ) -> None:
        self.chunks: list[bytes] = []
        self.fail_on_push = fail_on_push
        self.fail_on_finish = fail_on_finish
        self.block_event = block_event

    def push(self, chunk: bytes) -> None:
        if self.block_event is not None:
            self.block_event.wait()
        if self.fail_on_push is not None and len(self.chunks) >= self.fail_on_push:
            raise ValueError("boom-push")
        self.chunks.append(bytes(chunk))

    def finish(self) -> bytes:
        if self.fail_on_finish:
            raise ValueError("boom-finish")
        return b"".join(self.chunks)


class TestFailOpenStreamConsumer:
    def test_successful_finish_returns_decoder_result(self) -> None:
        consumer = FailOpenStreamConsumer(_ToyDecoder, max_queue=4)
        for chunk in (b"ab", b"cd", b"ef"):
            assert consumer.submit(chunk) is True
        assert consumer.seal(5.0) is True
        assert consumer.result(timeout=5.0) == b"abcdef"
        assert not consumer.failed
        assert not consumer.disabled

    def test_submit_is_nonblocking_and_bounded_under_slow_consumer(self) -> None:
        block = threading.Event()  # consumer wedges on its first push
        consumer = FailOpenStreamConsumer(
            lambda: _ToyDecoder(block_event=block), max_queue=2
        )
        submitted = 0
        start = time.monotonic()
        for _ in range(50):
            if consumer.submit(b"xxxxxxxx"):
                submitted += 1
            else:
                break
        elapsed = time.monotonic() - start

        assert elapsed < 2.0, "producer blocked on a stuck consumer"
        assert submitted < 50, "backpressure never engaged"
        assert consumer.disabled
        # Permanent for this frame: even after the consumer is released.
        block.set()
        time.sleep(0.1)
        assert consumer.submit(b"again") is False

    def test_consumer_failure_disables_and_never_propagates(self) -> None:
        consumer = FailOpenStreamConsumer(lambda: _ToyDecoder(fail_on_push=2), max_queue=8)
        for index in range(6):
            consumer.submit(b"chunk%d" % index)
        deadline = time.monotonic() + 5.0
        while not consumer.failed and time.monotonic() < deadline:
            time.sleep(0.01)
        assert consumer.failed
        assert consumer.submit(b"more") is False
        assert consumer.seal(2.0) is False
        assert consumer.result(timeout=2.0) is None

    def test_failed_finish_reports_failure_not_exception(self) -> None:
        consumer = FailOpenStreamConsumer(
            lambda: _ToyDecoder(fail_on_finish=True), max_queue=4
        )
        assert consumer.submit(b"x") is True
        assert consumer.seal(5.0) is True
        assert consumer.result(timeout=5.0) is None
        assert consumer.failed

    def test_result_before_seal_is_none(self) -> None:
        consumer = FailOpenStreamConsumer(_ToyDecoder, max_queue=4)
        consumer.submit(b"x")
        assert consumer.result(timeout=0.2) is None

    def test_disable_abandons_consumer_without_blocking_caller(self) -> None:
        block = threading.Event()
        consumer = FailOpenStreamConsumer(lambda: _ToyDecoder(block_event=block), max_queue=2)
        consumer.submit(b"x")  # starts the consumer; it wedges inside push
        time.sleep(0.1)  # let it actually enter push
        start = time.monotonic()
        consumer.disable("test")
        # disable returns promptly and unblocks the producer.  It cannot
        # interrupt a decoder already wedged inside push -- the daemon may be
        # abandoned -- so we only assert the caller is never blocked.
        assert time.monotonic() - start < 1.0
        assert consumer.disabled
        assert consumer.submit(b"more") is False
        assert consumer.result(timeout=0.2) is None
        block.set()  # release the abandoned daemon so it can exit

    def test_seal_on_a_wedged_consumer_is_bounded(self) -> None:
        block = threading.Event()
        consumer = FailOpenStreamConsumer(lambda: _ToyDecoder(block_event=block), max_queue=1)
        consumer.submit(b"x")  # consumer wedges inside push
        consumer.submit(b"y")  # fills the 1-slot queue
        start = time.monotonic()
        assert consumer.seal(timeout=0.4) is False  # queue stays full; bounded wait
        elapsed = time.monotonic() - start
        assert elapsed < 2.0
        assert consumer.disabled
        block.set()

    def test_released_memoryview_is_fail_open(self) -> None:
        consumer = FailOpenStreamConsumer(_ToyDecoder, max_queue=1)
        view = memoryview(bytearray(b"mutable"))
        view.release()

        assert consumer.submit(view) is False
        assert consumer.disabled

    def test_mutable_submission_is_frozen_before_queueing(self) -> None:
        block = threading.Event()
        consumer = FailOpenStreamConsumer(
            lambda: _ToyDecoder(block_event=block),
            max_queue=4,
        )
        first = bytearray(b"first")
        second = bytearray(b"second")
        assert consumer.submit(first)
        assert consumer.submit(second)
        first[:] = b"XXXXX"
        second[:] = b"YYYYYY"
        block.set()
        assert consumer.seal(2.0)
        assert consumer.result(2.0) == b"firstsecond"


def _stream_paths(tmp_path: Path) -> tuple[Path, Path, Path]:
    capture = tmp_path / "capture.bin"
    return (
        capture,
        tmp_path / f"capture.bin{STREAM_DATA_SUFFIX}",
        tmp_path / f"capture.bin{STREAM_RECEIPT_SUFFIX}",
    )


def _feed_session(session: FineStreamSession, stream: bytes) -> None:
    for offset in range(0, len(stream), FULL_RECORD_BYTES):
        session.submit(stream[offset : offset + FULL_RECORD_BYTES])


class _BlockingDecoder:
    """A decoder that wedges inside ``push`` to exercise bounded deadlines."""

    def __init__(self, block: threading.Event) -> None:
        self._block = block

    def __call__(self, *, height: int, width: int, out=None, validate_padding: bool = True):
        return self

    def push(self, _chunk) -> None:
        self._block.wait(timeout=10)

    def finish(self):  # pragma: no cover - only reached after the block is set
        raise ValueError("never reached")


class _WriteAfterTimeoutDecoder:
    def __init__(
        self,
        *,
        out: np.ndarray,
        entered: threading.Event,
        release: threading.Event,
        wrote_after_release: threading.Event,
    ) -> None:
        self._out = out
        self._entered = entered
        self._release = release
        self._wrote_after_release = wrote_after_release

    def push(self, _chunk: bytes) -> None:
        self._out.flat[0] = 1
        self._entered.set()
        self._release.wait(timeout=10)
        # This write occurs after FineStreamSession.finish has timed out. It
        # would crash or corrupt the worker if finish closed the live mmap.
        self._out.flat[0] = 2
        self._wrote_after_release.set()

    def finish(self):  # pragma: no cover - stop is observed before the sentinel
        raise AssertionError("abandoned decoder must not finish")


class _ProofDecoder:
    def __init__(self, out: np.ndarray, proof: dict[str, object]) -> None:
        self._out = out
        self._proof = proof

    def push(self, _chunk: bytes) -> None:
        self._out.fill(7)

    def finish(self):
        return self._out, self._proof


class TestFineStreamSession:
    def test_publishes_bound_artifact_and_receipt_only_on_success(
        self, tmp_path: Path
    ) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        capture.write_bytes(stream)
        raw_sha = hashlib.sha256(stream).hexdigest()

        session = FineStreamSession(capture, height=3, max_queue=4)
        _feed_session(session, stream)
        result = session.finish(raw_sha256=raw_sha, raw_bytes=len(stream))

        assert result["status"] == "ok"
        assert data_path.is_file()
        assert receipt_path.is_file()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert set(receipt) == STREAM_RECEIPT_KEYS
        assert receipt["kind"] == "negpy.ls5000-stream-receipt"
        assert receipt["version"] == 1
        assert receipt["status"] == "complete"
        assert receipt["dtype"] == "uint16"
        assert receipt["derived_filename"] == data_path.name
        assert receipt["raw_sha256"] == raw_sha
        assert receipt["raw_bytes"] == len(stream)
        assert receipt["height"] == 3
        assert receipt["width"] == WIDTH
        assert receipt["channels"] == 4
        assert receipt["derived_sha256"] == hashlib.sha256(
            data_path.read_bytes()
        ).hexdigest()
        assert receipt["derived_bytes"] == data_path.stat().st_size
        layout = receipt["layout"]
        assert layout["padding_validated_records"] == 2
        assert layout["rgb_samples_decoded"] == 4
        assert layout["ir_planes_transferred"] == 1
        # A streamed decode, not a committed final image.
        assert not list(tmp_path.glob("*.tif"))

    def test_persisted_artifact_matches_offline_decode_byte_for_byte(
        self, tmp_path: Path
    ) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, _receipt = _stream_paths(tmp_path)
        capture.write_bytes(stream)
        raw_sha = hashlib.sha256(stream).hexdigest()

        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        assert session.finish(raw_sha256=raw_sha, raw_bytes=len(stream))["status"] == "ok"

        persisted = np.load(data_path, allow_pickle=False)
        offline, _ = decode_full_records(capture, height=3)
        np.testing.assert_array_equal(persisted, offline)

    def test_no_leftover_temp_files_on_success(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, _data, _receipt = _stream_paths(tmp_path)
        capture.write_bytes(stream)
        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(), raw_bytes=len(stream)
        )
        assert not [p for p in tmp_path.iterdir() if p.name.endswith(".tmp")]

    def test_success_is_terminal_and_repeat_finish_preserves_publication(
        self, tmp_path: Path
    ) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        first = session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(),
            raw_bytes=len(stream),
        )
        data_sha = hashlib.sha256(data_path.read_bytes()).hexdigest()
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        session.submit(b"must be ignored after terminal success")
        second = session.finish(raw_sha256="0" * 64, raw_bytes=0)

        assert second == first
        assert hashlib.sha256(data_path.read_bytes()).hexdigest() == data_sha
        assert hashlib.sha256(receipt_path.read_bytes()).hexdigest() == receipt_sha

    def test_abort_after_success_retracts_unjournaled_publication(
        self, tmp_path: Path
    ) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        assert session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(),
            raw_bytes=len(stream),
        )["status"] == "ok"

        first = session.abort("journal-write-failed")
        second = session.abort("ignored-repeat")

        assert first == second
        assert first["status"] == "abandoned"
        assert not receipt_path.exists()
        assert not data_path.exists()

    def test_receipt_collision_is_refused_not_claimed(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        capture.write_bytes(stream)
        stale = b'{"stale": true}'
        receipt_path.write_bytes(stale)

        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        result = session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(), raw_bytes=len(stream)
        )

        assert result["status"] == "abandoned"
        assert result["reason"] == "receipt-collision"
        # The stale receipt is untouched and our (now-orphaned) data is cleaned.
        assert receipt_path.read_bytes() == stale
        assert not data_path.exists()

    def test_data_collision_is_refused_not_claimed(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        capture.write_bytes(stream)
        data_path.write_bytes(b"stale-derived")

        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        result = session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(), raw_bytes=len(stream)
        )

        assert result["status"] == "abandoned"
        assert result["reason"] == "data-collision"
        # The pre-existing data file is not overwritten; no receipt is written.
        assert data_path.read_bytes() == b"stale-derived"
        assert not receipt_path.exists()

    def test_no_receipt_and_clean_scratch_on_padding_failure(
        self, tmp_path: Path
    ) -> None:
        _base, full = _synthetic_full_records(height=3)
        full[1, 63_136 // 2] ^= 1
        stream = full.astype(">u2").tobytes()
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        capture.write_bytes(stream)

        session = FineStreamSession(capture, height=3)
        _feed_session(session, stream)
        result = session.finish(raw_sha256="f" * 64, raw_bytes=len(stream))

        assert result["status"] == "abandoned"
        assert not receipt_path.exists()
        assert not data_path.exists()
        assert not list(tmp_path.glob("*.tif"))
        assert not [p for p in tmp_path.iterdir() if p.name.endswith(".tmp")]

    def test_no_receipt_on_short_stream(self, tmp_path: Path) -> None:
        _base, stream = _stream_bytes(height=3)
        capture, data_path, receipt_path = _stream_paths(tmp_path)

        session = FineStreamSession(capture, height=3)
        session.submit(stream[:FULL_RECORD_BYTES])  # 1 of 2 records
        result = session.finish(raw_sha256="0" * 64, raw_bytes=len(stream))

        assert result["status"] == "abandoned"
        assert not receipt_path.exists()
        assert not data_path.exists()

    def test_submit_never_raises_after_consumer_failure(self, tmp_path: Path) -> None:
        capture, _data, _receipt = _stream_paths(tmp_path)
        session = FineStreamSession(capture, height=3)
        assert session._consumer is not None
        session._consumer.disable("test")
        session.submit(b"anything at all")  # must not raise
        result = session.finish(raw_sha256="0" * 64, raw_bytes=0)
        assert result["status"] == "abandoned"

    def test_submit_never_raises_when_consumer_raises_sync(
        self, tmp_path: Path
    ) -> None:
        capture, _data, _receipt = _stream_paths(tmp_path)
        session = FineStreamSession(capture, height=3)
        assert session._consumer is not None

        def _boom(_chunk: object) -> bool:
            raise RuntimeError("synchronous decoder explosion")

        session._consumer.submit = _boom  # type: ignore[method-assign]
        session.submit(b"payload")  # must swallow the synchronous exception
        assert not session.active

    def test_disabled_session_publishes_nothing(self, tmp_path: Path) -> None:
        capture, _data, receipt_path = _stream_paths(tmp_path)
        session = FineStreamSession(capture, height=3, enabled=False)
        session.submit(b"x")
        result = session.finish(raw_sha256="0" * 64, raw_bytes=0)
        assert result["status"] == "disabled"
        assert not receipt_path.exists()

    def test_finish_deadline_is_bounded_and_abandons_a_stuck_consumer(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        block = threading.Event()
        blocker = _BlockingDecoder(block)
        monkeypatch.setattr(sidecar_module, "StreamingFrameDecoder", blocker)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        _base, stream = _stream_bytes(height=3)

        session = FineStreamSession(capture, height=3, max_queue=1, finish_timeout_seconds=0.4)
        session.submit(stream[:FULL_RECORD_BYTES])
        start = time.monotonic()
        result = session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(), raw_bytes=len(stream)
        )
        elapsed = time.monotonic() - start
        block.set()

        assert result["status"] == "abandoned"
        assert elapsed < 1.0, "finish exceeded its single configured deadline"
        assert not receipt_path.exists()
        assert not data_path.exists()

    def test_timeout_never_closes_a_mapping_still_used_by_decoder(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        entered = threading.Event()
        release = threading.Event()
        wrote_after_release = threading.Event()

        def decoder_factory(*, height, width, out, validate_padding=True):
            return _WriteAfterTimeoutDecoder(
                out=out,
                entered=entered,
                release=release,
                wrote_after_release=wrote_after_release,
            )

        monkeypatch.setattr(sidecar_module, "StreamingFrameDecoder", decoder_factory)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        _base, stream = _stream_bytes(height=3)
        session = FineStreamSession(
            capture,
            height=3,
            max_queue=2,
            finish_timeout_seconds=0.15,
        )
        session.submit(stream[:FULL_RECORD_BYTES])
        assert entered.wait(2.0)

        start = time.monotonic()
        result = session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(),
            raw_bytes=len(stream),
        )
        assert time.monotonic() - start < 0.8
        assert result["status"] == "abandoned"
        assert not data_path.exists()
        assert not receipt_path.exists()

        release.set()
        assert wrote_after_release.wait(2.0), "post-timeout mmap write was not safe"
        deadline = time.monotonic() + 2.0
        while list(tmp_path.glob(".*.tmp")) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert not list(tmp_path.glob(".*.tmp"))

    @pytest.mark.parametrize("raw_bytes", [True, 415744.0, "415744"])
    def test_raw_byte_binding_requires_an_exact_integer_type(
        self, tmp_path: Path, raw_bytes: object
    ) -> None:
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        session = FineStreamSession(capture, height=3)

        result = session.finish(raw_sha256="a" * 64, raw_bytes=raw_bytes)  # type: ignore[arg-type]

        assert result["reason"] == "raw-bytes-invalid"
        assert not data_path.exists()
        assert not receipt_path.exists()

    @pytest.mark.parametrize(
        "proof",
        [
            {},
            {
                "padding_validated_records": 2,
                "rgb_samples_decoded": 4,
                "ir_planes_transferred": True,
                "rgb_average": "round-half-up uint16 average",
            },
            {
                "padding_validated_records": 2,
                "rgb_samples_decoded": 4,
                "ir_planes_transferred": 1,
                "rgb_average": "different rounding",
            },
        ],
    )
    def test_publisher_never_invents_or_coerces_decode_proof(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
        proof: dict[str, object],
    ) -> None:
        def decoder_factory(*, height, width, out, validate_padding=True):
            return _ProofDecoder(out, proof)

        monkeypatch.setattr(sidecar_module, "StreamingFrameDecoder", decoder_factory)
        capture, data_path, receipt_path = _stream_paths(tmp_path)
        _base, stream = _stream_bytes(height=3)
        session = FineStreamSession(capture, height=3)
        session.submit(stream)

        result = session.finish(
            raw_sha256=hashlib.sha256(stream).hexdigest(),
            raw_bytes=len(stream),
        )

        assert result["reason"] == "invalid-decode-proof"
        assert not data_path.exists()
        assert not receipt_path.exists()


def test_default_finish_timeout_is_materially_below_legacy_60s() -> None:
    assert DEFAULT_FINISH_TIMEOUT_SECONDS < 60.0
