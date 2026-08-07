"""Regression contracts for the proven LS-5000 packed RGB4x + IR stream."""

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
    decode_core_records,
    decode_full_records,
    infer_record_geometry,
)


def _counter_train(words: np.ndarray, first_counter: int) -> None:
    words[0::2] = 0xAA55
    words[1::2] = (first_counter + np.arange(words.size // 2, dtype=np.uint32)) & 0xFFFF


def _e9ea_prefixed_counter_train(words: np.ndarray) -> None:
    words[:4] = (0xE9EA, 0xE9EA, 0xE9EA, 0xD894)
    _counter_train(words[4:], 0xD895)


def _e004_prefixed_counter_train(words: np.ndarray) -> None:
    words[:4] = (0xE004, 0xE004, 0xE004, 0xD894)
    _counter_train(words[4:], 0xD895)


def _synthetic_full_records(height: int = 3) -> tuple[np.ndarray, np.ndarray]:
    records = (height + 1) // 2
    base = (np.arange(records * 2 * WIDTH * 4, dtype=np.uint32).reshape(records * 2, WIDTH, 4) % 20_000).astype(np.uint16)
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


def test_core_decoder_preserves_channel_x_row_order_and_discards_surplus_row(tmp_path: Path) -> None:
    width, height, channels = 3, 3, 4
    records = 2
    core_words = width * channels * 2
    record_bytes = core_words * 2 + 10
    expected = np.arange(height * width * channels, dtype=np.uint16).reshape(height, width, channels)
    row_slots = np.concatenate([expected[:, ::-1], np.full((1, width, channels), 60_000, dtype=np.uint16)])
    wire = row_slots.reshape(records, 2, width, channels).transpose(0, 3, 2, 1).reshape(records, core_words)
    path = tmp_path / "prefix.bin"
    with path.open("wb") as stream:
        for record in wire:
            stream.write(record.astype(">u2").tobytes())
            stream.write(b"\xaa" * 10)

    decoded = decode_core_records(path, record_bytes=record_bytes, width=width, height=height, channels=channels)

    np.testing.assert_array_equal(expected, decoded)


def test_full_decoder_rounds_four_rgb_samples_and_keeps_one_ir_plane(tmp_path: Path) -> None:
    base, full = _synthetic_full_records()
    path = tmp_path / "full.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    decoded, report = decode_full_records(path, height=3)

    expected = base.copy()
    expected[..., :3] += 2
    np.testing.assert_array_equal(expected, decoded)
    assert report["rgb_samples_decoded"] == 4
    assert report["rgb_average"] == "round-half-up uint16 average"
    assert report["ir_planes_transferred"] == 1
    assert report["padding_validated_records"] == 2
    assert report["padding_1_3_counter_dialect"] == "canonical"


def test_full_decoder_fails_closed_on_padding_corruption(tmp_path: Path) -> None:
    _base, full = _synthetic_full_records()
    full[1, 63_136 // 2] ^= 1
    path = tmp_path / "corrupt.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 0 counter train mismatch"):
        decode_full_records(path, height=3)


def test_full_decoder_accepts_e9ea_prefixed_padding_counter_dialect(tmp_path: Path) -> None:
    base, full = _synthetic_full_records()
    for record in full:
        _e9ea_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
        _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    path = tmp_path / "e9ea-prefixed.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    decoded, report = decode_full_records(path, height=3)

    expected = base.copy()
    expected[..., :3] += 2
    np.testing.assert_array_equal(expected, decoded)
    assert report["padding_1_3_counter_dialect"] == "e9ea-prefixed"


def test_full_decoder_rejects_corrupt_e9ea_prefixed_padding(tmp_path: Path) -> None:
    _base, full = _synthetic_full_records()
    for record in full:
        _e9ea_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
        _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    full[1, 110_840 // 2] ^= 1
    path = tmp_path / "corrupt-e9ea-prefixed.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 1 counter train mismatch"):
        decode_full_records(path, height=3)


def test_full_decoder_rejects_mixed_padding_counter_dialects(tmp_path: Path) -> None:
    _base, full = _synthetic_full_records()
    for record in full:
        _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    path = tmp_path / "mixed-padding-dialects.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 3 counter train mismatch"):
        decode_full_records(path, height=3)


def test_full_decoder_rejects_cross_record_dialect_change(tmp_path: Path) -> None:
    _base, full = _synthetic_full_records()
    record = full[1]
    _e9ea_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
    _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    path = tmp_path / "cross-record-dialect-change.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 1 counter train mismatch"):
        decode_full_records(path, height=3)


def test_full_decoder_accepts_e004_prefixed_padding_counter_dialect(tmp_path: Path) -> None:
    base, full = _synthetic_full_records()
    for record in full:
        _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
        _e004_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    path = tmp_path / "e004-prefixed.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    decoded, report = decode_full_records(path, height=3)

    expected = base.copy()
    expected[..., :3] += 2
    np.testing.assert_array_equal(expected, decoded)
    assert report["padding_1_3_counter_dialect"] == "e004-prefixed"


@pytest.mark.parametrize(
    "corrupt_word_offset",
    [110_840 // 2, 110_840 // 2 + 3, 110_840 // 2 + 4, 111_616 // 2 - 1],
    ids=["sentinel", "d894", "train-head", "train-tail"],
)
def test_full_decoder_rejects_corrupt_e004_prefixed_padding(
    tmp_path: Path, corrupt_word_offset: int
) -> None:
    _base, full = _synthetic_full_records()
    for record in full:
        _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
        _e004_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    full[1, corrupt_word_offset] ^= 1
    path = tmp_path / "corrupt-e004-prefixed.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 1 counter train mismatch"):
        decode_full_records(path, height=3)


def test_full_decoder_rejects_e004_padding_1_with_canonical_padding_3(tmp_path: Path) -> None:
    _base, full = _synthetic_full_records()
    for record in full:
        _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
    path = tmp_path / "mixed-e004-canonical.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 3 counter train mismatch"):
        decode_full_records(path, height=3)


def test_full_decoder_rejects_e004_padding_1_with_e9ea_padding_3(tmp_path: Path) -> None:
    _base, full = _synthetic_full_records()
    for record in full:
        _e004_prefixed_counter_train(record[110_840 // 2 : 111_616 // 2])
        _e9ea_prefixed_counter_train(record[207_096 // 2 : 207_872 // 2])
    path = tmp_path / "mixed-e004-e9ea.bin"
    path.write_bytes(full.astype(">u2").tobytes())

    with pytest.raises(ValueError, match="padding 3 counter train mismatch"):
        decode_full_records(path, height=3)


def test_geometry_inference_accepts_only_known_record_sizes(tmp_path: Path) -> None:
    path = tmp_path / "stream.bin"
    path.write_bytes(b"\x00" * (2 * FULL_RECORD_BYTES))
    assert infer_record_geometry(path, records=2) == FULL_RECORD_BYTES
    path.write_bytes(b"\x00" * 14)
    with pytest.raises(ValueError, match="neither"):
        infer_record_geometry(path, records=2)
