"""`MockTransport`: a deterministic, hardware-free `transport.Transport`
implementation with scripted retry/fault injection, used by every test that
exercises `scan.start`'s worker-loop shape without a real LS-5000 attached.
See BRIDGE.md (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md) for the wire-level contract this mirrors;
`CoolscanPyTransport` (transport/coolscanpy_transport.py) satisfies the
identical `Transport` contract against real hardware.
"""

from __future__ import annotations

import hashlib
import tempfile
import threading
import uuid
from pathlib import Path
from typing import Callable

import numpy as np
import tifffile

from scanstudio_bridge import domain, safety
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport import FrameRetryExhausted, OnCall, phased_call, timed_call
from scanstudio_bridge.transport.output_reservation import (
    OutputReservations,
    raw_export_for_slot,
    write_raw_export,
    write_tiff,
)

_DEVICE_ID = "mock-ls5000-0"
_SYNTHETIC_FRAME_SIDE = 64
_SYNTHETIC_PREVIEW_HEIGHT = 48
_SYNTHETIC_PREVIEW_WIDTH = 64
_SYNTHETIC_SMEAR_REASON = "synthetic transport-smear fault"
# Literal copy of coolscanpy.types.DIGITAL_ICE_STORAGE_TRANSFORM -- duplicated
# rather than imported because this module stays hardware-library-free (see
# coolscanpy_transport.py's module docstring: it is the one file allowed to
# import coolscanpy). Keep byte-identical to that constant.
_MOCK_STORAGE_TRANSFORM = "swapaxes01-scanner-native-to-nikon-render-parity-v2"


def _synthetic_rgb_frame() -> np.ndarray:
    return np.zeros((_SYNTHETIC_FRAME_SIDE, _SYNTHETIC_FRAME_SIDE, 3), dtype=np.uint16)


def _synthetic_ir_frame() -> np.ndarray:
    return np.zeros((_SYNTHETIC_FRAME_SIDE, _SYNTHETIC_FRAME_SIDE), dtype=np.uint16)


def _synthetic_meter_frame() -> np.ndarray:
    return np.zeros((_SYNTHETIC_FRAME_SIDE, _SYNTHETIC_FRAME_SIDE, 4), dtype=np.uint16)


def _synthetic_preview_tile(slot: int, offset_rows: int = 0) -> np.ndarray:
    """Return a deterministic landscape display tile with visible alignment."""

    y = np.arange(_SYNTHETIC_PREVIEW_HEIGHT, dtype=np.uint16)[:, np.newaxis]
    x = np.arange(_SYNTHETIC_PREVIEW_WIDTH, dtype=np.uint16)[np.newaxis, :]
    plane = ((x + y * 3 + slot * 37) % 256).astype(np.uint8)
    tile = np.repeat(plane[..., np.newaxis], 3, axis=2)
    # Mock tiles are already in display orientation. Native +rows advances
    # the crop window, which makes image content move left on display.
    return np.roll(tile, -offset_rows, axis=1)


def _validate_manual_rows(rows: object) -> None:
    """Mock-only structural check -- a deliberately loose shadow of
    coolscanpy's real `manual_frames.build_manual_detection` gates (structure,
    physical frame-height range, transport-table sanity). This mock has no
    raster or transport table to check against, so it only enforces what it
    can: at least 2 plain-integer rows, strictly increasing. See
    coolscanpy_transport.py's `manual_frames` for the real physical gates."""
    if not isinstance(rows, list) or len(rows) < 2:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "manual frame placement needs at least 2 boundary rows (1 frame); "
            f"only {len(rows) if isinstance(rows, list) else 0} were given",
        )
    if any(type(row) is not int or isinstance(row, bool) for row in rows):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "manual frame boundary rows must be plain integers",
        )
    if any(a >= b for a, b in zip(rows, rows[1:])):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "frame boundary rows must be placed in strictly increasing order, "
            "top to bottom of the preview",
        )


def _synthetic_receipt(
    *,
    slot: int,
    spacing_offset: int,
    recipe: domain.CaptureRecipe,
    rgb_path: str,
    ir_path: str | None,
    meter_rgbi_path: str | None,
    raw_export_path: str | None,
    raw_export_ir_path: str | None,
) -> domain.ScanReceipt:
    return domain.ScanReceipt(
        version=1,
        slot=slot,
        spacing_offset=spacing_offset,
        dpi=recipe.resolution_dpi,
        depth=recipe.bit_depth,
        device_id=_DEVICE_ID,
        device_model="SUPER COOLSCAN 5000 ED (mock)",
        reviewed_fingerprint_sha256="0" * 64,
        fresh_fingerprint_sha256="0" * 64,
        manual_approval=None,
        exposure=domain.ExposureVector(
            focus_position=0,
            exposure_multiplier=1.0,
            red_exposure_us=0.0,
            green_exposure_us=0.0,
            blue_exposure_us=0.0,
        ),
        split_alignment=None,
        clipping=domain.ClippingTelemetry(
            fractions=(0.0, 0.0, 0.0),
            clip_level=0.995,
            warning_fraction=0.02,
            warning=False,
        ),
        focus_detail=domain.FocusDetailTelemetry(
            method="laplacian-variance",
            verdict="measured",
            score=0.0,
            texture_span=0.0,
        ),
        transport_smear=domain.TransportSmearAssessment(
            verdict="clean",
            start_row=None,
            suffix_rows=0,
            minimum_matches=0,
            tail_median_rms=None,
            tail_min_corr=None,
            pre_tail_median_rms=None,
            texture_span=None,
            reason="synthetic mock frame, no transport read performed",
        ),
        artifacts={},
        storage_transform=_MOCK_STORAGE_TRANSFORM,
        rgb_path=rgb_path,
        ir_path=ir_path,
        meter_rgbi_path=meter_rgbi_path,
        # MockTransport has no persistent CoolscanPy attempts journal.
        attempts_root=None,
        raw_export_path=raw_export_path,
        raw_export_ir_path=raw_export_ir_path,
    )


class MockTransport:
    """Deterministic, hardware-free `Transport`. Satisfies
    `transport.Transport` structurally -- no explicit inheritance needed,
    it's a `Protocol`."""

    def __init__(
        self,
        slot_count: int = 6,
        fault_script: dict[int, int] | None = None,
        permanent_fault_slots: set[int] | None = None,
        enforce_fixed_recipe: bool = True,
        *,
        film_present: bool | None = True,
        preview_dir: Path | None = None,
    ) -> None:
        self._slot_count = slot_count
        self._fault_script = dict(fault_script) if fault_script else {}
        self._permanent_fault_slots = set(permanent_fault_slots) if permanent_fault_slots else set()
        self._enforce_fixed_recipe = enforce_fixed_recipe
        self._film_present = film_present
        # Self-isolating by default: never touches the real ~/.scanstudio
        # even by accident (mirrors this class's own hardware-free charter).
        self._preview_dir = (
            preview_dir
            if preview_dir is not None
            else Path(tempfile.mkdtemp(prefix="scanstudio-mock-preview-"))
        )

        self._connected = False
        self._device_id: str | None = None
        self._preview_established = False
        self._last_preview_material: domain.Material | None = None
        self._approved_slots: set[int] = set()
        self._needs_approval_slots: set[int] = set()
        self._spacing_offsets: dict[int, int] = {}
        self._scanning = False
        self._stop_event = threading.Event()
        # 2026-08-08 adversarial review, S1: the fingerprint the last
        # successful preview()/manual_frames() call returned -- mirrors the
        # real transport's `self._roll.fingerprint.sha256`, kept here since
        # this double has no real Roll object of its own. See approve()'s
        # own docstring for how this is used.
        self._fingerprint: str | None = None

    # -- device lifecycle -----------------------------------------------------

    def list_devices(self) -> list[domain.DeviceInfo]:
        return [self._device_info()]

    def open_device(self, device_id: str) -> domain.DeviceInfo:
        if self._connected:
            raise BridgeError(ErrorCode.ALREADY_CONNECTED, "a device is already open")
        if device_id != _DEVICE_ID:
            raise BridgeError(ErrorCode.DEVICE_NOT_FOUND, f"no such device: {device_id!r}")
        self._connected = True
        self._device_id = device_id
        self._preview_established = False
        self._last_preview_material = None
        self._approved_slots.clear()
        self._needs_approval_slots.clear()
        self._spacing_offsets.clear()
        self._fingerprint = None
        return self._device_info()

    def status(self) -> domain.DeviceStatus:
        self._require_connected()
        return domain.DeviceStatus(
            connected=self._connected,
            device_id=self._device_id,
            preview_established=self._preview_established,
            slot_count=self._slot_count if self._preview_established else None,
            active_job_id=None,
            lane_held=self._scanning,
            # Live-recomputed by service.py (Plan 08-03), which owns
            # safety.py's base_dir wiring -- the Transport layer has no
            # access to it.
            motion_armed=False,
            film_present=self._film_present,
            # The mock simulates the SA-30 strip feeder the real traces
            # were captured behind.
            adapter="36Strip",
        )

    def close_device(self) -> None:
        self._require_connected()
        if self._scanning:
            raise BridgeError(ErrorCode.HARDWARE_LANE_BUSY, "a scan job holds the hardware lane")
        self._connected = False
        self._device_id = None
        self._preview_established = False
        self._last_preview_material = None
        self._approved_slots.clear()
        self._needs_approval_slots.clear()
        self._spacing_offsets.clear()
        self._fingerprint = None

    # -- preview / approve ------------------------------------------------------

    def preview(
        self,
        material: domain.Material,
        slots: list[int] | None,
        on_thumbnail: Callable[[domain.Thumbnail], None],
    ) -> domain.PreviewResult:
        self._require_connected()
        self._approved_slots.clear()
        self._needs_approval_slots.clear()
        self._spacing_offsets.clear()
        wanted = None if slots is None else set(slots)

        for i in range(self._slot_count):
            slot = i + 1
            is_last = slot == self._slot_count
            if is_last:
                self._needs_approval_slots.add(slot)
            if wanted is not None and slot not in wanted:
                continue
            # Deterministic synthetic tile derived from slot -- a flat fill,
            # no real content to normalize (see coolscanpy_transport.py's
            # _normalize_preview_tile for the real-hardware equivalent).
            tile_path = self._preview_dir / f"slot-{slot:04d}.tif"
            tifffile.imwrite(
                tile_path, _synthetic_preview_tile(slot), photometric="rgb"
            )
            thumbnail = domain.Thumbnail(
                slot=slot,
                boundary_rows=(i * 1200, (i + 1) * 1200),
                spacing_offset=0,
                needs_approval=is_last,
                warnings=("ambiguous-content-tail-boundary",) if is_last else (),
                image_path=str(tile_path),
            )
            on_thumbnail(thumbnail)

        self._preview_established = True
        self._last_preview_material = material
        fingerprint = hashlib.sha256(f"{material}:{self._slot_count}".encode()).hexdigest()
        self._fingerprint = fingerprint
        return domain.PreviewResult(count=self._slot_count, fingerprint=fingerprint)

    def approve(self, slot: int, *, fingerprint: str | None = None) -> None:
        self._require_connected()
        # Additive (2026-08-08 adversarial review, S1) -- see
        # transport.Transport.approve's own docstring. `None` (the default,
        # and every pre-existing caller) skips the comparison entirely,
        # unchanged from before this parameter existed.
        if fingerprint is not None and self._fingerprint != fingerprint:
            raise BridgeError(
                ErrorCode.FINGERPRINT_REFUSED,
                "this approval was computed against an earlier preview session "
                "that no longer matches the roll's current state; acquire a "
                "fresh preview or placement and approve again",
            )
        if slot < 1 or slot > self._slot_count or slot not in self._needs_approval_slots:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"slot {slot} does not need approval")
        self._approved_slots.add(slot)

    def set_spacing_offset(
        self, slot: int, offset_rows: int
    ) -> domain.Thumbnail:
        self._require_connected()
        if self._scanning:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a scan job holds the hardware lane",
            )
        if not self._preview_established:
            raise BridgeError(
                ErrorCode.NO_PREVIEW,
                "roll.setSpacingOffset requires a completed roll.preview first",
            )
        if type(slot) is not int or not 1 <= slot <= self._slot_count:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"slot must be between 1 and {self._slot_count}",
            )
        minimum = 0 if slot == 1 else -144
        if type(offset_rows) is not int or not minimum <= offset_rows <= 144:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"offsetRows for slot {slot} must be between {minimum} and 144",
            )

        self._spacing_offsets[slot] = offset_rows
        self._approved_slots.discard(slot)
        tile_path = (
            self._preview_dir
            / f"slot-{slot:04d}-adjusted-{uuid.uuid4().hex}.tif"
        )
        try:
            tifffile.imwrite(
                tile_path,
                _synthetic_preview_tile(slot, offset_rows),
                photometric="rgb",
            )
        except Exception as exc:
            # Mirror the real adapter's fail-closed contract: the offset is
            # already part of this mock session, so a missing visible tile
            # invalidates preview registration before any scan can consume it.
            self._preview_established = False
            self._last_preview_material = None
            raise BridgeError(
                ErrorCode.INTERNAL,
                "frame alignment was applied, but the adjusted preview tile "
                "could not be persisted; preview registration was invalidated "
                f"and a fresh preview is required ({type(exc).__name__}: {exc})",
            ) from exc
        is_last = slot == self._slot_count
        return domain.Thumbnail(
            slot=slot,
            boundary_rows=((slot - 1) * 1200, slot * 1200),
            spacing_offset=offset_rows,
            needs_approval=is_last,
            warnings=("ambiguous-content-tail-boundary",) if is_last else (),
            image_path=str(tile_path),
        )

    # -- manual frame placement (Rung 4) -----------------------------------------

    def manual_frames(
        self, rows: list[int]
    ) -> tuple[
        domain.PreviewResult,
        tuple[domain.Thumbnail, ...],
        tuple[domain.BoundarySnap, ...],
        domain.Material,
    ]:
        self._require_connected()
        if self._scanning:
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "a scan job holds the hardware lane",
            )
        if not self._preview_established:
            raise BridgeError(
                ErrorCode.NO_PREVIEW,
                "manual frame placement requires a completed roll.preview attempt first",
            )
        _validate_manual_rows(rows)

        # A manual placement replaces the whole roll's addressable slot
        # lattice -- mirrors preview()'s own clear-and-rebuild of approval/
        # offset bookkeeping (real CoolscanPy: a fresh RollPreviewSession
        # with its own fixed, 1-based, contiguous slots).
        self._slot_count = len(rows) - 1
        self._approved_slots.clear()
        self._needs_approval_slots.clear()
        self._spacing_offsets.clear()

        thumbnails: list[domain.Thumbnail] = []
        snaps: list[domain.BoundarySnap] = []
        for i in range(self._slot_count):
            slot = i + 1
            self._needs_approval_slots.add(slot)
            tile_path = self._preview_dir / f"slot-{slot:04d}-manual.tif"
            tifffile.imwrite(
                tile_path, _synthetic_preview_tile(slot), photometric="rgb"
            )
            thumbnails.append(
                domain.Thumbnail(
                    slot=slot,
                    boundary_rows=(rows[i], rows[i + 1]),
                    spacing_offset=0,
                    needs_approval=True,
                    warnings=("user-picked",),
                    image_path=str(tile_path),
                )
            )
        # Deterministic, mock-only "snap": a picked row exactly divisible by
        # 100 is reported as having snapped 1 row -- exercises the wire
        # shape without needing real clear-film evidence. Real snap
        # detection lives entirely in coolscanpy_transport.py.
        for index, row in enumerate(rows):
            if row % 100 == 0 and row > 0:
                snaps.append(
                    domain.BoundarySnap(
                        boundary_index=index,
                        requested_row=row,
                        snapped_row=row - 1,
                        evidence_run=(row - 4, row + 4),
                    )
                )

        fingerprint = hashlib.sha256(
            f"manual:{tuple(rows)}".encode()
        ).hexdigest()
        self._fingerprint = fingerprint
        self._preview_established = True
        return (
            domain.PreviewResult(count=self._slot_count, fingerprint=fingerprint),
            tuple(thumbnails),
            tuple(snaps),
            self._last_preview_material,
        )

    def preview_strip(self) -> domain.PreviewStrip:
        self._require_connected()
        if not self._preview_established:
            raise BridgeError(
                ErrorCode.NO_PREVIEW,
                "roll.previewStrip requires a completed roll.preview attempt first",
            )
        # The wire contract promises the image's width axis carries exactly
        # row_count columns at pixels_per_row=1 (the real transport writes
        # the raster unresized). The mock keeps the file small by capping
        # the synthetic strip, so its REPORTED row_count is the written
        # width -- an honest miniature, never a contradiction the editor's
        # row-to-pixel mapping would silently mis-scale on (2026-08-08
        # second-opinion review, finding 2).
        row_count = min(self._slot_count * 1200, 4_096)
        tile_path = self._preview_dir / f"strip-{uuid.uuid4().hex}.tif"
        strip = np.zeros((_SYNTHETIC_PREVIEW_WIDTH, row_count, 3), dtype=np.uint8)
        tifffile.imwrite(tile_path, strip, photometric="rgb")
        return domain.PreviewStrip(
            image_path=str(tile_path), row_count=row_count, pixels_per_row=1
        )

    # -- scanning -----------------------------------------------------------------

    def start_scan(
        self,
        slots: list[int],
        recipe: domain.CaptureRecipe,
        output: domain.OutputSpec,
        on_progress: Callable[[domain.ScanProgress], None],
        on_retry: Callable[[int, int, str], None],
        on_frame: Callable[[int, domain.ScanReceipt], None],
        on_call: OnCall | None = None,
    ) -> domain.ScanSummary:
        self._require_connected()
        if self._enforce_fixed_recipe:
            if self._last_preview_material is None:
                raise BridgeError(
                    ErrorCode.NO_PREVIEW, "scan.start requires a completed roll.preview first"
                )
            domain.validate_capture_recipe(recipe, self._last_preview_material)

        # Reserve the complete possible artifact group before any mock scan
        # callback. This mirrors the real transport's create-only guarantee.
        reservations = OutputReservations.reserve(slots, recipe, output)
        self._stop_event.clear()
        self._scanning = True
        try:
            completed: list[int] = []
            failed: list[int] = []
            total = len(slots)
            for ordinal, slot in enumerate(slots):
                if self._stop_event.is_set():
                    break
                # Plan 10-09 (phase-boundary telemetry): mirrors
                # CoolscanPyTransport.start_scan's own fine_scan:slot{N}
                # "scan.phase" wrap around ONLY the scan-attempt retry loop
                # (_attempt_one_slot) -- NOT the file writes below, which
                # are separate, sequential, phased_call-wrapped siblings,
                # exactly like CoolscanPyTransport's own start_scan
                # structure (fine_scan:slot{N} exits before any
                # file_write.*:slot{N} phase begins). Raises
                # FrameRetryExhausted straight through timed_call (which
                # only observes it for telemetry, never swallows it) on
                # exhaustion, uncaught here -- matches
                # CoolscanPyTransport's identical propagation.
                timed_call(
                    on_call,
                    f"fine_scan:slot{slot}",
                    lambda: self._attempt_one_slot(
                        slot=slot,
                        ordinal=ordinal,
                        total=total,
                        on_progress=on_progress,
                        on_retry=on_retry,
                        on_call=on_call,
                    ),
                    kind="phase",
                )
                self._write_slot_output(
                    slot=slot,
                    recipe=recipe,
                    output=output,
                    reservations=reservations,
                    on_frame=on_frame,
                    on_call=on_call,
                )
                completed.append(slot)
            reservations.release_unused()
            return domain.ScanSummary(
                completed=tuple(completed),
                failed=tuple(failed),
                stopped=self._stop_event.is_set(),
            )
        except BaseException:
            # Match the real transport: retain artifacts whose writes
            # completed, but remove this call's untouched identity-checked
            # placeholders so a safe retry is not blocked.
            reservations.release_unused()
            raise
        finally:
            self._scanning = False

    def _attempt_one_slot(
        self,
        *,
        slot: int,
        ordinal: int,
        total: int,
        on_progress: Callable[[domain.ScanProgress], None],
        on_retry: Callable[[int, int, str], None],
        on_call: OnCall | None = None,
    ) -> None:
        """Mirrors CoolscanPyTransport._scan_one_slot: up to max_attempts
        calls (only TransportSmearDetected-equivalent leading/permanent
        faults are retried), each its own mock.scan:slot{N} scan.call
        boundary. Raises FrameRetryExhausted on exhaustion; returns
        normally (no value -- this synthetic transport has no Frame object
        to hand back) the instant an attempt succeeds. Called by the
        caller's own fine_scan:slot{N} scan.phase wrap -- this method
        itself does not touch on_call directly for that outer boundary."""
        max_attempts = 1 + safety.MAX_FRAME_RETRIES
        leading_failures = self._fault_script.get(slot, 0)
        permanent = slot in self._permanent_fault_slots
        last_error: Exception | None = None

        for attempt in range(1, max_attempts + 1):
            on_progress(
                domain.ScanProgress(
                    job_id="mock-job",
                    slot=slot,
                    ordinal=ordinal,
                    total_slots=total,
                    fraction=(ordinal + (attempt / max_attempts)) / max(total, 1),
                    message=f"slot {slot} attempt {attempt}",
                )
            )
            should_fail = permanent or attempt <= leading_failures
            # Mirrors CoolscanPyTransport._scan_one_slot's own
            # roll.scan:slot{N} call-boundary telemetry -- this synthetic
            # transport has no real SDK call to wrap, so the boundary
            # brackets the equivalent decision step instead, keeping both
            # Transport implementations' telemetry call names structurally
            # comparable.
            timed_call(on_call, f"mock.scan:slot{slot}", lambda: None)
            if not should_fail:
                return
            last_error = RuntimeError(_SYNTHETIC_SMEAR_REASON)
            if attempt < max_attempts:
                on_retry(slot, attempt, _SYNTHETIC_SMEAR_REASON)

        raise FrameRetryExhausted(slot, last_error or RuntimeError(_SYNTHETIC_SMEAR_REASON))

    def _write_slot_output(
        self,
        *,
        slot: int,
        recipe: domain.CaptureRecipe,
        output: domain.OutputSpec,
        reservations: OutputReservations,
        on_frame: Callable[[int, domain.ScanReceipt], None],
        on_call: OnCall | None = None,
    ) -> None:
        """Mirrors CoolscanPyTransport.start_scan's own post-scan file
        writes: called only after _attempt_one_slot (wrapped in its own
        fine_scan:slot{N} scan.phase boundary by the caller) has already
        succeeded for this slot -- a permanently/leading-failing slot never
        reaches here, since _attempt_one_slot raises straight out of the
        caller's loop instead of returning."""
        paths = reservations.groups[slot]
        rgb_path = paths.rgb_path
        rgb_frame = _synthetic_rgb_frame()
        # Plan 10-09: phased_call tags each file write as BOTH "scan.call"
        # (Plan 10-04, unchanged) AND "scan.phase" (this plan's addition)
        # -- mirrors CoolscanPyTransport.start_scan's identical file-write
        # wrapping.
        phased_call(
            on_call,
            f"file_write.rgb:slot{slot}",
            lambda: write_tiff(
                reservations, rgb_path, rgb_frame, photometric="rgb"
            ),
        )
        ir_path_str: str | None = None
        ir_frame: np.ndarray | None = None
        if recipe.channels is domain.Channels.RGBI:
            ir_path = paths.ir_path
            assert ir_path is not None
            ir_frame = _synthetic_ir_frame()
            phased_call(
                on_call,
                f"file_write.ir:slot{slot}",
                lambda: write_tiff(reservations, ir_path, ir_frame),
            )
            ir_path_str = str(ir_path)
        raw_export_path_str: str | None = None
        raw_export_ir_path_str: str | None = None
        raw_export_spec = raw_export_for_slot(output, slot)
        if raw_export_spec is not None:
            raw_export_path = paths.raw_export_path
            assert raw_export_path is not None
            raw_export_ir_path = paths.raw_export_ir_path
            phased_call(
                on_call,
                f"file_write.raw:slot{slot}",
                lambda: write_raw_export(
                    reservations,
                    raw_export_path,
                    raw_export_ir_path,
                    raw_export_spec,
                    rgb=rgb_frame,
                    ir=ir_frame,
                    dpi=recipe.resolution_dpi,
                    device_model="SUPER COOLSCAN 5000 ED (mock)",
                ),
            )
            raw_export_path_str = str(raw_export_path)
            raw_export_ir_path_str = (
                str(raw_export_ir_path) if raw_export_ir_path is not None else None
            )
        meter_rgbi_path_str: str | None = None
        if recipe.channels is domain.Channels.RGBI:
            meter_path = paths.meter_rgbi_path
            assert meter_path is not None
            phased_call(
                on_call,
                f"file_write.meter:slot{slot}",
                lambda: write_tiff(reservations, meter_path, _synthetic_meter_frame()),
            )
            meter_rgbi_path_str = str(meter_path)
        receipt = _synthetic_receipt(
            slot=slot,
            spacing_offset=self._spacing_offsets.get(slot, 0),
            recipe=recipe,
            rgb_path=str(rgb_path),
            ir_path=ir_path_str,
            meter_rgbi_path=meter_rgbi_path_str,
            raw_export_path=raw_export_path_str,
            raw_export_ir_path=raw_export_ir_path_str,
        )
        on_frame(slot, receipt)

    def request_stop(self) -> None:
        self._stop_event.set()

    def eject(self) -> bool:
        # Same post-eject contract as CoolscanPyTransport: the film is out,
        # so the preview no longer describes loaded media -- the emitted
        # device.status must show previewEstablished false and scan.start
        # must be back behind NO_PREVIEW.
        self._preview_established = False
        self._last_preview_material = None
        self._spacing_offsets.clear()
        return True

    # -- internals ------------------------------------------------------------

    def _device_info(self) -> domain.DeviceInfo:
        return domain.DeviceInfo(
            device_id=_DEVICE_ID,
            vendor="Nikon",
            model="SUPER COOLSCAN 5000 ED (mock)",
            capabilities=domain.Capabilities(
                ir_channel=True,
                supported_dpi=(4000,),
                supported_depths=(16,),
                multi_sample=True,
                adapter_frame_capacity=40,
                adapter_frame_control=True,
                auto_exposure=True,
                registered_geometry=True,
                can_eject=True,
                # Same fixed set CoolscanPyTransport reports -- the one
                # wired recipe's multisample_passes, not a second hardcoded
                # "4" (see coolscanpy_transport.py's identical comment).
                supported_multisample_passes=(domain.FIXED_COLOR_NEGATIVE_RECIPE.multisample_passes,),
            ),
        )

    def _require_connected(self) -> None:
        if not self._connected:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
