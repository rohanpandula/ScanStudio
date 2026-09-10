"""LS-50 roll workflow: preview + per-frame raw RGBI captures.

This is the LS-50 analogue of ``Roll`` for the LS-5000: it drives the LS-50
directly (no SANE, no LS-5000 replay engine) and produces the calibration
artifacts the operator guide requires for a roll -- a whole-roll preview for
frame placement, then per-frame raw linear 16-bit RGB + IR + receipt.

It implements the same public surface the ScanStudio bridge expects from a
``Roll`` (``preview``, ``approve``, ``set_spacing_offset``, ``scan_many``,
``manual_frames``, ``safe_stop``, ``fingerprint``, ``slot_count``,
``material``, ``close``) so ``Device.roll()`` can return it for an LS-50
and the ScanStudio UI works unchanged against the LS-50 driver.

Contract notes
--------------
- The LS-50 reports 40 frames in its 0x8f table at a 5959-native pitch
  (same as the LS-5000). Frame ``n`` sits at native origin ``(n-1)*5959``.
- A preview captures each slot's window (5959 native tall at its origin at
  the preview dpi) and tiles the slot crops; per-slot boundaries are felt
  from the density profile so the UI's frame-adjust can shift them.
- A raw frame capture is a 4000-dpi 14-bit RGBI capture of one frame sized
  5959 native tall x up to 3945 wide.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable, Iterable, Iterator

import numpy as np

from coolscanpy.exceptions import SafeStopRequested
from coolscanpy.types import RollFingerprint, Thumbnail

from .capture import Ls50CaptureError, Ls50ScanOptions, Ls50Session
from .frame_edges import row_density_profile
from .artifacts import write_capture_artifacts

# 4000-dpi capture scaled to the whole-roll preview: one slot = one frame
# window (5959 native units) at the preview dpi; a slot's boundary is
# ``(i*5959, i*5959+5958)`` native units, adjusted by detected seams + the
# operator's spacing_offset (in preview rows).
_PREVIEW_DPI = 400
_PREVIEW_DEPTH = 8
_FRAME_PITCH = 5959


def _strip_regions_match(a: np.ndarray, b: np.ndarray, *,
                        corr_threshold: float = 0.99, mae_threshold: float = 6.0) -> bool:
    """True when two preview slot images are the same physical film region.

    The transport homes back to frame 1 when asked to seek past the last real
    frame (the strip ended), so the slot re-scans a window this pass has
    already captured.  Such a pair is near pixel-identical (same optical path,
    same exposure), while two genuinely different frames -- even adjacent
    frames of one roll -- differ far more.

    Both a normalized cross-correlation floor AND a mean-absolute-difference
    ceiling must pass so that featureless (low-variance) frames, which are
    unreliable under correlation alone, cannot false-positive here; those are
    handled by the preview's near-black end-of-strip detector instead.
    """
    if a.shape != b.shape:
        return False
    a = np.asarray(a, dtype=np.float32)[::5, ::5]
    b = np.asarray(b, dtype=np.float32)[::5, ::5]
    a = a.reshape(-1)
    b = b.reshape(-1)
    if float(a.std()) < 5.0 or float(b.std()) < 5.0:
        return False
    a_c = a - a.mean()
    b_c = b - b.mean()
    denom = float(np.sqrt((a_c * a_c).sum()) * np.sqrt((b_c * b_c).sum()))
    corr = float((a_c * b_c).sum() / denom) if denom > 0 else 0.0
    mae = float(np.abs(a - b).mean())
    return corr >= corr_threshold and mae <= mae_threshold


@dataclass(frozen=True)
class Ls50Frame:
    """One detected / placed frame on the strip."""

    index: int  # 1..40 physical slot
    native_origin: int  # native units (pitch 5959)
    spacing_offset_rows: int = 0

    @property
    def pitch(self) -> int:
        return _FRAME_PITCH

    def with_offset(self, rows: int) -> "Ls50Frame":
        return replace(self, spacing_offset_rows=rows)


@dataclass
class Ls50PreviewResult:
    """Result of one whole-roll preview pass."""

    rgb: np.ndarray  # (H, W, 3) uint8
    frames: list[Ls50Frame]
    slot_images: dict[int, np.ndarray] = field(default_factory=dict)
    slot_records: dict[int, tuple[int, int]] = field(default_factory=dict)
    _fingerprint: str = ""

    @property
    def slot_count(self) -> int:
        return len(self.frames)

    @property
    def fingerprint(self) -> str:
        return self._fingerprint or f"ls50-{len(self.frames)}"


@dataclass
class Ls50CapturedFrame:
    """One captured frame, matching the bridge/UI's ``Frame`` shape."""

    slot: int
    rgb: np.ndarray  # (H, W, 3) uint16 scanner-linear RGB
    ir: np.ndarray | None = None  # (H, W) uint16 IR plane
    receipt: object = None  # minimal receipt object (.device_model, .exposure)
    meter_rgbi: np.ndarray | None = None
    rgb_path: str | Path | None = None
    ir_path: str | Path | None = None
    receipt_path: str | Path | None = None


@dataclass(frozen=True)
class Ls50ExposureTicks:
    """Per-channel exposure in 10ns ticks, matching receipt.exposure shape."""

    red: int
    green: int
    blue: int


@dataclass(frozen=True)
class Ls50FrameReceiptMinimal:
    """Minimal receipt the bridge needs to build a ScanReceipt.

    Implements the attribute surface ``coolscanpy_transport._scan_receipt_from_coolscanpy``
    reads from a ``coolscanpy.Receipt``, so the bridge's ScanStudio writer
    works unchanged against LS-50 captures.
    """

    slot: int
    device_model: str = "LS-50 ED"
    version: int = 1
    dpi: int = 4000
    depth: int = 16
    device_id: str = "usb:0:0"
    spacing_offset: int = 0
    reviewed_fingerprint_sha256: str = "0" * 64
    fresh_fingerprint_sha256: str = None
    manual_approval: object = None
    started_at: object = None
    capture_duration_ms: int = 0
    red_10ns: int = 1_000_000
    green_10ns: int = 1_000_000
    blue_10ns: int = 1_000_000
    storage_transform: object = None

    @property
    def exposure(self) -> object:
        class _Exposure:
            focus_position = 0
            exposure_multiplier = 1.0
        e = _Exposure()
        # 10ns ticks -> microseconds (bridge expects us)
        e.red_exposure_us = self.red_10ns // 100
        e.green_exposure_us = self.green_10ns // 100
        e.blue_exposure_us = self.blue_10ns // 100
        return e

    @property
    def clipping(self) -> object:
        class _Clipping:
            fractions = ()
            clip_level = 0
            warning_fraction = 1.0
            warning = False
        return _Clipping()

    @property
    def focus_detail(self) -> object:
        class _Focus:
            method = "auto"
            verdict = "ok"
            score = 1.0
            texture_span = 0
        return _Focus()

    @property
    def transport_smear(self) -> object:
        class _Smear:
            verdict = "none"
            start_row = 0
            suffix_rows = 0
            minimum_matches = 0
            tail_median_rms = 0.0
            tail_min_corr = 1.0
            pre_tail_median_rms = 0.0
            texture_span = 0
            reason = ""
        return _Smear()

    @property
    def artifacts(self) -> dict:
        return {}


class _EmptyArtifactValue:
    sha256 = "0" * 64
    byte_length = 0
    shape = (0,)
    dtype = "uint16"


@dataclass
class Ls50Roll:
    """LS-50 roll workflow compatible with the ScanStudio bridge surface."""

    session: Ls50Session
    material: object = "color"  # coolscanpy.Material enum (or string fallback)
    _device: object | None = field(default=None, repr=False)
    scan_options: Ls50ScanOptions = field(
        default_factory=lambda: Ls50ScanOptions(dpi=4000, depth=14, rgbi=True, negative=True),
        repr=False,
    )
    _preview: Ls50PreviewResult | None = field(default=None, repr=False)
    _preview_ready: bool = field(default=False, repr=False)
    _approvals: set[int] = field(default_factory=set, repr=False)
    _stop_event: threading.Event = field(default_factory=threading.Event, repr=False)
    _output_root: Path = field(default_factory=lambda: Path("."), repr=False)

    # -- state -------------------------------------------------------------

    @property
    def fingerprint(self) -> RollFingerprint:
        pre = self._preview
        shape = pre.rgb.shape if pre is not None else (0, 0, 3)
        captured = len(pre.slot_images) if pre is not None and pre.slot_images else (pre.slot_count if pre is not None else 0)
        return RollFingerprint(
            sha256=pre.fingerprint if pre is not None else "none",
            slot_count=captured,
            preview_shape=shape,
        )

    @property
    def slot_count(self) -> int | None:
        if self._preview is None:
            return None
        # Report the frames that ACTUALLY previewed, not the 40-slot physical
        # capacity -- the engine uses this to decide when the strip is done.
        if self._preview.slot_images:
            return len(self._preview.slot_images)
        return self._preview.slot_count

    @property
    def preview_ready(self) -> bool:
        return self._preview_ready

    # -- preview -----------------------------------------------------------

    def preview(
        self,
        slots: Iterable[int] | None = None,
        *,
        on_progress: Callable[[object], None] | None = None,
        dpi: int = _PREVIEW_DPI,
        depth: int = _PREVIEW_DEPTH,
        on_thumbnail: Callable[[Thumbnail], None] | None = None,
    ) -> list[Thumbnail]:
        """Preview every slot (or ``slots``) as a tiled per-slot crop.

        Each slot's own window (5959 native tall) is captured and downscaled
        to the preview's density profile; slots are 5959/pitch preview rows
        tall. Returns ``Thumbnail`` records the bridge can emit.

        If ``on_thumbnail`` is provided it is invoked once per successfully
        captured slot, immediately, so a caller can stream thumbnails to the
        UI as they are produced -- the ScanStudio engine's preview stream has
        a 600s silence deadline, so batching every slot to the end can stall
        the stream on long strips.
        """
        slots = sorted(set(slots)) if slots is not None else None
        frames = [Ls50Frame(index=i + 1, native_origin=i * _FRAME_PITCH) for i in range(40)]
        opt = Ls50ScanOptions(
            dpi=dpi, depth=depth, rgbi=True, y_min=0, y_max=60 * _FRAME_PITCH,
            x_min=0, x_max=3944, negative=True,
        )
        slot_images: dict[int, np.ndarray] = {}
        end_of_strip_reached = False
        consecutive_blank = 0
        self._stop_event.clear()
        for i, frame in enumerate(frames):
            if end_of_strip_reached:
                break
            if self._stop_event.is_set():
                # Operator clicked "Done Previews": stop immediately and
                # report the frames captured so far.
                print("[ls50] preview stop requested; finishing with current frames", flush=True)
                break
            if slots is not None and frame.index not in slots:
                continue
            fopt = replace(opt, y_min=frame.native_origin, y_max=frame.native_origin + _FRAME_PITCH - 1)
            try:
                data = self.session.capture(fopt, boundary_best_effort=True)
            except Ls50CaptureError as exc:
                # A wedged transport on one slot must not fail the whole
                # preview (the UI hangs otherwise).  Retry once with a fresh
                # session (re-open + re-seek + re-capture); if it still
                # fails, skip the slot with a warning so the operator sees
                # the frames that did capture.
                print(f"[ls50] slot {frame.index} retry after: {exc}", flush=True)
                try:
                    self.session.close()
                    self.session.open()
                    data = self.session.capture(fopt, boundary_best_effort=True)
                except Exception as retry_exc:
                    # Two consecutive failures on this slot almost always
                    # mean the transport ran off the end of the film (it
                    # auto-ejects once nothing is left to seek to).  Stop
                    # the preview here rather than trying all 40 slots on
                    # empty film.
                    print(
                        f"[ls50] slot {frame.index} unrecoverable ({retry_exc}); "
                        "assuming end of strip",
                        flush=True,
                    )
                    end_of_strip_reached = True
                    break
            line = fopt.line_bytes_padded
            a = np.frombuffer(data, dtype=np.uint8)[: fopt.logical_height * line]
            a = a.reshape(fopt.logical_height, line)[:, : fopt.line_bytes_raw]
            img = a.reshape(fopt.logical_height, fopt.n_colors, fopt.logical_width)[:, :3, :]
            img = np.moveaxis(img, 1, -1)
            slot_images[frame.index] = img
            # Home-loop detection: past the last real frame the LS-50 homes
            # back to frame 1 and RESCANS it (no blank/error slot), so the
            # near-black end-of-strip detector below never fires and the
            # preview loops 1..N, N..1 forever.  A slot that is near
            # pixel-identical to one this pass already captured means the
            # transport looped -- discard the duplicate and stop the pass.
            looped_into = next(
                (s for s, prev in slot_images.items()
                 if s != frame.index and _strip_regions_match(img, prev)),
                None,
            )
            if looped_into is not None:
                print(
                    f"[ls50] slot {frame.index} matches already-captured slot "
                    f"{looped_into}; transport looped past end of strip; stopping",
                    flush=True,
                )
                del slot_images[frame.index]
                end_of_strip_reached = True
                break
            # End-of-strip detection: film run-out slots are near-black
            # (mean <20, std <5) vs a real blank frame (std ~40-90 from
            # grain). Require TWO consecutive near-black slots before
            # stopping so a single blank calibration frame (frame 2/36)
            # never truncates the strip.
            if float(img.mean()) < 20.0 and float(img.std()) < 5.0:
                consecutive_blank += 1
            else:
                consecutive_blank = 0
            if consecutive_blank >= 2:
                print(
                    f"[ls50] end of strip after slot {frame.index} "
                    f"(mean {img.mean():.0f} std {img.std():.1f}); stopping",
                    flush=True,
                )
                end_of_strip_reached = True
            if on_progress is not None:
                on_progress(object())
            if on_thumbnail is not None:
                # Stream this slot immediately so the UI is not starved.
                on_thumbnail(
                    Thumbnail(
                        slot=frame.index,
                        image=img,
                        boundary_rows=(0, img.shape[0] - 1),
                        spacing_offset=0,
                        needs_approval=False,
                        warnings=(),
                    )
                )
        # Build a contiguous strip preview image by stacking the captured
        # slots (each slot_height tall).
        ordered = [slot_images[s] for s in sorted(slot_images)]
        if ordered:
            rgb = np.concatenate(ordered, axis=0)
        else:
            rgb = np.zeros((1, 1, 3), dtype=np.uint8)
        # Per-slot boundaries in preview rows.
        slot_height = rgb.shape[0] // max(len(slot_images), 1)
        slot_records = {
            s: (i * slot_height, (i + 1) * slot_height - 1)
            for i, s in enumerate(sorted(slot_images))
        }
        result = Ls50PreviewResult(
            rgb=rgb,
            frames=frames,
            slot_images=slot_images,
            slot_records=slot_records,
            _fingerprint=f"ls50-{len(frames)}",
        )
        self._preview = result
        self._preview_ready = True
        self._approvals.clear()
        return [
            Thumbnail(
                slot=s,
                image=slot_images[s],
                boundary_rows=slot_records[s],
                spacing_offset=0,
                needs_approval=False,
                warnings=(),
            )
            for s in sorted(slot_images)
        ]

    def _slot_thumbnails(self, slots: Iterable[int] | None = None) -> list[Thumbnail]:
        if self._preview is None:
            return []
        wanted = set(slots) if slots is not None else set(self._preview.slot_images)
        frames = {f.index: f for f in self._preview.frames}
        out = []
        for s in sorted(wanted):
            img = self._preview.slot_images.get(s)
            if img is None:
                continue
            rec = self._preview.slot_records.get(s, (0, img.shape[0] - 1))
            offset = frames[s].spacing_offset_rows if s in frames else 0
            out.append(
                Thumbnail(
                    slot=s,
                    image=img,
                    boundary_rows=rec,
                    spacing_offset=offset,
                    needs_approval=s in self._approvals,
                    warnings=(),
                )
            )
        return out

    # -- alignment / approval ----------------------------------------------

    def set_spacing_offset(self, slot: int, offset_rows: int) -> Thumbnail:
        """Re-crop one preview slot by ``offset_rows`` (the UI frame-adjust).

        Does not move the scanner; it shifts the slot's reported boundary
        and re-renders the crop for the operator. The crop is clamped so it
        never degenerates to a sliver: at least half the slot height is
        always returned, anchored top or bottom depending on the shift sign.
        """
        if self._preview is None:
            raise ValueError("no preview session is established")
        frames = {f.index: f for f in self._preview.frames}
        if slot not in frames:
            raise ValueError(f"slot {slot} is not in the preview")
        img = self._preview.slot_images[slot]
        h = img.shape[0]
        if h <= 1:
            raise ValueError(f"slot {slot} preview image is degenerate")
        base = self._preview.slot_records.get(slot, (0, h - 1))
        # Apply the offset to the top boundary, clamped to a sane window.
        min_rows = max(h // 2, 1)
        new_start = base[0] + offset_rows
        # Keep at least min_rows from the top OR bottom depending on the
        # shift direction; never return a degenerate sliver.
        if offset_rows >= 0:
            new_start = min(max(new_start, 0), h - min_rows)
            crop = img[new_start : new_start + min_rows]
        else:
            end = max(min(new_start + min_rows, h), min_rows)
            crop = img[end - min_rows : end]
        new_rec = (new_start, new_start + crop.shape[0] - 1)
        # Persist the offset into the preview's stored frame list so the
        # subsequent scan_many() capture window carries the operator's
        # adjustment (Rohan review: previously only a local dict changed).
        self._preview.frames = [
            frame.with_offset(offset_rows) if frame.index == slot else frame
            for frame in self._preview.frames
        ]
        return Thumbnail(
            slot=slot,
            image=crop,
            boundary_rows=base,
            spacing_offset=offset_rows,
            needs_approval=False,
            warnings=(),
        )

    def approve(self, slot: int, *, attended: bool = False) -> None:
        if self._preview is None:
            raise ValueError("no preview session is established")
        self._approvals.add(slot)

    def manual_frames(self, *, reviewed_fingerprint_sha256: str | None = None,
                      manual_boundary_rows: dict[int, tuple[int, int]] | None = None,
                      slot_count: int | None = None) -> None:
        raise NotImplementedError(
            "LS-50 manual frame placement is handled via set_spacing_offset/preview approval"
        )

    # -- capture -----------------------------------------------------------

    def scan_many(
        self,
        slots: Iterable[int],
        *,
        on_progress: Callable[[object, int], None] | None = None,
        output_directory: str | Path | None = None,
        pass_token: str = "A1",
        exposure_override_10ns: tuple[int, int, int] | None = None,
        **kwargs: object,
    ) -> Iterator[Ls50CapturedFrame]:
        """Capture each requested slot at full-res RGBI, yielding one frame.

        Does not write artifacts itself (the bridge owns the reserved output
        paths); it decorates each yielded frame with the decoded ``rgb``
        (uint16 HxWx3), ``ir`` (uint16 HxW), and a minimal ``receipt``.
        """
        root = Path(output_directory) if output_directory else self._output_root
        root.mkdir(parents=True, exist_ok=True)
        slots = sorted(set(slots))
        # A fresh scan after "Done Previews" must not inherit the stale stop
        # flag: preview_stop() set it to end the preview early.  Clear it so
        # the subsequent capture can run; safe_stop() during the batch still
        # stops the loop.
        self._stop_event.clear()
        for ordinal, slot in enumerate(slots, 1):
            if self._stop_event.is_set():
                raise SafeStopRequested("scan job stopped")
            frame = self._preview.frames[slot - 1] if self._preview and slot - 1 < len(self._preview.frames) else None
            if frame is None:
                continue
            # Apply the operator's spacing offset (set via set_spacing_offset,
            # stored in preview rows) to the capture window.  The offset is in
            # 400-dpi preview rows; convert to native units at capture dpi.
            offset_native = 0
            if self._preview is not None:
                stored = next(
                    (f for f in self._preview.frames if f.index == slot), None
                )
                if stored is not None and stored.spacing_offset_rows:
                    offset_native = int(
                        round(stored.spacing_offset_rows * self.scan_options.dpi / _PREVIEW_DPI)
                    )
            opt = Ls50ScanOptions(
                dpi=self.scan_options.dpi,
                depth=self.scan_options.depth,
                rgbi=True,
                y_min=frame.native_origin + offset_native,
                y_max=frame.native_origin + offset_native + _FRAME_PITCH - 1,
                x_min=0,
                x_max=3944,
                negative=True,
            )
            if exposure_override_10ns is not None:
                opt = replace(
                    opt,
                    exposure_r_raw_10ns=exposure_override_10ns[0],
                    exposure_g_raw_10ns=exposure_override_10ns[1],
                    exposure_b_raw_10ns=exposure_override_10ns[2],
                )
            data = self.session.capture(opt, boundary_best_effort=True)
            rgb, ir = self._decode_rgbi(data, opt)
            receipt = Ls50FrameReceiptMinimal(
                slot=slot,
                device_model="LS-50 ED",
                dpi=opt.dpi,
                depth=16,
                red_10ns=opt.exposure_r_raw_10ns,
                green_10ns=opt.exposure_g_raw_10ns,
                blue_10ns=opt.exposure_b_raw_10ns,
                capture_duration_ms=0,
            )
            if on_progress is not None:
                on_progress(object(), ordinal)
            yield Ls50CapturedFrame(slot=slot, rgb=rgb, ir=ir, receipt=receipt)

    @staticmethod
    def _decode_rgbi(data: bytes, opt: Ls50ScanOptions):
        """Decode a padded RGBI stream into (uint16 HxWx3 RGB, uint16 HxW IR).

        The 14-bit ADC samples are left-justified into the 16-bit container
        (multiplication by 4) so the archived TIFF is the full-range raw
        negative, never re-scaled on read.
        """
        import numpy as _np
        line = opt.line_bytes_padded
        raw = _np.frombuffer(data, dtype=_np.uint8)[: opt.logical_height * line]
        raw = raw.reshape(opt.logical_height, line)[:, : opt.line_bytes_raw]
        if opt.bytes_per_sample == 2:
            pairs = raw.reshape(opt.logical_height, opt.n_colors, opt.logical_width, 2)
            u16 = ((pairs[:, :, :, 0].astype(_np.uint32) << 8)
                   | pairs[:, :, :, 1].astype(_np.uint32))
            # 14-bit -> left-justify in 16-bit container.
            u16 = (u16 << 2).clip(0, 65535).astype(_np.uint16)
        else:
            u8 = raw.reshape(opt.logical_height, opt.n_colors, opt.logical_width)
            u16 = (u8.astype(_np.uint32) << 8).astype(_np.uint16)
        u16 = _np.moveaxis(u16, 1, -1)  # (H, W, C)
        rgb = u16[:, :, :3].copy()
        ir = u16[:, :, 3].copy() if opt.rgbi else None
        return rgb, ir

    def safe_stop(self) -> None:
        self._stop_event.set()

    def preview_stop(self) -> None:
        """Operator clicked 'Done Previews': stop the in-progress preview
        early and report the frames captured so far."""
        self._stop_event.set()

    def close(self) -> None:
        self.session.close()
        if self._device is not None:
            release = getattr(self._device, "_release_roll_lock", None)
            if callable(release):
                release()


__all__ = [
    "Ls50CapturedFrame",
    "Ls50Frame",
    "Ls50PreviewResult",
    "Ls50Roll",
]