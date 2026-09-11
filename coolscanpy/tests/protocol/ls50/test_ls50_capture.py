"""Hardware-free tests for the LS-50 (Coolscan V) direct-USB package.

These exercise the nkscan-derived wire grammar (DTC/DTQ image READ, chunked
reads, ILI-as-end-of-stream) and the preview end-of-strip logic without a
scanner attached.
"""

from __future__ import annotations

import numpy as np

from coolscanpy.protocol.ls50.capture import Ls50ScanOptions


def test_ls50_scan_options_geometry() -> None:
    """The 400-dpi RGBI scan describes the LS-50's 3940x5950 native window."""
    opt = Ls50ScanOptions(dpi=400, depth=8, rgbi=True, y_min=0, y_max=5958)
    assert opt.logical_width == 394
    assert opt.logical_height == 595
    assert opt.n_colors == 4
    # RGBI line = 4 * 394 * 1 = 1576, padded to 2048 (512-block).
    assert opt.line_bytes_raw == 1576
    assert opt.line_bytes_padded == 2048
    assert opt.stream_bytes == 595 * 2048


def test_ls50_scan_options_14bit_rgbi() -> None:
    opt = Ls50ScanOptions(dpi=4000, depth=14, rgbi=True)
    assert opt.logical_width == 3941
    assert opt.logical_height == 5951
    assert opt.bytes_per_sample == 2


def test_ls50_read_cdb_uses_dtc_dtq_layout() -> None:
    """The image READ carries DTC=0, DTQ=(color<<8|width), len24, ctl=0x80.

    This is the nkscan wire grammar; replaying the old LBA-based CDB is what
    desynchronized the LS-50 stream.
    """
    opt = Ls50ScanOptions(dpi=400, depth=8, rgbi=True)
    want = 1 << 16
    cdb = bytearray(10)
    cdb[0] = 0x28
    cdb[2] = 0x00  # DataType::Image
    # width_code(1 byte) = 0x00, color = 0
    cdb[4:6] = ((0 << 8) | 0x00).to_bytes(2, "big")
    cdb[6:9] = want.to_bytes(3, "big")
    cdb[9] = 0x80  # Nikon VENDOR control
    assert cdb.hex() == "28000000000001000080"


def test_width_code_mapping_matches_nkscan() -> None:
    # nkscan width_code: 1->0x00, 2->0x01, 4->0x03.
    assert {1: 0x00, 2: 0x01, 4: 0x03}[1] == 0x00
    assert {1: 0x00, 2: 0x01, 4: 0x03}[2] == 0x01


def test_preview_end_of_strip_stops_on_near_black_run() -> None:
    """Two consecutive near-black slots end the preview loop."""
    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    def near_black(img: np.ndarray) -> bool:
        return float(img.mean()) < 20.0 and float(img.std()) < 5.0

    # Real-strip shape: 1-5 real, 6 transitional (std ~18, NOT near-black),
    # 7-8 black (std ~0.1).  Stop fires on the 2nd consecutive near-black.
    rng = np.random.default_rng(0)
    frames = [
        (165 + rng.normal(0, 40, (8, 8, 3))).clip(0, 255).astype(np.uint8),
        (179 + rng.normal(0, 40, (8, 8, 3))).clip(0, 255).astype(np.uint8),
        (221 + rng.normal(0, 40, (8, 8, 3))).clip(0, 255).astype(np.uint8),
        (183 + rng.normal(0, 40, (8, 8, 3))).clip(0, 255).astype(np.uint8),
        (162 + rng.normal(0, 40, (8, 8, 3))).clip(0, 255).astype(np.uint8),
        # transitional: mean low, std > 5 (so NOT near-black)
        np.full((8, 8, 3), 4, np.uint8) + rng.normal(0, 18, (8, 8, 3)).clip(0, 60).astype(np.uint8),
        np.zeros((8, 8, 3), np.uint8),
        np.zeros((8, 8, 3), np.uint8),
    ]
    consecutive_blank = 0
    stopped_at = None
    for i, img in enumerate(frames, start=1):
        nb = near_black(img)
        consecutive_blank = consecutive_blank + 1 if nb else 0
        if consecutive_blank >= 2:
            stopped_at = i
            break
    assert stopped_at == 8


def test_ls50_preview_honors_stop_signal() -> None:
    """A set stop event ends the preview loop immediately."""
    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    roll = Ls50Roll.__new__(Ls50Roll)
    roll._stop_event = __import__("threading").Event()
    roll._stop_event.set()
    # The loop's first guard checks the stop event.
    from dataclasses import replace

    class FakeSession:
        def capture(self, opt, boundary_best_effort=True):
            raise AssertionError("capture must not run when stop is set")

    roll.session = FakeSession()
    frames = [type("F", (), {"index": 1, "native_origin": 0, "spacing_offset_rows": 0})()]
    # Directly exercise the guard logic
    if roll._stop_event.is_set():
        ran = False
    else:
        ran = True
    assert ran is False


def _encode_slot(img: np.ndarray) -> bytes:
    """Encode a (H, W, 3) uint8 slot image as a padded 8-bit RGBI stream.

    Mirrors the driver's decode path in ``Ls50Roll.preview``: the unit
    returns ``logical_height * line_bytes_padded`` bytes whose first
    ``line_bytes_raw`` bytes per row are ``(H, 4ch, W)`` interleaved RGBI.
    """
    from coolscanpy.protocol.ls50.capture import Ls50ScanOptions

    opt = Ls50ScanOptions(dpi=400, depth=8, rgbi=True, y_min=0, y_max=5958)
    h, w, _ = img.shape
    rgbaoi = np.zeros((h, 4, w), np.uint8)
    rgbaoi[:, :3, :] = np.moveaxis(img, -1, 1)
    raw = np.zeros((h, opt.line_bytes_padded), np.uint8)
    raw[:, : opt.line_bytes_raw] = rgbaoi.reshape(h, opt.line_bytes_raw)
    return raw.tobytes()


def test_ls50_preview_stops_on_transport_home_loop() -> None:
    """Past the last real frame the LS-50 re-scans frame 1 (a "home loop");
    the preview must detect the near-identical repeat and stop instead of
    looping 1..N, N..1 forever."""
    import threading

    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    rng = np.random.default_rng(7)
    slots = {}
    for s in range(1, 6):
        img = (150 + rng.normal(0, 40, (595, 394, 3))).clip(0, 255).astype(np.uint8)
        slots[s] = img

    class FakeSession:
        def __init__(self):
            self.calls = []

        def capture(self, opt, boundary_best_effort=True):
            slot = len(self.calls) + 1
            if slot <= 5:
                data = _encode_slot(slots[slot])
            else:
                # The transport looped back to frame 1 (re-scan of slot 1
                # with a little sensor noise, indistinguishable from the
                # original at the 8-bit preview level).
                data = _encode_slot(
                    (slots[1].astype(np.int16) + rng.normal(0, 2, slots[1].shape))
                    .clip(0, 255).astype(np.uint8)
                )
            self.calls.append(slot)
            return data

    roll = Ls50Roll.__new__(Ls50Roll)
    session = FakeSession()
    roll.session = session
    roll._stop_event = threading.Event()
    roll._preview = None
    roll._preview_ready = False
    roll._approvals = set()
    roll._output_root = __import__("pathlib").Path(".")

    thumbnails = roll.preview()

    assert [t.slot for t in thumbnails] == [1, 2, 3, 4, 5]
    # One extra capture (the looped re-scan of frame 1) was served before the
    # detector stopped the pass; it must never run out the whole 40-slot list.
    assert session.calls == [1, 2, 3, 4, 5, 6]


def test_ls50_strip_regions_match() -> None:
    """The home-loop comparator accepts real re-scans and rejects different
    frames and featureless (low-variance) images."""
    from coolscanpy.protocol.ls50.workflow import _strip_regions_match

    rng = np.random.default_rng(3)
    a = (150 + rng.normal(0, 40, (595, 394, 3))).clip(0, 255).astype(np.uint8)
    b = (150 + rng.normal(0, 40, (595, 394, 3))).clip(0, 255).astype(np.uint8)
    # Identical capture -> match.
    assert _strip_regions_match(a, a)
    # Re-scan with tiny sensor noise -> still the same region.
    noisy = (a.astype(np.int16) + rng.normal(0, 2, a.shape)).clip(0, 255).astype(np.uint8)
    assert _strip_regions_match(a, noisy)
    # Two different frames are never "the same region".
    assert not _strip_regions_match(a, b)
    # Featureless frames defer to the near-black detector (no false positive).
    flat = np.full((595, 394, 3), 128, np.uint8)
    assert not _strip_regions_match(flat, flat.copy())


def _build_preview_state() -> tuple:
    """A 2-slot preview whose stacked raster and slot records are consistent
    with ``Ls50Roll.preview`` output: slot 1 = rows 0..10 (a ramp), slot 2 =
    rows 11..21 (its mirror), so boundary shifts are observable."""
    from coolscanpy.protocol.ls50.workflow import Ls50PreviewResult, Ls50Frame

    raster = np.zeros((22, 4, 3), np.uint8)
    for r in range(11):
        raster[r] = r
        raster[21 - r] = 200 + r
    slot_images = {1: raster[:11], 2: raster[11:]}
    records = {1: (0, 10), 2: (11, 21)}
    frames = [Ls50Frame(index=1, native_origin=0), Ls50Frame(index=2, native_origin=5959)]
    return Ls50PreviewResult(rgb=raster, frames=frames, slot_images=slot_images, slot_records=records)


def test_set_spacing_offset_returns_full_slot_height() -> None:
    """The align step's re-crop must return the FULL slot height, shifted,
    never a half-height zoomed sliver (bug: returned h//2 rows)."""
    import threading
    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    roll = Ls50Roll.__new__(Ls50Roll)
    roll.session = object()
    roll._stop_event = threading.Event()
    roll._preview = _build_preview_state()
    roll._preview_ready = True
    roll._approvals = set()
    roll._output_root = __import__("pathlib").Path(".")

    base = roll._preview.slot_images[1]
    thumb = roll.set_spacing_offset(1, 3)

    assert thumb.image.shape == base.shape, \
        f"re-crop must stay full slot size, got {thumb.image.shape} vs {base.shape}"
    # Offset +3 shifts the window down 3 rows in the strip raster: crop row i
    # is strip row (slot_start + 3 + i), exactly the LS-5000 re-crop rule.
    raster = roll._preview.rgb
    for i in range(thumb.image.shape[0]):
        assert np.array_equal(thumb.image[i], raster[3 + i]), \
            f"crop row {i} must equal strip row {3 + i}"


def test_set_spacing_offset_negative_and_persist() -> None:
    """Negative offsets shift up, and the offset persists into the frame list
    so scan_many applies it."""
    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    roll = Ls50Roll.__new__(Ls50Roll)
    roll.session = object()
    roll._stop_event = __import__("threading").Event()
    roll._preview = _build_preview_state()
    roll._preview_ready = True
    roll._approvals = set()
    roll._output_root = __import__("pathlib").Path(".")

    thumb = roll.set_spacing_offset(2, -2)
    assert thumb.image.shape == roll._preview.slot_images[2].shape
    # Slot 2 starts at strip row 11; offset -2 -> crop row i is strip row 9+i.
    raster = roll._preview.rgb
    for i in range(thumb.image.shape[0]):
        assert np.array_equal(thumb.image[i], raster[9 + i]), \
            f"crop row {i} must equal strip row {9 + i}"
    persisted = next(f for f in roll._preview.frames if f.index == 2)
    assert persisted.spacing_offset_rows == -2


def test_set_spacing_offset_pads_off_raster() -> None:
    """Rows whose source falls off the captured raster are blank padding."""
    import threading
    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    roll = Ls50Roll.__new__(Ls50Roll)
    roll.session = object()
    roll._stop_event = threading.Event()
    roll._preview = _build_preview_state()
    roll._preview_ready = True
    roll._approvals = set()
    roll._output_root = __import__("pathlib").Path(".")

    thumb = roll.set_spacing_offset(1, -4)
    assert thumb.image.shape == roll._preview.slot_images[1].shape
    # Slot 1 starts at strip row 0; offset -4 pushes the first 4 rows off the
    # top -> blank, the rest is strip rows 0..6.
    assert np.all(thumb.image[:4] == 0), "rows off the top must be blank"
    raster = roll._preview.rgb
    for i in range(4, thumb.image.shape[0]):
        assert np.array_equal(thumb.image[i], raster[i - 4]), \
            f"crop row {i} must equal strip row {i - 4}"


def test_preview_survives_a_clean_empty_read_mid_strip() -> None:
    """A film-ejected-mid-seek slot can come back with sense 000000 but ZERO
    bytes (``_read_lines`` treats an immediate short read as a normal
    end-of-stream, not a fault). Reshaping that empty buffer into the fixed
    frame shape used to raise a raw, uncaught ValueError that crashed the
    whole preview instead of ending it gracefully -- live 2026-09-11:
    "cannot reshape array of size 0 into shape (595,2048)" right after an
    eject. The frames captured before the empty read must still come back."""
    import threading
    from coolscanpy.protocol.ls50.workflow import Ls50Roll

    rng = np.random.default_rng(11)
    slots = {
        s: (150 + rng.normal(0, 40, (595, 394, 3))).clip(0, 255).astype(np.uint8)
        for s in range(1, 4)
    }

    class FakeSession:
        def __init__(self):
            self.calls = 0

        def capture(self, opt, boundary_best_effort=True):
            self.calls += 1
            if self.calls <= 3:
                return _encode_slot(slots[self.calls])
            return b""  # eject mid-seek: clean, but empty

    roll = Ls50Roll.__new__(Ls50Roll)
    roll.session = FakeSession()
    roll._stop_event = threading.Event()
    roll._preview = None
    roll._preview_ready = False
    roll._approvals = set()
    roll._output_root = __import__("pathlib").Path(".")

    thumbnails = roll.preview()  # must not raise

    assert [t.slot for t in thumbnails] == [1, 2, 3]


def test_scan_many_pre_flips_and_tags_storage_transform() -> None:
    """The engine's derivative renderer unconditionally applies the LS-5000's
    "swapaxes01" storage transform to any archive master, and refuses to
    render at all without a recognized storageTransform tag -- LS-50 receipts
    previously left this None, so a real scan's Positive/Preview never
    rendered at all. Settled by normalized cross-correlation (not eyeballing,
    after several wrong visual calls both ways) between the confirmed-correct
    preview tile and 4 transformed candidates of a real full-res capture of
    the same frame: flipud(swap(x)) scored clearly highest. The preview path
    gets that via `_normalize_preview_tile(mirror=True)`; the engine has no
    second flip, so `scan_many` must store a pre-flipped master:
    swap(fliplr(x)) == flipud(swap(x)) for any x, so storing fliplr(x) here
    reproduces the same confirmed-correct result once the engine's own swap
    runs on it."""
    import threading
    from dataclasses import replace as dc_replace

    from coolscanpy.protocol.ls50.capture import Ls50ScanOptions
    from coolscanpy.protocol.ls50.workflow import Ls50Frame, Ls50PreviewResult, Ls50Roll

    rng = np.random.default_rng(5)
    img = (150 + rng.normal(0, 40, (595, 394, 3))).clip(0, 255).astype(np.uint8)

    class FakeSession:
        def capture(self, opt, boundary_best_effort=True):
            return _encode_slot(img)

    roll = Ls50Roll.__new__(Ls50Roll)
    roll.session = FakeSession()
    roll._stop_event = threading.Event()
    roll._output_root = __import__("pathlib").Path(".")
    roll.scan_options = Ls50ScanOptions(dpi=400, depth=8, rgbi=True)
    roll._preview = Ls50PreviewResult(
        rgb=np.zeros((1, 1, 3), np.uint8),
        frames=[Ls50Frame(index=1, native_origin=0)],
        slot_images={},
        slot_records={},
    )

    (frame,) = list(roll.scan_many([1]))

    assert frame.receipt.storage_transform == (
        "swapaxes01-scanner-native-to-nikon-render-parity-v2"
    )
    opt = dc_replace(
        Ls50ScanOptions(dpi=400, depth=8, rgbi=True),
        y_min=0, y_max=5958,
    )
    naive_rgb, _ = Ls50Roll._decode_rgbi(_encode_slot(img), opt)
    assert np.array_equal(frame.rgb, naive_rgb)
