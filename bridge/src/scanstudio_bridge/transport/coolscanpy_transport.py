"""`CoolscanPyTransport`: the thin real adapter over CoolscanPy's
`Device`/`Roll` API. Satisfies the identical `transport.Transport` contract
as `MockTransport` (transport/mock.py). See BRIDGE.md
(nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md)
for the wire-level contract and its CoolscanPy-exception-to-error-code
rename table this module implements.

This is the one file in this codebase that imports `coolscanpy` at module
level -- every other module stays hardware-library-free.
"""

from __future__ import annotations

import re
import subprocess
import time
import uuid
from pathlib import Path
from typing import Callable, Iterator

import coolscanpy
import numpy as np
import tifffile

# `Roll.preview()`'s public taxonomy (coolscanpy.FeederParked and its
# siblings, exported at the package's top level) is not the whole story --
# these two types live at internal coolscanpy module paths and are not part
# of that taxonomy, yet preview() is observed to let them escape uncaught.
# Live 2026-07-25: coolscanpy.protocol.ls5000_single_pass.roll_index's
# IndexDecodeError surfaced for a non-affine transport table and reached
# this bridge as a bare INTERNAL error with the message dropped from
# telemetry (see safety.TelemetryLog callers in service.py). Catching them
# explicitly below (see preview()) is a bridge-side compensation for a
# coolscanpy leak, not a wire contract of coolscanpy's own -- it becomes
# harmless, dead code the day coolscanpy's own facade translates these into
# its public taxonomy instead.
from coolscanpy.protocol.ls5000_single_pass.roll_index import IndexDecodeError
from coolscanpy.roll.preview_session import (
    RollSessionError,
    RollSessionIntegrityError,
)

from scanstudio_bridge import domain, safety
from scanstudio_bridge.exposure_authority import build_exposure_authority
from scanstudio_bridge.protocol import BridgeError, ErrorCode
from scanstudio_bridge.transport import FrameRetryExhausted, OnCall, phased_call
from scanstudio_bridge.transport.output_reservation import OutputReservations, write_tiff

# Plan 10-09: how long `coolscanpy_provenance()`'s `git rev-parse HEAD`
# subprocess is allowed to run before being treated the same as "git is
# absent" -- provenance reporting must never be able to hang bridge
# startup.
_GIT_HEAD_SHA_TIMEOUT_SECONDS = 5.0

_DEVICE_VENDOR = "Nikon"
_DEVICE_MODEL = "SUPER COOLSCAN 5000 ED"

# The wire and CoolscanPy enum string VALUES do not match (see BRIDGE.md's
# Types note) -- never assume they do, always translate explicitly.
_MATERIAL_TO_COOLSCANPY: dict[domain.Material, coolscanpy.Material] = {
    domain.Material.COLOR_NEGATIVE: coolscanpy.Material.COLOR_NEGATIVE,
    domain.Material.BLACK_AND_WHITE_NEGATIVE: coolscanpy.Material.BLACK_AND_WHITE_NEGATIVE,
}


def _coolscanpy_git_head_sha(package_dir: Path) -> str | None:
    """Return CoolscanPy's own checkout SHA, never an ancestor repository.

    ``package_dir`` is ``<coolscanpy root>/src/coolscanpy``. Require a git
    marker at that component root before asking git for HEAD; packaged source
    snapshots deliberately have no marker, so they report ``None`` rather
    than accidentally borrowing ScanStudio's enclosing checkout SHA.
    """
    component_root = package_dir.parent.parent
    if not (component_root / ".git").exists():
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(component_root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=_GIT_HEAD_SHA_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    sha = result.stdout.strip()
    return sha or None


def coolscanpy_provenance() -> dict[str, object]:
    """Plan 10-09: `coolscanpy.__file__`, its version string, and -- if the
    directory the running interpreter actually resolved is a git checkout
    -- its HEAD sha (never raises; tolerates git/a checkout being absent).

    Closes the stale-wheel blindspot documented in this repository's
    pyproject.toml `[tool.uv.sources]` comment: a stale cached build can
    silently keep running under an unchanged version string, so the actual
    file path plus git HEAD sha are the only way to tell which real
    coolscanpy content a running bridge process loaded.

    The sole function in this codebase another module may import to learn
    anything about coolscanpy without itself importing the `coolscanpy`
    module directly -- keeps this file's "one file imports coolscanpy at
    module level" invariant intact (see this module's own docstring) while
    still letting cli.py report on it at startup."""
    package_dir = Path(coolscanpy.__file__).resolve().parent
    return {
        "file": coolscanpy.__file__,
        "version": coolscanpy.__version__,
        "head_sha": _coolscanpy_git_head_sha(package_dir),
    }


def _close_scan_many(iterator: Iterator[coolscanpy.Frame] | None) -> None:
    """Close a ``scan_many`` iterator if it exposes ``.close()``.

    The real library returns an owned iterator whose ``.close()`` requests a
    frame-boundary safe stop and waits for the worker to drain. Test doubles
    may omit the method entirely; this helper tolerates both shapes.
    """
    if iterator is None:
        return
    close_fn = getattr(iterator, "close", None)
    if callable(close_fn):
        close_fn()


# 2026-07-25 incident (batch clamp-and-retry): the out-of-table
# `RollMismatch` a fresh `scan_many` re-read can raise --
# coolscanpy.protocol.ls5000_single_pass.worker.py's
# `_bind_plan_to_live_selection`: "requested frame N is outside the
# scanner-addressable table 1..M" -- carries no structured attribute for
# M. Confirmed by reading coolscanpy's own source (exceptions.py,
# _roll.py): every step between that raise site and the public
# `coolscanpy.RollMismatch` this module catches passes only a message
# string -- `RollMismatch.__init__` takes no kwargs, and `_roll.py`'s own
# batch-worker re-raises this exact message bare (`RollMismatch(message)`,
# no attribute). M is therefore recovered from the message text itself --
# the only place it exists -- rather than invented via a structured field
# that does not exist anywhere on this exception.
_OUT_OF_TABLE_MESSAGE_RE = re.compile(
    r"outside the scanner-addressable table 1\.\.(\d+)"
)


def _trim_out_of_table_slots(
    remaining: list[int], message: str
) -> tuple[list[int], list[int]] | None:
    """One-shot recovery for the out-of-table `RollMismatch` above: the
    PREVIEW-time slot count (`Roll.slot_count`, populated from the last
    `roll.preview` call's session) is stale by the time `scan_many`
    re-reads the transport table for real, so the bridge cannot clamp
    `remaining` before ever calling `scan_many` -- it can only react once
    `scan_many` itself raises this specific shape. Returns `(surviving,
    dropped)`, both preserving `remaining`'s ascending order, when
    `message` matches AND trimming would actually shrink the batch (both
    non-empty); `None` when the message doesn't match this exact shape,
    or every slot in `remaining` already fits under the parsed bound (the
    match came from something else, or this is a stale retry) -- the
    caller falls back to the pre-existing unconditional ROLL_MISMATCH
    failure in either `None` case."""
    match = _OUT_OF_TABLE_MESSAGE_RE.search(message)
    if match is None:
        return None
    table_bound = int(match.group(1))
    surviving = [slot for slot in remaining if slot <= table_bound]
    dropped = [slot for slot in remaining if slot > table_bound]
    if not surviving or not dropped:
        return None
    return surviving, dropped


class _ScanPhase:
    """One ``fine_scan:batch`` ``scan.phase`` telemetry boundary around a
    ``Roll.scan_many`` consumption.

    ``scan_many`` returns a lazy iterator: the real work happens while the
    caller iterates and writes each frame. A single phase span is therefore
    the honest granularity the bridge can observe, bracketing the entire
    batch from reservation to exhaustion/raise/abandon.
    """

    def __init__(self, on_call: OnCall | None) -> None:
        self._on_call = on_call
        self._started_at: float | None = None

    def __enter__(self) -> None:
        if self._on_call is not None:
            self._on_call("enter", "fine_scan:batch", None, "phase")
        self._started_at = time.monotonic()

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: object,
    ) -> None:
        del tb
        if self._on_call is not None and self._started_at is not None:
            self._on_call(
                "exit",
                "fine_scan:batch",
                time.monotonic() - self._started_at,
                "phase",
                call_outcome="raise" if exc_type is not None else "return",
                exception_class=exc_type.__name__ if exc_type is not None else None,
            )


def _capabilities_from_coolscanpy(caps: coolscanpy.Capabilities) -> domain.Capabilities:
    return domain.Capabilities(
        ir_channel=caps.ir_channel,
        supported_dpi=tuple(caps.supported_dpi),
        supported_depths=tuple(caps.supported_depths),
        multi_sample=caps.multi_sample,
        adapter_frame_capacity=caps.adapter_frame_capacity,
        adapter_frame_control=caps.adapter_frame_control,
        auto_exposure=caps.auto_exposure,
        registered_geometry=caps.registered_geometry,
        can_eject=caps.can_eject,
        # Bridge-derived, not read from `caps` -- CoolscanPy's own
        # Capabilities has no such field. Fixed to the one wired recipe's
        # multisample_passes (see BRIDGE.md's Recipe constraints) rather
        # than a bare literal, so there is exactly one source of truth for
        # "4" in this codebase.
        supported_multisample_passes=(domain.FIXED_COLOR_NEGATIVE_RECIPE.multisample_passes,),
    )


def _device_info_from_coolscanpy(info: coolscanpy.DeviceInfo) -> domain.DeviceInfo:
    return domain.DeviceInfo(
        device_id=info.id,
        vendor=info.vendor,
        model=info.model,
        capabilities=_capabilities_from_coolscanpy(info.capabilities),
    )


def _normalize_preview_tile(image: np.ndarray) -> np.ndarray:
    """Transpose an HxWx3 scanner-native crop into Nikon-render orientation,
    then stretch it to an 8-bit display tile.

    The axis swap matches CoolscanPy's full-capture storage transform exactly;
    it never rotates or flips an axis. A 0.5th/99.5th percentile clip across
    the whole array is linearly rescaled onto 0-255. No resize -- CoolscanPy's
    preview crops are already thumbnail-sized.
    """
    upright = np.swapaxes(image, 0, 1)
    low, high = np.percentile(upright, (0.5, 99.5))
    span = max(high - low, 1.0)
    stretched = (np.clip(upright, low, high).astype(np.float64) - low) * (255.0 / span)
    return np.rint(stretched).astype(np.uint8)


def _thumbnail_from_coolscanpy(
    thumbnail: coolscanpy.Thumbnail, *, image_path: str
) -> domain.Thumbnail:
    # `.image` is normalized (_normalize_preview_tile) and written to disk
    # by the caller (preview(), below) -- image_path is threaded through
    # here; BRIDGE.md's Thumbnail still carries no image bytes on the wire,
    # only this path, exactly like ScanReceipt's rgbPath/irPath.
    return domain.Thumbnail(
        slot=thumbnail.slot,
        boundary_rows=tuple(thumbnail.boundary_rows),
        spacing_offset=thumbnail.spacing_offset,
        needs_approval=thumbnail.needs_approval,
        warnings=tuple(thumbnail.warnings),
        image_path=image_path,
    )


def _approval_receipt_from_coolscanpy(
    approval: coolscanpy.ApprovalReceipt | None,
) -> domain.ApprovalReceipt | None:
    if approval is None:
        return None
    return domain.ApprovalReceipt(
        reviewed_fingerprint_sha256=approval.reviewed_fingerprint_sha256,
        slot=approval.slot,
        spacing_offset=approval.spacing_offset,
        thumbnail_sha256=approval.thumbnail_sha256,
        reviewed_lookup_row=approval.reviewed_lookup_row,
        reviewed_native_origin=approval.reviewed_native_origin,
        review_reasons=tuple(approval.review_reasons),
    )


def _scan_receipt_from_coolscanpy(
    receipt: coolscanpy.Receipt,
    *,
    rgb_path: str,
    ir_path: str | None,
    meter_rgbi_path: str | None,
    attempts_root: Path | None,
) -> domain.ScanReceipt:
    exposure_authority = build_exposure_authority(attempts_root=attempts_root, slot=receipt.slot)
    exposure = receipt.exposure
    clipping = receipt.clipping
    focus_detail = receipt.focus_detail
    transport_smear = receipt.transport_smear
    return domain.ScanReceipt(
        version=receipt.version,
        slot=receipt.slot,
        spacing_offset=receipt.spacing_offset,
        dpi=receipt.dpi,
        depth=receipt.depth,
        device_id=receipt.device_id,
        device_model=receipt.device_model,
        reviewed_fingerprint_sha256=receipt.reviewed_fingerprint_sha256,
        fresh_fingerprint_sha256=receipt.fresh_fingerprint_sha256,
        manual_approval=_approval_receipt_from_coolscanpy(receipt.manual_approval),
        exposure=domain.ExposureVector(
            focus_position=exposure.focus_position,
            exposure_multiplier=exposure.exposure_multiplier,
            red_exposure_us=exposure.red_exposure_us,
            green_exposure_us=exposure.green_exposure_us,
            blue_exposure_us=exposure.blue_exposure_us,
        ),
        # Always None for this route: single-pass RGBI4 shares one pass for
        # RGB+IR, so CoolscanPy never populates a separate SplitAlignment
        # record. See BRIDGE.md's Types section.
        split_alignment=None,
        clipping=domain.ClippingTelemetry(
            fractions=tuple(clipping.fractions),
            clip_level=clipping.clip_level,
            warning_fraction=clipping.warning_fraction,
            warning=clipping.warning,
        ),
        focus_detail=domain.FocusDetailTelemetry(
            method=focus_detail.method,
            verdict=focus_detail.verdict,
            score=focus_detail.score,
            texture_span=focus_detail.texture_span,
        ),
        transport_smear=domain.TransportSmearAssessment(
            verdict=transport_smear.verdict,
            start_row=transport_smear.start_row,
            suffix_rows=transport_smear.suffix_rows,
            minimum_matches=transport_smear.minimum_matches,
            tail_median_rms=transport_smear.tail_median_rms,
            tail_min_corr=transport_smear.tail_min_corr,
            pre_tail_median_rms=transport_smear.pre_tail_median_rms,
            texture_span=transport_smear.texture_span,
            reason=transport_smear.reason,
        ),
        artifacts={
            key: domain.ArtifactEvidence(
                sha256=value.sha256,
                byte_length=value.byte_length,
                shape=tuple(value.shape),
                dtype=value.dtype,
            )
            for key, value in receipt.artifacts.items()
        },
        # Sol adversarial review 2026-07-26, finding 2: forwarded verbatim,
        # never re-derived -- CoolscanPy's Receipt.storage_transform is
        # already the single source of truth for which numpy transform
        # produced rgb_path/ir_path's storage orientation.
        storage_transform=receipt.storage_transform,
        rgb_path=rgb_path,
        ir_path=ir_path,
        meter_rgbi_path=meter_rgbi_path,
        # The current Roll's caller-owned persistent evidence directory;
        # never inferred by looking at unrelated filesystem state.
        attempts_root=str(attempts_root) if attempts_root is not None else None,
        exposure_authority=exposure_authority,
    )


class CoolscanPyTransport:
    """Thin real adapter over CoolscanPy's `Device`/`Roll` API. Satisfies
    `transport.Transport` structurally -- no explicit inheritance needed,
    it's a `Protocol`."""

    def __init__(self) -> None:
        self._device: coolscanpy.Device | None = None
        self._device_id: str | None = None
        self._roll: coolscanpy.Roll | None = None
        self._material: domain.Material | None = None
        self._preview_established = False
        self._scanning = False
        # Plan 10-09 (attempts-root persistence): the exact `attempts_root`
        # passed to `Device.roll()` below, kept here purely for our own
        # reporting -- service.py reads this (via getattr, since
        # MockTransport has no such concept) to add it to scan.start's
        # telemetry closures. Not read back from coolscanpy's `Roll` (whose
        # own copy is a private attribute) -- this is simply the value we
        # ourselves chose and passed in.
        self.attempts_root: Path | None = None

    # -- device lifecycle -----------------------------------------------------

    def list_devices(self) -> list[domain.DeviceInfo]:
        return [_device_info_from_coolscanpy(info) for info in coolscanpy.get_devices()]

    def open_device(self, device_id: str) -> domain.DeviceInfo:
        if self._device is not None:
            raise BridgeError(ErrorCode.ALREADY_CONNECTED, "a device is already open")
        try:
            self._device = coolscanpy.open(device_id)
        except coolscanpy.DeviceNotFound as exc:
            raise BridgeError(ErrorCode.DEVICE_NOT_FOUND, str(exc)) from exc
        except coolscanpy.DeviceBusy as exc:
            raise BridgeError(ErrorCode.DEVICE_BUSY, str(exc)) from exc
        self._device_id = device_id
        return domain.DeviceInfo(
            device_id=device_id,
            vendor=_DEVICE_VENDOR,
            model=_DEVICE_MODEL,
            capabilities=_capabilities_from_coolscanpy(self._device.capabilities),
        )

    def status(self) -> domain.DeviceStatus:
        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        # The bundled CoolScanPy supplies a motion-free tri-state
        # `film_present()` query. Keep the defensive getattr/callable and
        # fail-soft exception boundary so an older dependency, an active
        # capture's DeviceBusy, or a misbehaving probe reports unknown rather
        # than raising from status() or fabricating a true/false reading.
        film_present_attr = getattr(self._device, "film_present", None)
        if callable(film_present_attr):
            try:
                film_present = film_present_attr()
            except Exception:
                film_present = None
        else:
            film_present = None
        return domain.DeviceStatus(
            connected=True,
            device_id=self._device_id,
            preview_established=self._preview_established,
            slot_count=self._roll.slot_count if self._preview_established else None,
            active_job_id=None,
            lane_held=self._scanning,
            # Live-recomputed by service.py (Plan 08-03), which owns
            # safety.py's base_dir wiring -- the Transport layer has no
            # access to it.
            motion_armed=False,
            film_present=film_present,
        )

    def close_device(self) -> None:
        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        if self._scanning:
            raise BridgeError(ErrorCode.HARDWARE_LANE_BUSY, "a scan job holds the hardware lane")
        if self._roll is not None:
            self._roll.close()
            self._roll = None
        self._device.close()
        self._device = None
        self._device_id = None
        self._material = None
        self._preview_established = False

    # -- preview / approve ------------------------------------------------------

    def preview(
        self,
        material: domain.Material,
        slots: list[int] | None,
        on_thumbnail: Callable[[domain.Thumbnail], None],
    ) -> domain.PreviewResult:
        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        translated = _MATERIAL_TO_COOLSCANPY[material]
        # State is committed only on SUCCESS (2026-07-25 adversarial-review
        # finding): previously `self._material` was overwritten up front and
        # an existing Roll was reused regardless, so previewing material A,
        # then requesting material B, relabeled the bridge's state as B
        # while the Roll (and any still-valid session) remained A's -- a
        # subsequent scan could then validate against the mislabeled
        # session. A material CHANGE therefore closes the old Roll (its
        # session is A's, not B's), and `self._material` moves only after
        # the traversal succeeds. The prior preview session is also
        # invalidated up front: CoolscanPy's `Roll.preview()` re-reads the
        # transport and replaces the fingerprint and every Thumbnail, so
        # the moment a new attempt starts, the old session is gone whether
        # or not this attempt completes.
        self._preview_established = False
        if self._roll is not None and self._material != material:
            self._roll.close()
            self._roll = None
        if self._roll is None:
            # Plan 10-09 (attempts-root persistence): a caller-owned
            # attempts_root survives Roll.close(), unlike coolscanpy's own
            # default (a bare tempfile.mkdtemp() directory that
            # Roll.close() shutil.rmtree()s the instant this Roll closes --
            # see coolscanpy's _roll.py Roll.__init__/.close() and
            # _device.py Device.roll()'s own docstring). Without this, a
            # failed attempt's journal/manifest/rasters are wiped the
            # moment the device closes (or the bridge exits), with no path
            # ever reported anywhere -- exactly what left a real failed
            # attempt's journal surviving only by luck in a randomly-named
            # /var/folders temp dir instead of somewhere an operator could
            # actually find it. Fresh UUID per Roll, mirroring the existing
            # preview-tile directory convention a few lines below (one
            # fresh UUID directory per roll.preview call): the Roll (and
            # therefore this attempts_root) is created once here, before
            # any scan.start job_id exists, so it cannot be keyed by
            # job_id -- see this plan's SUMMARY for that reasoning.
            self.attempts_root = (
                safety.DEFAULT_BASE_DIR / "coolscanpy-attempts" / uuid.uuid4().hex
            )
            self.attempts_root.mkdir(parents=True, exist_ok=True)
            self._roll = self._device.roll(
                material=translated, attempts_root=self.attempts_root
            )

        try:
            # A SINGLE blocking CoolscanPy call that returns the complete
            # list once the whole-roll transport read finishes -- there is
            # no per-thumbnail streaming under the hood. `on_thumbnail` is
            # invoked once per item below, simulating the bridge's own
            # one-event-per-slot wire behavior on top of this atomic call.
            thumbnails = self._roll.preview(slots=slots)
        except coolscanpy.CaptureWorkerBootstrapFailed as exc:
            raise BridgeError(ErrorCode.INTERNAL, str(exc)) from exc
        except coolscanpy.FeederParked as exc:
            raise BridgeError(ErrorCode.FEEDER_PARKED, str(exc)) from exc
        except coolscanpy.RefeedRequired as exc:
            raise BridgeError(ErrorCode.REFEED_REQUIRED, str(exc)) from exc
        except coolscanpy.DeviceBusy as exc:
            raise BridgeError(ErrorCode.DEVICE_BUSY, str(exc)) from exc
        except IndexDecodeError as exc:
            # Hedged wording (2026-07-25 adversarial-review finding): the
            # IndexDecodeError class also covers malformed envelopes and
            # geometry defects, which are capture/driver faults a refeed
            # cannot fix -- refeed-and-retry stays the first move, but the
            # message must not sell a software fault as a film problem.
            raise BridgeError(
                ErrorCode.REFEED_REQUIRED,
                "transport read was not one uniform traversal; eject or refeed "
                "the strip and run the preview again -- if this recurs on "
                f"clean feeds it may be a capture or driver defect ({exc})",
            ) from exc
        except RollSessionIntegrityError:
            # Artifact/journal integrity faults are driver-side defects, not
            # operator conditions -- let service.py's boundary report them as
            # INTERNAL with the exception class preserved in the message.
            raise
        except RollSessionError as exc:
            raise BridgeError(
                ErrorCode.REFEED_REQUIRED,
                "preview could not establish a usable roll session; refeed the "
                "strip and retry -- if this recurs on clean feeds it may be a "
                f"capture or driver defect ({exc})",
            ) from exc
        except coolscanpy.RollMismatch as exc:
            # Base-class fallback AFTER every mapped subclass (RefeedRequired
            # above; FingerprintRefused/ManualReviewRequired are scan-time
            # concepts that preview() does not raise). CoolscanPy raises the
            # bare base for e.g. a completed preview whose evidence belongs
            # to a different USB topology -- typed, never INTERNAL.
            raise BridgeError(ErrorCode.ROLL_MISMATCH, str(exc)) from exc

        # Fresh UUID directory per roll.preview call, mirroring the
        # existing hw-telemetry/{session_id}.jsonl convention (see
        # BRIDGE.md's Thumbnail.imagePath prose).
        preview_dir = safety.DEFAULT_BASE_DIR / "previews" / uuid.uuid4().hex
        preview_dir.mkdir(parents=True, exist_ok=True)
        for thumbnail in thumbnails:
            tile_path = preview_dir / f"slot-{thumbnail.slot:04d}.tif"
            tifffile.imwrite(
                tile_path, _normalize_preview_tile(thumbnail.image), photometric="rgb"
            )
            on_thumbnail(_thumbnail_from_coolscanpy(thumbnail, image_path=str(tile_path)))

        self._material = material
        self._preview_established = True
        return domain.PreviewResult(count=len(thumbnails), fingerprint=self._roll.fingerprint.sha256)

    def approve(self, slot: int) -> None:
        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        if not self._preview_established:
            raise BridgeError(
                ErrorCode.NO_PREVIEW, "roll.approve requires a completed roll.preview first"
            )
        try:
            self._roll.approve(slot)
        except ValueError as exc:
            raise BridgeError(ErrorCode.INVALID_PARAMS, str(exc)) from exc

    def set_spacing_offset(
        self, slot: int, offset_rows: int
    ) -> domain.Thumbnail:
        """Re-crop one established preview slot without moving the scanner."""

        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
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
        assert self._roll is not None
        try:
            thumbnail = self._roll.set_spacing_offset(slot, offset_rows)
        except coolscanpy.DeviceBusy as exc:
            raise BridgeError(ErrorCode.HARDWARE_LANE_BUSY, str(exc)) from exc
        except RollSessionIntegrityError:
            self._preview_established = False
            raise
        except RollSessionError as exc:
            self._preview_established = False
            raise BridgeError(
                ErrorCode.NO_PREVIEW,
                "frame alignment could not be changed because the preview "
                f"session is no longer usable; acquire a fresh preview ({exc})",
            ) from exc
        except ValueError as exc:
            raise BridgeError(ErrorCode.INVALID_PARAMS, str(exc)) from exc

        # A fresh path is part of the result contract: the macOS image
        # loader caches file URLs, so overwriting the prior tile in place
        # can leave the UI showing the pre-adjustment crop.
        try:
            preview_dir = safety.DEFAULT_BASE_DIR / "previews" / uuid.uuid4().hex
            preview_dir.mkdir(parents=True, exist_ok=True)
            tile_path = preview_dir / f"slot-{thumbnail.slot:04d}.tif"
            tifffile.imwrite(
                tile_path,
                _normalize_preview_tile(thumbnail.image),
                photometric="rgb",
            )
        except Exception as exc:
            # CoolScanPy already committed the new native-row offset before
            # this bridge-owned display artifact is written. Keeping the old
            # preview registration alive would let scan.start consume a
            # hidden alignment that the user never saw, so fail closed and
            # require a complete preview to establish visible state again.
            self._preview_established = False
            raise BridgeError(
                ErrorCode.INTERNAL,
                "frame alignment was applied, but the adjusted preview tile "
                "could not be persisted; preview registration was invalidated "
                f"and a fresh preview is required ({type(exc).__name__}: {exc})",
            ) from exc
        return _thumbnail_from_coolscanpy(thumbnail, image_path=str(tile_path))

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
        """Fine-scan the requested slots using one ``Roll.scan_many`` batch.

        ``on_retry`` is retained for ``Transport`` contract compatibility
        but is no longer invoked: the bridge now delegates the whole slot
        list to ``Roll.scan_many`` and surfaces exhausted retry conditions
        as ``FrameRetryExhausted`` instead of driving retries itself.
        """
        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        if not self._preview_established:
            raise BridgeError(
                ErrorCode.NO_PREVIEW, "scan.start requires a completed roll.preview first"
            )
        domain.validate_capture_recipe(recipe, self._material)

        total = len(slots)
        completed: list[int] = []
        failed: list[int] = []
        # Plan 10-09 (per-frame failure reasons, coordinator scope
        # addition): see ManualReviewRequired below and ScanSummary's own
        # docstring (domain.py).
        failure_reasons: dict[int, dict[str, str]] = {}
        stopped = False
        # 2026-07-25 incident (batch clamp-and-retry): bounds
        # _trim_out_of_table_slots' recovery to exactly one attempt per
        # start_scan call -- see the RollMismatch handler below.
        table_trim_retried = False
        self._scanning = True
        reservations: OutputReservations | None = None
        try:
            # scan_many requires unique, strictly-increasing slots.
            sorted_slots = sorted(slots)
            if len(sorted_slots) != len(set(sorted_slots)):
                raise BridgeError(ErrorCode.INVALID_PARAMS, "scan slots must be unique")
            if not sorted_slots:
                return domain.ScanSummary(
                    completed=(), failed=(), stopped=False, failure_reasons={}
                )
            remaining: list[int] = list(sorted_slots)

            # Reserve every possible artifact before progress callbacks or
            # CoolscanPy motion.  This rejects RGB, IR, and potential meter
            # collisions atomically for the requested output group.
            reservations = OutputReservations.reserve(sorted_slots, recipe, output)

            # scan_many yields completed frames and exposes no per-slot
            # pre-attempt hook, so this upfront pass is the only way to give
            # the client a scan.progress event naming every requested slot
            # before the batch actually starts moving.
            #
            # NOTE (2026-07-25 incident fix): service.py no longer infers
            # "the slot in flight" from the last of these on_progress
            # calls -- they all fire here, in one pass, before scan_many is
            # ever invoked, so "the last slot on_progress fired for" is
            # always this batch's LAST requested slot, never whichever slot
            # a later exception actually affects (a 33-slot batch's
            # pre-frame RollMismatch once misreported slot 36 instead of
            # slot 4 this way). See service.py's first_pending_slot() (and
            # its resolved_slots' own comment) for the on_frame-based
            # replacement this module's on_frame callback below now feeds.
            for ordinal, slot in enumerate(sorted_slots):
                on_progress(
                    domain.ScanProgress(
                        job_id="",
                        slot=slot,
                        ordinal=ordinal,
                        total_slots=total,
                        fraction=ordinal / max(total, 1),
                        message=f"scanning slot {slot}",
                    )
                )

            while remaining:
                batch_iterator: Iterator[coolscanpy.Frame] | None = None
                try:
                    with _ScanPhase(on_call):
                        batch_iterator = self._roll.scan_many(remaining, on_progress=None)
                        try:
                            for frame in batch_iterator:
                                slot = frame.slot
                                paths = reservations.groups[slot]
                                rgb_path = paths.rgb_path

                                phased_call(
                                    on_call,
                                    f"file_write.rgb:slot{slot}",
                                    lambda: write_tiff(
                                        reservations,
                                        rgb_path,
                                        frame.rgb,
                                        photometric="rgb",
                                        resolution=(recipe.resolution_dpi, recipe.resolution_dpi),
                                        resolutionunit="INCH",
                                    ),
                                )
                                ir_path_str: str | None = None
                                if recipe.channels is domain.Channels.RGBI:
                                    ir_path = paths.ir_path
                                    assert ir_path is not None
                                    phased_call(
                                        on_call,
                                        f"file_write.ir:slot{slot}",
                                        lambda: write_tiff(
                                            reservations,
                                            ir_path,
                                            frame.ir,
                                            resolution=(recipe.resolution_dpi, recipe.resolution_dpi),
                                            resolutionunit="INCH",
                                        ),
                                    )
                                    ir_path_str = str(ir_path)

                                meter_rgbi_path_str: str | None = None
                                if frame.meter_rgbi is not None:
                                    meter_path = paths.meter_rgbi_path
                                    assert meter_path is not None
                                    # No photometric kwarg -- this is 4-channel meter data,
                                    # not display RGB (see BRIDGE.md's meterRgbiPath prose).
                                    phased_call(
                                        on_call,
                                        f"file_write.meter:slot{slot}",
                                        lambda: write_tiff(
                                            reservations,
                                            meter_path,
                                            frame.meter_rgbi,
                                            resolution=(recipe.resolution_dpi, recipe.resolution_dpi),
                                            resolutionunit="INCH",
                                        ),
                                    )
                                    meter_rgbi_path_str = str(meter_path)
                                else:
                                    reservations.release_unused(paths.meter_rgbi_path)

                                receipt = _scan_receipt_from_coolscanpy(
                                    frame.receipt,
                                    rgb_path=str(rgb_path),
                                    ir_path=ir_path_str,
                                    meter_rgbi_path=meter_rgbi_path_str,
                                    attempts_root=self.attempts_root,
                                )
                                on_frame(slot, receipt)
                                completed.append(slot)
                                remaining.remove(slot)
                        except coolscanpy.TransportSmearDetected as exc:
                            # scan_many processes slots in order; the first
                            # remaining slot is the one that failed. The bridge
                            # no longer drives per-frame retries itself, so
                            # surface the exhausted-retry shape service.py's
                            # anomaly path expects.
                            raise FrameRetryExhausted(remaining[0], exc) from exc
                        finally:
                            _close_scan_many(batch_iterator)
                except coolscanpy.SafeStopRequested:
                    stopped = True
                    break
                except coolscanpy.ManualReviewRequired as exc:
                    # Pre-flight check: no motion was attempted on this
                    # slot, so no eject is warranted -- surfaces as this
                    # slot's failure only, batch continues (Plan 08-01
                    # decision; not in BRIDGE.md's anomaly-halt list).
                    # Plan 10-09 (coordinator scope addition): preserved via
                    # ScanSummary.failure_reasons so service.py's worker can
                    # still emit a scan.frameFailed event/telemetry entry for
                    # it, exactly like every other failure path this plan
                    # instruments.
                    failed_slot = exc.slot
                    failed.append(failed_slot)
                    failure_reasons[failed_slot] = {
                        "reason_class": type(exc).__name__,
                        "reason_message": str(exc),
                        "code": ErrorCode.MANUAL_REVIEW_REQUIRED.value,
                    }
                    remaining.remove(failed_slot)
                    continue
                except coolscanpy.CaptureWorkerBootstrapFailed as exc:
                    raise BridgeError(ErrorCode.INTERNAL, str(exc)) from exc
                except coolscanpy.FeederParked as exc:
                    raise BridgeError(ErrorCode.FEEDER_PARKED, str(exc)) from exc
                except coolscanpy.FingerprintRefused as exc:
                    raise BridgeError(ErrorCode.FINGERPRINT_REFUSED, str(exc)) from exc
                except coolscanpy.RefeedRequired as exc:
                    raise BridgeError(ErrorCode.REFEED_REQUIRED, str(exc)) from exc
                except coolscanpy.GeometryValidationError as exc:
                    raise BridgeError(ErrorCode.GEOMETRY_VALIDATION_ERROR, str(exc)) from exc
                except coolscanpy.SplitAlignmentError as exc:
                    raise BridgeError(ErrorCode.SPLIT_ALIGNMENT_ERROR, str(exc)) from exc
                except coolscanpy.BatchIntegrityError as exc:
                    raise BridgeError(ErrorCode.BATCH_INTEGRITY_ERROR, str(exc)) from exc
                except coolscanpy.RollMismatch as exc:
                    # Base-class fallback AFTER every mapped RollMismatch
                    # subclass above (FingerprintRefused, RefeedRequired;
                    # ManualReviewRequired is folded into the summary
                    # earlier). CoolscanPy converts unclassified synchronized
                    # refusals to the bare base -- live 2026-07-25, a
                    # post-power-cycle unit attention surfaced mid-scan as
                    # "RollMismatch: SynchronizedProtocolError: ready group
                    # 170-170: untraced sense 063f03" and reached the app as
                    # INTERNAL. Typed, message preserved; a retry on the
                    # same feed succeeded once the attention drained.
                    #
                    # 2026-07-25 incident (batch clamp-and-retry): a second,
                    # more specific shape of this same base class --
                    # "requested frame N is outside the scanner-addressable
                    # table 1..M" (coolscanpy's
                    # worker.py::_bind_plan_to_live_selection, raised when
                    # this scan_many call's own FRESH transport re-read finds
                    # fewer addressable slots than Roll.slot_count reported
                    # after preview) -- live 2026-07-25: requesting slot 39
                    # after a re-read that found only 37 addressable slots
                    # failed the ENTIRE batch up front, nothing scanned, even
                    # though slots 1..37 were still perfectly scannable. One
                    # automatic recovery attempt: drop every remaining slot
                    # above the parsed table bound, fold each into
                    # failure_reasons exactly like ManualReviewRequired above
                    # (service.py's worker turns each into its own
                    # scan.frameFailed event), and retry scan_many once with
                    # the surviving subset. table_trim_retried bounds this to
                    # exactly one attempt per start_scan call -- a second
                    # out-of-table RollMismatch (e.g. the table shrank again
                    # mid-retry) falls straight through to the unconditional
                    # raise below, and a RollMismatch whose message doesn't
                    # match this exact shape (_trim_out_of_table_slots
                    # returns None) always did too.
                    trimmed = (
                        None
                        if table_trim_retried
                        else _trim_out_of_table_slots(remaining, str(exc))
                    )
                    if trimmed is None:
                        raise BridgeError(ErrorCode.ROLL_MISMATCH, str(exc)) from exc
                    surviving, dropped = trimmed
                    table_trim_retried = True
                    for dropped_slot in dropped:
                        failed.append(dropped_slot)
                        failure_reasons[dropped_slot] = {
                            "reason_class": type(exc).__name__,
                            "reason_message": str(exc),
                            "code": ErrorCode.ROLL_MISMATCH.value,
                        }
                    remaining = surviving
                    continue
                except NotImplementedError as exc:
                    # Defensive backstop: domain.validate_capture_recipe
                    # already raises NOT_IMPLEMENTED upfront for
                    # black-and-white, so this is not the primary path.
                    raise BridgeError(ErrorCode.NOT_IMPLEMENTED, str(exc)) from exc

            reservations.release_unused()
            return domain.ScanSummary(
                completed=tuple(completed),
                failed=tuple(failed),
                stopped=stopped,
                failure_reasons=failure_reasons,
            )
        except BaseException:
            if reservations is not None:
                # Preserve files that were fully written, but remove this
                # call's identity-checked zero-byte reservations so a retry
                # is not falsely blocked after any scan/decoder/write error.
                reservations.release_unused()
            raise
        finally:
            self._scanning = False

    def request_stop(self) -> None:
        if self._roll is not None:
            self._roll.safe_stop()

    def eject(self) -> bool:
        if self._device is None:
            raise BridgeError(ErrorCode.NOT_CONNECTED, "no device is open")
        # Route through the open Roll when one exists. On the pinned
        # coolscanpy `Roll.eject()` is a plain passthrough to
        # `Device.eject()`, so behavior is identical today -- but the
        # vendor-traced held-session eject (RESERVE_UNIT before the eject
        # CDB, proven live 2026-07-20 from a normal post-traversal state)
        # lands on `Roll` first (see coolscanpy's capture branch), so this
        # routing picks it up with zero bridge changes the day the pin
        # advances. The callable guard keeps duck-typed Roll doubles
        # without an eject method on the device route instead of dying
        # with an AttributeError.
        roll = self._roll
        if roll is not None and callable(getattr(roll, "eject", None)):
            target = roll
        else:
            target = self._device
        # Future-pin exception (capture branch): Roll.eject() with no held
        # reservation raises EjectNotAvailable, which is NOT an EjectFailed
        # subclass. Resolved per call so the editable pin advancing is
        # picked up without a bridge restart ordering hazard; the empty
        # tuple makes the except clause match nothing on today's pin.
        eject_not_available: tuple[type[BaseException], ...] = tuple(
            cls
            for cls in (getattr(coolscanpy, "EjectNotAvailable", None),)
            if isinstance(cls, type) and issubclass(cls, BaseException)
        )
        try:
            ejected = bool(target.eject())
        except ImportError as exc:
            raise BridgeError(
                ErrorCode.EJECT_FAILED,
                "real eject requires the coolscanpy[scanner] extra and SANE installed -- see README",
            ) from exc
        except coolscanpy.FeederParked as exc:
            # The typed accepted-without-progress outcome
            # (INCIDENT-20260719-eject-from-park): the eject CDB can be
            # accepted with clean sense while a parked/wedged transport
            # never actuates, and the driver's traced eject reports that
            # stall as FeederParked. Never a silent success, never
            # auto-retried here or anywhere above -- a power cycle is the
            # only demonstrated recovery.
            raise BridgeError(ErrorCode.FEEDER_PARKED, str(exc)) from exc
        except coolscanpy.EjectFailed as exc:
            raise BridgeError(ErrorCode.EJECT_FAILED, str(exc)) from exc
        except eject_not_available as exc:
            raise BridgeError(ErrorCode.EJECT_FAILED, str(exc)) from exc
        if not ejected:
            # A capability-gated no-op is NOT an eject: the film is still
            # inside the feeder. Returning success here would be exactly
            # the silent accepted-without-progress shape the incident
            # forbids.
            raise BridgeError(
                ErrorCode.EJECT_FAILED,
                "the device reports no eject capability; the film was not ejected",
            )
        # The strip is out: the roll session and preview no longer
        # describe loaded film. Close-first ordering on purpose -- if
        # close() raises (surfaced as INTERNAL by service.py's boundary),
        # `self._roll` stays set so `device.close` can still close
        # Roll-then-Device in the order coolscanpy requires.
        if self._roll is not None:
            self._roll.close()
            self._roll = None
        self._material = None
        self._preview_established = False
        return True
