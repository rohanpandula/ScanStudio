from __future__ import annotations

"""Direct-USB RGBI capture for the Nikon LS-50 ED (Coolscan V).

The command sequence here was reverse-engineered and proven against a
physical LS-50 ED (USB 04b0:4001) using a 5-frame color-negative strip in
an SA-30 adapter, 2026-09-09. The SASI/Coolscan protocol differs enough
from the LS-5000 trace that the LS-5000 ``ls5000_single_pass.worker``
cannot drive this model; this module is the LS-50-specific direct-USB path.

Proven wire sequence (all steps ``000000`` against the live unit):

    RESERVE         16 00 00 00 00 00
    MODE_SELECT     15 10 00 00 14 00  <20-byte data_out>
    SET_BOUNDARY    2a 00 88 00 00 03  <30-byte data_out>
    SET_WINDOW      24 00 00 00 00 00 00 00 3a 80  <58-byte data_out>  x4 (9,1,2,3)
    SCAN           1b 00 00 00 04 00  09 01 02 03     (RGBI)  -- or 03 00 01 02 03 (RGB)
    READ(10)        28 00 00 00 00 00 <alloc24> 00    per line

Allocation length (byte semantics): the READ CDB *must* encode the padded
line length in the 3-byte allocation field, or the unit returns no data
(phase 1, sense 000000). Per-line length for the LS-50:

    line_bytes = n_colors * logical_width * bytes_per_sample
    n_colors   = 4 for RGBI (R,G,B,IR), 3 for RGB
    logical_width at 400dpi = 394 px (native 3940 / pitch 10)
    bytes_per_sample = 1 (8-bit) or 2 (14-bit in a 16-bit container)
    padded to the next 512-byte block  (LS-50 requires 512-block padding)

The frame table (0x8f) reports 40 frames with a 5959-native-unit pitch,
identical to the LS-5000, so frame placement reuses the same pitch.
"""
LS50_PROTOCOL_NOTES = r"""PROTOCOL NOTES (embedded):
# PROTOCOL NOTES (2026-09-09, physical LS-50 ED 04b0:4001, 5-frame color neg in SA-30):
#
# CONFIRMED WORKING (full RGBI raw capture streamed):
#   RESERVE -> MODE_SELECT(20B) -> SET_BOUNDARY(1.5x formula) -> SET_WINDOW x4 (9,1,2,3)
#   -> SCAN 1b 00 00 00 04 00 09 01 02 03 (RGBI) -> [TUR]* -> per-line READ(10) 2048B
#   Result: 595 lines x 2048 = 1,218,560 B; R/G/B real image + IR plane (mean ~241).
#
# CRITICAL FRAMES:
#   - READ(10) CDB allocation MUST encode the padded per-line length (2048 for
#     4ch@400dpi@8-bit) or the unit returns phase-1/sense-000000 with no data.
#   - MODE_SELECT data_out = 000000080000000000000001030600000fa00000 (20B, plan-exact).
#   - SET_BOUNDARY uses SANE frame_offset = int(resy_max*1.5+1)=8926, end=8925,
#     boundaryx-1=3939. A pitch-5959 boundary (end 5958) rejects 052400.
#   - window geometry (native units) at 400dpi: width=3940, height=5950.
#
# STILL-OPEN (needs patient per-command iteration, state-dependent):
#   - SET_BOUNDARY sometimes rejects 052400 in a fresh session after the first
#     power-cycle; may depend on the strip's loaded frame count (n_frames).
#   - C1 page read with large allocation overflows (-8); small allocation
#     rejects 052400. Works only in certain device states.
#   - SEND LUT (2a 00 03 00) wedges the pipeline at >=512B; omitted for raw.
#
# The LS-50 frame table (0x8f) reports 40 frames at 5959-native pitch, same as
# the LS-5000, so frame placement can reuse that pitch."""

import struct
import time
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Any

from ..ls5000_single_pass.worker import (
    _connect_device,
    perform_transaction,
)
from ..ls5000_single_pass.usb_backend import get_libusb_backend  # noqa: F401 (kept for parity)


class Ls50CaptureError(RuntimeError):
    """A wire-level LS-50 capture failed."""


class Ls50Resolution(IntEnum):
    """The LS-50's supported scan resolutions (dpi). 4000 is native-max."""
    DPI_4000 = 4000
    DPI_2000 = 2000
    DPI_1000 = 1000
    DPI_400 = 400
    DPI_200 = 200


@dataclass(frozen=True)
class Ls50ScanOptions:
    """One LS-50 scan request."""

    dpi: int = 400
    depth: int = 8  # 8 or 14 (ADC native); 14 stored in 16-bit container
    rgbi: bool = True  # RGBI (IR plane) vs RGB only
    x_min: int = 0
    y_min: int = 0
    x_max: int = 3940
    y_max: int = 5950
    exposure_r_raw_10ns: int = 1_000_000
    exposure_g_raw_10ns: int = 1_000_000
    exposure_b_raw_10ns: int = 1_000_000
    samples_per_scan: int = 1
    negative: bool = True

    @property
    def n_colors(self) -> int:
        return 4 if self.rgbi else 3

    @property
    def pitch(self) -> int:
        return 4000 // self.dpi

    @property
    def logical_width(self) -> int:
        return (self.x_max - self.x_min + 1) // self.pitch

    @property
    def logical_height(self) -> int:
        return (self.y_max - self.y_min + 1) // self.pitch

    @property
    def bytes_per_sample(self) -> int:
        return 2 if self.depth > 8 else 1

    @property
    def line_bytes_raw(self) -> int:
        return self.n_colors * self.logical_width * self.bytes_per_sample

    @property
    def line_bytes_padded(self) -> int:
        n = self.line_bytes_raw
        return ((n + 511) // 512) * 512

    @property
    def stream_bytes(self) -> int:
        return self.line_bytes_padded * self.logical_height


class Ls50Session:
    """Stateful raw-USB LS-50 session (bounded by one RELEASE)."""

    def __init__(self, *, bus: int | None = None, address: int | None = None) -> None:
        self._bus = bus
        self._address = address
        self._dev: Any | None = None
        self._ep_out: Any | None = None
        self._ep_in: Any | None = None
        self._util: Any | None = None

    # -- transport ---------------------------------------------------------

    def __enter__(self) -> "Ls50Session":
        self.open()
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.close()

    def open(self) -> None:
        self._dev, _intf, self._ep_out, self._ep_in, self._util = _connect_device(
            expected_scanner_product="LS-50 ED",
            expected_usb_bus=self._bus,
            expected_usb_address=self._address,
        )

    def close(self) -> None:
        if self._util is not None and self._dev is not None:
            try:
                self._release()
            except Exception:
                pass
            self._util.dispose_resources(self._dev)
            self._dev = self._ep_out = self._ep_in = self._util = None

    def _perf(self, *, cdb: str, name: str, data_out: str | None = None,
              req_len: int | None = None, parts: list[int] | None = None,
              phase: int | None = None, sense: str = "000000") -> Any:
        entry: dict[str, Any] = {
            "seq": 0, "name": name, "cdb": cdb,
            "expected_phase": phase or (2 if data_out is not None else 3),
            "expected_sense": sense,
        }
        if data_out is not None:
            entry["data_out"] = data_out
        if req_len is not None:
            entry["request_len"] = req_len
            entry["request_parts"] = parts or [req_len]
        result = perform_transaction(self._ep_out, self._ep_in, entry, data_timeout_ms=120_000)
        if result.sense not in ("000000", "", "098006", "098001"):
            raise Ls50CaptureError(f"{name} failed: sense {result.sense} status {result.status.hex()}")
        return result

    def _turb_unit_ready(self, max_polls: int = 300) -> None:
        for poll in range(max_polls):
            result = perform_transaction(
                self._ep_out, self._ep_in,
                {"seq": 0, "name": "TEST_UNIT_READY", "cdb": "000000000000"},
                data_timeout_ms=30_000,
            )
            if result.sense in ("000000", ""):
                return
            # A unit-recovered/not-ready sense is fine to keep polling; a
            # hard ILLEGAL REQUEST (05xx) or a USB timeout after repeated
            # tries means the device desynced rather than "still working".
            if poll == max_polls // 2 and result.sense.startswith("05"):
                raise Ls50CaptureError(
                    f"LS-50 returned {result.sense} while waiting to be ready"
                )
            time.sleep(1)
        raise Ls50CaptureError("LS-50 did not become ready")

    def _release(self) -> None:
        try:
            perform_transaction(
                self._ep_out, self._ep_in,
                {"seq": 0, "name": "RELEASE_UNIT", "cdb": "170000000000"},
                data_timeout_ms=10_000,
            )
        except Exception:
            pass

    # -- scan --------------------------------------------------------------

    def _set_boundary(self, n_frames: int) -> None:
        resy_max = 5950
        # SANE coolscan3's exact formula (backend/coolscan3.c): 1.5x resy_max + 1.
        # Proven working against the physical LS-50 in the bring-up probe; a
        # pitch-5959 boundary (5959 end) is rejected with 052400.
        frame_offset = int(resy_max * 1.5 + 1)
        boundaryx = 3940
        blk = 4 + n_frames * 16
        payload = bytearray.fromhex("2a0088000003")
        payload += blk.to_bytes(3, "big")
        payload += b"\x00"
        payload += (blk >> 8).to_bytes(1, "big")
        payload += (blk & 0xFF).to_bytes(1, "big")
        payload += bytes([n_frames, n_frames])
        for i in range(n_frames):
            start = frame_offset * i
            payload += start.to_bytes(4, "big")
            payload += (0).to_bytes(4, "big")
            payload += (start + frame_offset - 1).to_bytes(4, "big")
            payload += (boundaryx - 1).to_bytes(4, "big")
        self._perf(cdb="2a0088000003", name="SET_BOUNDARY", data_out=payload.hex(), phase=2)

    def _set_window(self, opt: Ls50ScanOptions, color: int) -> None:
        w = bytearray(58)
        w[0:8] = bytes.fromhex("0000000000000032")
        w[8] = color
        w[10:12] = opt.dpi.to_bytes(2, "big")
        w[12:14] = opt.dpi.to_bytes(2, "big")
        w[14:18] = (0).to_bytes(4, "big")
        w[18:22] = (opt.y_min).to_bytes(4, "big")  # upper-left y = frame's native origin
        w[22:26] = ((opt.x_max - opt.x_min + 1)).to_bytes(4, "big")
        w[26:30] = ((opt.y_max - opt.y_min + 1)).to_bytes(4, "big")
        w[33] = 0x05
        w[34] = opt.depth
        w[35:48] = bytes(13)
        w[48] = ((opt.samples_per_scan - 1) << 4) & 0xF0
        # avg_negpos byte. Empirically confirmed on the LS-50 (RGBI path,
        # which is what the calibration workflow uses): byte 0x81 outputs the
        # RAW FILM NEGATIVE (dense base ~160s, inverted-looking colors), and
        # byte 0x80 outputs the scanner-inverted POSITIVE (natural colors,
        # base ~24). `negative=True` (the film IS a negative) -> emit the raw
        # negative -> 0x81. This matches the operator's archived reference
        # captures (ls50-fullneg) exactly.
        w[49] = 0x81 if opt.negative else 0x80
        w[50] = 0x01
        w[51] = 0x02 if opt.samples_per_scan == 1 else 0x10
        w[52] = 0x02
        w[53] = 0xFF
        exposure = {1: opt.exposure_r_raw_10ns, 2: opt.exposure_g_raw_10ns,
                    3: opt.exposure_b_raw_10ns, 9: 0}.get(color, 1_000_000)
        w[54:58] = (exposure).to_bytes(4, "big")
        self._perf(cdb="24000000000000003a80", name=f"SET_WINDOW c{color}",
                   data_out=w.hex(), phase=2)

    def _seek_frame(self, opt: Ls50ScanOptions) -> None:
        """Move the transport to the windowed frame position.

        Mirror of the LS-5000 replay's AUTOFOCUS-EXECUTE seek: send
        ``e0 00 a0`` with the frame's centre Y, then EXECUTE ``c1``, then
        wait ready.  Without this the window-origin change alone does not
        advance the film and every frame scans the same physical spot.
        """
        seek_y = opt.y_min + (opt.y_max - opt.y_min + 1) // 2
        payload = bytearray(9)
        payload[1:5] = (0).to_bytes(4, "big")  # focusX (0 = scan width centre)
        payload[5:9] = seek_y.to_bytes(4, "big")
        try:
            self._perf(cdb="e000a000000000000900", name="AUTOFOCUS_EXEC",
                       data_out=payload.hex(), phase=2)
        except Ls50CaptureError:
            # Status-only / variants are tolerated; the EXECUTE below is what
            # actually steps the transport.
            pass
        self._perf(cdb="c10000000000", name="EXECUTE", phase=1)
        self._turb_unit_ready()

    def _scan(self, opt: Ls50ScanOptions) -> None:
        mask = "09010203" if opt.rgbi else "010203"
        cdb = "1b0000000400" if opt.rgbi else "1b0000000300"
        # The LS-50 can be slow to leave the not-ready state right after a
        # fresh seek (observed on the very first slot of a session). Retry
        # the whole seek + SCAN once with a bounded ready wait before
        # giving up, so a slow-but-working unit succeeds and a genuinely
        # wedged unit fails fast (the caller skips the slot).
        for attempt in range(2):
            if getattr(opt, "_seeked", False) is not True:
                self._seek_frame(opt)
            # First SCAN returns 098006 (REISSUE) which is the expected arm;
            # reissue once and the second returns the terminal sense.
            first = self._perf(cdb=cdb, name="SCAN", data_out=mask,
                               phase=1, sense="098006")
            if first.sense == "098006":
                entry = {"seq": 0, "name": "SCAN(reissue)", "cdb": cdb,
                         "data_out": mask, "expected_phase": 1,
                         "expected_sense": "098001"}
                second = perform_transaction(self._ep_out, self._ep_in, entry,
                                             data_timeout_ms=120_000)
                if second.sense not in ("000000", "098001", ""):
                    raise Ls50CaptureError(
                        f"SCAN(reissue) failed: sense {second.sense} status {second.status.hex()}"
                    )
            try:
                # Bounded ready wait: a wedged slot skips in ~60s, a
                # slow-but-working scan gets one full retry.
                self._turb_unit_ready(max_polls=60)
                return
            except Ls50CaptureError:
                if attempt == 0:
                    continue
                raise

    def _read_lines(self, opt: Ls50ScanOptions) -> bytes:
        """Read the image stream in large chunks, Nikon data-type READ.

        Ported from the nkscan driver's wire model (Nikon LS-5000/LS-9000
        spec, identical to the LS-50): an image READ(10) carries the data
        type code (DTC) in byte 2 and the data type qualifier (DTQ =
        color << 8 | element width code) in bytes 4-5, the transfer length in
        bytes 6-8, and Nikon's vendor control byte 0x80 in byte 9.  The host
        asks for a whole number of granules in as few READs as the transport
        allows, and a READ that comes back short, or with sense 05/2C
        (ILI / OutOfSequence), simply means the unit reported the end of the
        image -- normal, not an error.  This replaces the fragile per-line
        READs that desynchronized the LS-50's stream.
        """
        # Element width code: 1 byte -> 0x00, 2 bytes -> 0x01, 4 bytes -> 0x03.
        width_code = {1: 0x00, 2: 0x01, 4: 0x03}[opt.bytes_per_sample]
        dtc = 0x00  # DataType::Image
        # DTQ = color element << 8 | element width.  The color for the first
        # image plane is 0 (nkscan reads the interleaved pass through the scan
        # windows, so the leading color element is channel 0 -- R).
        # nkscan passes the window's color id; for a multi-channel pass the
        # unit interleaves, so reading color 0 with the pass's channel set is
        # what channels the whole stream.
        color = 0
        dtq = (color << 8) | width_code

        # Chunk bound: the transport's max transfer.  libusb bulk is 1 MiB;
        # keep a conservative 64 KiB reader so a unit with a small SCSI
        # buffer (32 KiB on some Coolscans) never over-asks.
        chunk = min(opt.stream_bytes, 1 << 16)
        out = bytearray()
        remaining = opt.stream_bytes
        deadline_budget = 300  # seconds
        import time
        start = time.monotonic()
        while remaining > 0:
            if time.monotonic() - start > deadline_budget:
                raise Ls50CaptureError("image READ stalled; no data for 300s")
            want = min(chunk, remaining)
            # Round DOWN to a whole granule.  The granule for a single-line
            # 8/16-bit stream is 1 (nkscan Layout default), so `want` is fine.
            cdb = bytearray(10)
            cdb[0] = 0x28
            cdb[2] = dtc
            cdb[4:6] = dtq.to_bytes(2, "big")
            cdb[6:9] = want.to_bytes(3, "big")
            cdb[9] = 0x80  # Nikon vendor control byte
            result = perform_transaction(
                self._ep_out, self._ep_in,
                {"seq": 0, "name": "READ", "cdb": cdb.hex(),
                 "request_len": want, "request_parts": [want],
                 "expected_phase": 3, "expected_sense": "000000"},
                data_timeout_ms=120_000,
            )
            payload = result.payload
            got = len(payload)
            if result.phase != 3 or got == 0:
                # 2-11-5: a short/zero READ is how the unit says the image is
                # spent.  Do not treat it as a device error.
                if got < want or result.sense != "000000":
                    break
                raise Ls50CaptureError(
                    f"image READ phase {result.phase} sense {result.sense}"
                )
            out += payload
            remaining -= got
            if got < want:
                # A short read signals end-of-stream (ILI per 2-11).
                break
        return bytes(out)

    def capture(self, opt: Ls50ScanOptions, *, n_frames_boundary: int = 1,
                boundary_best_effort: bool = True) -> bytes:
        """Run the full RGBI capture and return the padded line-interleaved stream.

        ``boundary_best_effort`` tolerates the LS-50's state-dependent
        SET_BOUNDARY refusal (sense 052400 can be returned on a warm unit);
        the brought-up capture path proceeds and streams data regardless, as
        proven against the physical unit.
        """
        self._turb_unit_ready()
        self._perf(cdb="160000000000", name="RESERVE", phase=1)
        # MODE_SELECT is best-effort...
        try:
            self._perf(cdb="151000001400", name="MODE_SELECT",
                       data_out="000000080000000000000001030600000fa00000", phase=2)
        except Ls50CaptureError:
            pass
        if boundary_best_effort:
            try:
                self._set_boundary(n_frames_boundary)
            except Ls50CaptureError:
                pass
        else:
            self._set_boundary(n_frames_boundary)
        colors = (9, 1, 2, 3) if opt.rgbi else (1, 2, 3)
        for color in colors:
            self._set_window(opt, color)
        self._scan(opt)
        return self._read_lines(opt)


def capture_rgbi(
    *,
    dpi: int = 400,
    depth: int = 8,
    rgbi: bool = True,
    bus: int | None = None,
    address: int | None = None,
    n_frames_boundary: int = 1,
    **window_overrides: Any,
) -> bytes:
    """One-shot LS-50 RGBI raw capture. Returns the padded interleaved bytes."""
    opt = Ls50ScanOptions(dpi=dpi, depth=depth, rgbi=rgbi, **window_overrides)
    with Ls50Session(bus=bus, address=address) as session:
        return session.capture(opt, n_frames_boundary=n_frames_boundary)