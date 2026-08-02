"""Decode Nikon LS-5000 single-pass RGBI4x fine records.

Both inputs are supported:

* 65,508-byte USBPcap prefixes (2,980 records), and
* complete 207,872-byte live responses (2,980 records).

The full live response contains four distinct RGB samples and one transferred
IR plane.  RGB is averaged round-half-up; IR is emitted unchanged.  Prefix
captures contain only the first RGB sample plus IR and remain supported for
wire/reference validation.

`StreamingFrameDecoder` adds an incremental path over the same 207,872-byte
full records: it accepts arbitrarily fragmented chunks, stages at most one
record, and produces output byte-identical to `decode_full_records` for the
same stream, so a live capture can be decoded as it arrives while the durable
raw stream remains the offline oracle.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np


WIDTH = 3_946
HEIGHT = 5_959
CHANNELS = 4
RGB_CHANNELS = 3
ROWS_PER_RECORD = 2
EXPECTED_RECORDS = (HEIGHT + 1) // 2
PREFIX_RECORD_BYTES = 65_508
FULL_RECORD_BYTES = 207_872
CORE_WORDS = WIDTH * CHANNELS * ROWS_PER_RECORD
CORE_BYTES = CORE_WORDS * 2
UNIT_WORDS = WIDTH * ROWS_PER_RECORD
UNIT_BYTES = UNIT_WORDS * 2
FULL_RECORD_WORDS = FULL_RECORD_BYTES // 2

# Half-open byte offsets established by the complete run-10 capture.
FULL_RGB_SAMPLE_BYTE_OFFSETS = (
    (0, 15_784, 31_568),
    (63_488, 79_272, 95_056),
    (111_616, 127_400, 143_184),
    (159_744, 175_528, 191_312),
)
FULL_IR_BYTE_OFFSET = 47_352
FULL_PADDING_BYTE_RANGES = (
    (63_136, 63_488),
    (110_840, 111_616),
    (158_968, 159_744),
    (207_096, 207_872),
)

# Word-grained views of the byte offsets above, shared by the batch and the
# streaming decode kernels so both produce byte-identical output.
FULL_RGB_SAMPLE_WORD_OFFSETS = tuple(
    tuple(offset // 2 for offset in sample_offsets)
    for sample_offsets in FULL_RGB_SAMPLE_BYTE_OFFSETS
)
FULL_IR_WORD_OFFSET = FULL_IR_BYTE_OFFSET // 2


def infer_record_geometry(path: Path, records: int = EXPECTED_RECORDS) -> int:
    size = path.stat().st_size
    if size % records:
        raise ValueError(f"stream size {size} is not divisible by {records} records")
    record_bytes = size // records
    if record_bytes not in (PREFIX_RECORD_BYTES, FULL_RECORD_BYTES):
        raise ValueError(f"record size {record_bytes} is neither {PREFIX_RECORD_BYTES} nor {FULL_RECORD_BYTES}")
    return record_bytes


def decode_core_records(
    path: Path,
    *,
    record_bytes: int,
    width: int = WIDTH,
    height: int = HEIGHT,
    channels: int = CHANNELS,
) -> np.ndarray:
    records = (height + 1) // 2
    expected_size = records * record_bytes
    if path.stat().st_size != expected_size:
        raise ValueError(f"stream has {path.stat().st_size} bytes, expected {expected_size}")
    core_words = width * channels * ROWS_PER_RECORD
    core_bytes = core_words * 2
    if record_bytes < core_bytes:
        raise ValueError(f"record {record_bytes} is shorter than core {core_bytes}")

    raw = np.memmap(path, dtype=np.uint8, mode="r", shape=(records, record_bytes))
    words = raw[:, :core_bytes].view(">u2")
    paired = words.reshape(records, channels, width, ROWS_PER_RECORD)
    rows = paired.transpose(0, 3, 2, 1).reshape(-1, width, channels)
    # The clean oracle exposes 5,960 row slots for a requested 5,959 rows.
    # Reverse X to the driver's native film orientation.
    return np.asarray(rows[:height, ::-1, :]).copy()


def _counter_train_ok(
    block: np.ndarray,
    *,
    first_counter: int,
) -> bool:
    if block.ndim != 2 or block.shape[1] % 2:
        return False
    expected = (first_counter + np.arange(block.shape[1] // 2, dtype=np.uint32)) & 0xFFFF
    return bool(np.all(block[:, 0::2] == 0xAA55) and np.all(block[:, 1::2] == expected.astype(np.uint16)[None, :]))


def _padding_counter_dialect(block: np.ndarray) -> str | None:
    """Identify any complete padding counter dialect observed live.

    The original captures begin with the canonical ``AA55,D893`` pair.  Two
    further stable LS-5000 states, each observed identically in both long
    padding blocks across every record of its captured stream, replace only
    the first three words with a repeated sentinel — ``E9EA``, ``E004``, or
    ``DC4C``.
    The fourth word remains ``D894`` and the canonical ``AA55,D895...`` train
    resumes immediately afterward.  Accept only those exact whole-block forms.
    """

    if _counter_train_ok(block, first_counter=0xD893):
        return "canonical"
    if block.ndim != 2 or block.shape[1] < 4:
        return None
    for sentinel, dialect in (
        (0xE9EA, "e9ea-prefixed"),
        (0xE004, "e004-prefixed"),
        (0xDC4C, "dc4c-prefixed"),
    ):
        sentinel_prefix = np.array(
            [sentinel, sentinel, sentinel, 0xD894],
            dtype=np.uint16,
        )
        if np.all(block[:, :4] == sentinel_prefix[None, :]) and _counter_train_ok(
            block[:, 4:],
            first_counter=0xD895,
        ):
            return dialect
    return None


def validate_full_record_layout(words: np.ndarray) -> dict[str, object]:
    """Fail closed on the four invariant padding regions in every record."""
    if words.ndim != 2 or words.shape[1] != FULL_RECORD_WORDS:
        raise ValueError(f"unexpected full-record word shape {words.shape}")

    pad0 = words[:, 63_136 // 2 : 63_488 // 2]
    pad1 = words[:, 110_840 // 2 : 111_616 // 2]
    pad2 = words[:, 158_968 // 2 : 159_744 // 2]
    pad3 = words[:, 207_096 // 2 : 207_872 // 2]
    ir_head = words[:, FULL_IR_BYTE_OFFSET // 2 : FULL_IR_BYTE_OFFSET // 2 + 388]

    if not _counter_train_ok(pad0, first_counter=0xE7FD):
        raise ValueError("full-record padding 0 counter train mismatch")
    pad1_dialect = _padding_counter_dialect(pad1)
    if pad1_dialect is None:
        raise ValueError("full-record padding 1 counter train mismatch")
    if not np.array_equal(pad2, ir_head):
        raise ValueError("full-record padding 2 is not the expected IR-head copy")
    pad3_dialect = _padding_counter_dialect(pad3)
    if pad3_dialect is None or pad3_dialect != pad1_dialect:
        raise ValueError("full-record padding 3 counter train mismatch")

    return {
        "padding_validated_records": int(words.shape[0]),
        "padding_byte_ranges": [list(bounds) for bounds in FULL_PADDING_BYTE_RANGES],
        "padding_1_3_counter_dialect": pad1_dialect,
        "padding_2_semantics": "duplicate of first 388 IR words; discarded",
    }


def _decode_record_block(block: np.ndarray, *, width: int = WIDTH) -> np.ndarray:
    """Average four RGB samples and carry the one IR plane for ``N`` records.

    ``block`` is ``(N, FULL_RECORD_WORDS)`` big-endian words.  Returns
    ``N * ROWS_PER_RECORD`` output rows of shape ``(width, CHANNELS)`` already
    reversed to the driver's native film orientation.  This is the single
    record kernel shared by the batch ``decode_full_records`` path and the
    streaming ``StreamingFrameDecoder`` so that both stay byte-identical.  The
    caller owns padding validation and clamping of the trailing surplus row.
    """

    count = block.shape[0]
    rgb_sum = np.zeros((count, RGB_CHANNELS, UNIT_WORDS), dtype=np.uint64)
    for sample_offsets in FULL_RGB_SAMPLE_WORD_OFFSETS:
        for channel, offset in enumerate(sample_offsets):
            rgb_sum[:, channel] += block[:, offset : offset + UNIT_WORDS]
    rgb_avg = ((rgb_sum + 2) // 4).astype(np.uint16)
    rgb_rows = rgb_avg.reshape(count, RGB_CHANNELS, width, ROWS_PER_RECORD).transpose(0, 3, 2, 1)
    ir_rows = block[:, FULL_IR_WORD_OFFSET : FULL_IR_WORD_OFFSET + UNIT_WORDS].reshape(count, width, ROWS_PER_RECORD).transpose(0, 2, 1)

    chunk = np.empty((count, ROWS_PER_RECORD, width, CHANNELS), dtype=np.uint16)
    chunk[..., :RGB_CHANNELS] = rgb_rows
    chunk[..., 3] = ir_rows
    return chunk.reshape(-1, width, CHANNELS)[:, ::-1, :]


def decode_full_records(
    path: Path,
    *,
    width: int = WIDTH,
    height: int = HEIGHT,
    validate_padding: bool = True,
    chunk_records: int = 64,
) -> tuple[np.ndarray, dict[str, object]]:
    """Average four RGB samples and extract the single transferred IR plane."""
    if width != WIDTH:
        raise ValueError(f"full-record decode requires width {WIDTH}, got {width}")
    records = (height + 1) // 2
    expected_size = records * FULL_RECORD_BYTES
    if path.stat().st_size != expected_size:
        raise ValueError(f"stream has {path.stat().st_size} bytes, expected {expected_size}")
    if chunk_records <= 0:
        raise ValueError("chunk_records must be positive")

    words = np.memmap(
        path,
        dtype=">u2",
        mode="r",
        shape=(records, FULL_RECORD_WORDS),
    )
    layout_report: dict[str, object] = {}
    if validate_padding:
        layout_report = validate_full_record_layout(words)

    rgbi = np.empty((height, width, CHANNELS), dtype=np.uint16)

    for first in range(0, records, chunk_records):
        last = min(records, first + chunk_records)
        flat_rows = _decode_record_block(words[first:last], width=width)
        output_first = first * ROWS_PER_RECORD
        output_last = min(height, output_first + flat_rows.shape[0])
        rgbi[output_first:output_last] = flat_rows[: output_last - output_first]

    layout_report.update(
        {
            "rgb_samples_decoded": 4,
            "rgb_average": "round-half-up uint16 average",
            "ir_planes_transferred": 1,
            "ir_multisample_semantics": "firmware-combined-or-1x-unresolved",
        }
    )
    return rgbi, layout_report


def decode_records(
    path: Path,
    *,
    record_bytes: int,
    width: int = WIDTH,
    height: int = HEIGHT,
) -> tuple[np.ndarray, dict[str, object]]:
    if record_bytes == FULL_RECORD_BYTES:
        return decode_full_records(path, width=width, height=height)
    return (
        decode_core_records(
            path,
            record_bytes=record_bytes,
            width=width,
            height=height,
            channels=CHANNELS,
        ),
        {
            "rgb_samples_decoded": 1,
            "ir_planes_transferred": 1,
            "prefix_capture": True,
        },
    )


class StreamingFrameDecoder:
    """Streaming LS-5000 full-record decoder fed arbitrarily fragmented bytes.

    Feed `push` payloads in arrival order -- any size, including one byte at a
    time or whole records -- then call `finish`.  It routes every completed
    207,872-byte record through the same `_decode_record_block` kernel and the
    same fail-closed `validate_full_record_layout` padding check as the batch
    `decode_full_records`, so its output is byte-identical to an offline decode
    of the same stream.

    It retains at most one record of raw staging, enforces an exact stream
    length, and reveals its private output buffer only after a complete,
    padding-valid `finish`.  It is a pure consumer: no file, USB, or threading
    side effects.  Buffering is bounded by design -- raw staging never exceeds
    one record -- but the decoded frame itself is full-size, as it must be to
    match the batch decoder and downstream quality control.
    """

    def __init__(
        self,
        *,
        height: int = HEIGHT,
        width: int = WIDTH,
        validate_padding: bool = True,
        out: np.ndarray | None = None,
    ) -> None:
        if width != WIDTH:
            raise ValueError(f"streaming decode requires width {WIDTH}, got {width}")
        if type(height) is not int or height <= 0:
            raise ValueError("height must be a positive integer")
        records = (height + 1) // 2
        self._height = height
        self._width = width
        self._records = records
        self._validate_padding = validate_padding
        self._expected_bytes = records * FULL_RECORD_BYTES
        self._staging = bytearray(FULL_RECORD_BYTES)
        self._filled = 0
        self._received = 0
        self._record_index = 0
        self._max_staged = 0
        if out is not None:
            out_array = np.asarray(out)
            if (
                out_array.shape != (height, width, CHANNELS)
                or out_array.dtype != np.uint16
            ):
                raise ValueError(
                    f"out must be a writable ({height}, {width}, {CHANNELS}) uint16 array"
                )
            self._rgbi: np.ndarray | None = out_array
        else:
            self._rgbi = None
        self._finished = False

    @property
    def expected_bytes(self) -> int:
        return self._expected_bytes

    @property
    def received(self) -> int:
        return self._received

    @property
    def records(self) -> int:
        return self._records

    @property
    def max_staged_bytes(self) -> int:
        """Peak raw staging occupancy; never exceeds one full record."""

        return self._max_staged

    @property
    def finished(self) -> bool:
        return self._finished

    def push(self, chunk: bytes | bytearray | memoryview) -> None:
        """Feed the next fragment; rejects any overrun of the exact length."""

        if self._finished:
            raise ValueError("push after finish")
        data = memoryview(chunk)
        length = data.nbytes
        if length == 0:
            return
        if self._received + length > self._expected_bytes:
            raise ValueError(
                f"stream overruns the exact {self._expected_bytes}-byte length"
            )
        self._received += length
        offset = 0
        while offset < length:
            take = min(FULL_RECORD_BYTES - self._filled, length - offset)
            self._staging[self._filled : self._filled + take] = data[offset : offset + take]
            self._filled += take
            offset += take
            if self._filled > self._max_staged:
                self._max_staged = self._filled
            if self._filled == FULL_RECORD_BYTES:
                self._emit_record()
                self._filled = 0

    def _emit_record(self) -> None:
        if self._rgbi is None:
            self._rgbi = np.empty((self._height, self._width, CHANNELS), dtype=np.uint16)
        record_words = np.frombuffer(self._staging, dtype=">u2").reshape(1, FULL_RECORD_WORDS)
        if self._validate_padding:
            validate_full_record_layout(record_words)
        flat_rows = _decode_record_block(record_words, width=self._width)
        output_first = self._record_index * ROWS_PER_RECORD
        output_last = min(self._height, output_first + flat_rows.shape[0])
        self._rgbi[output_first:output_last] = flat_rows[: output_last - output_first]
        self._record_index += 1

    def finish(self) -> tuple[np.ndarray, dict[str, object]]:
        """Complete the frame and reveal the private output buffer.

        Raises (revealing nothing) unless the stream is exactly the expected
        length, ends on a record boundary, and every record decoded.
        """

        if self._finished:
            raise ValueError("finish already called")
        if self._received != self._expected_bytes:
            raise ValueError(
                f"stream has {self._received} bytes, expected {self._expected_bytes}"
            )
        if self._filled != 0:
            raise ValueError("stream ended on a partial record")
        if self._record_index != self._records:
            raise ValueError(
                f"decoded {self._record_index} records, expected {self._records}"
            )
        if self._rgbi is None:
            raise ValueError(" streamed decode produced no output buffer")
        self._finished = True
        # Exactly the canonical decode proof, with no extra keys: a consumer
        # (the capture sidecar) refuses to publish unless this proof is exact,
        # so evidence can never be invented by filling in defaults.
        layout: dict[str, object] = {
            "rgb_samples_decoded": 4,
            "rgb_average": "round-half-up uint16 average",
            "ir_planes_transferred": 1,
        }
        if self._validate_padding:
            layout["padding_validated_records"] = int(self._record_index)
        return self._rgbi, layout
