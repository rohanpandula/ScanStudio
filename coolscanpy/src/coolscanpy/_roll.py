"""The roll-feeder extension: :class:`Roll`.

Wires three concrete subsystems that exist independently in this package but
were never previously composed into one whole-roll workflow:

* :mod:`coolscanpy.roll.preview_session` -- decodes one whole-roll transport
  read into fixed-order slots, spacing-offset math, and the reviewed
  fingerprint;
* :mod:`coolscanpy.protocol.ls5000_single_pass.capture_process` --
  ``CaptureProcessAdapter``, the process-isolated batch capture engine (the
  same class the concrete test suite already drives through injectable
  ``runner``/``batch_spawner`` seams, per the hardware-free testing
  contract);
* :mod:`coolscanpy.capture.single_pass_workflow` -- decodes, quality-checks,
  and finalizes one completed attempt.

Only ``Material.COLOR_NEGATIVE``'s single-pass RGBI4 capture route
(``CaptureRoute.SINGLE_PASS_RGBI4``) is wired end to end here. See the
``scan_many`` docstring and the package README's deviations note for why
``Material.BLACK_AND_WHITE_NEGATIVE``'s SANE-based route is not.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import queue
import re
import shutil
import stat
import tempfile
import threading
import time
import weakref
from pathlib import Path
from typing import TYPE_CHECKING, Any, Iterable, Iterator
from uuid import uuid4

import numpy as np
import tifffile

from coolscanpy.capture.single_pass_workflow import (
    LS5000SinglePassWorkflow,
    SinglePassAttempt,
    SinglePassFinalizationResult,
    SinglePassSession,
    SinglePassWorkflowError,
)
from coolscanpy.exceptions import (
    BatchIntegrityError,
    CaptureWorkerBootstrapFailed,
    DeviceBusy,
    FeederParked,
    FingerprintRefused,
    GeometryValidationError,
    ManualReviewRequired,
    PyCoolscanError,
    RollMismatch,
    SafeStopRequested,
    TransportSmearDetected,
)
from coolscanpy.protocol.ls5000_single_pass.capture_process import (
    BatchAckAction,
    CaptureBatchProcessError,
    CaptureBatchRequest,
    CaptureMode,
    CaptureOutcome,
    CaptureProcessAdapter,
    CaptureRequest,
    CaptureStopped,
    ManualFrameApproval,
)
from coolscanpy.protocol.ls5000_single_pass.density import (
    NikonDensityEvidence,
    NikonDensityFrameOwnershipReceipt,
    NikonExactBuilderEvidence,
    build_nikon_exact_builder_evidence,
)
from coolscanpy.roll.preview_session import (
    CaptureRoute,
    RollPreviewSession,
    build_roll_preview_session,
)
from coolscanpy.types import (
    ApprovalReceipt,
    ArtifactEvidence,
    ClippingTelemetry,
    ExposureVector,
    Frame,
    FingerprintComparison,
    FocusDetailTelemetry,
    Material,
    Progress,
    ProgressCallback,
    Receipt,
    RollFingerprint,
    Thumbnail,
    TransportSmearAssessment,
    build_digital_ice_acquisition_evidence,
)

if TYPE_CHECKING:
    from coolscanpy._device import Device

RECEIPT_VERSION = 1
LS5000_FINE_DPI = 4_000
LS5000_FINE_DEPTH = 16
_METER_PASS_BYTES = 1_088_000

# Generous defensive backstop for winding down scan_many's worker thread --
# not a hardware operation timeout (a real fine-scan frame is never
# abandoned mid-flight; see CaptureProcessAdapter's own docstring). Only
# matters if the worker is truly stuck, e.g. a hung child process.
_SCAN_WORKER_JOIN_TIMEOUT_SECONDS = 300.0
_USB_FALLBACK_TOPOLOGY = re.compile(r"^usb:(?P<bus>[0-9]+):(?P<address>[0-9]+)$")
_COOLSCAN3_TOPOLOGY = re.compile(
    r"^coolscan3:usb:(?:libusb:)?(?P<bus>[0-9]+):(?P<address>[0-9]+)$"
)

_BLACK_AND_WHITE_NOT_WIRED = (
    "Material.BLACK_AND_WHITE_NEGATIVE fine-scan capture is not wired in "
    "this package version: preview, spacing-offset, and approval all work "
    "for either material, but the SANE-based fine-scan pipeline "
    "(coolscanpy.roll.registration + coolscanpy.transport.sane.SaneBackend) "
    "has not been integrated with the roll batch engine. Only "
    "Material.COLOR_NEGATIVE's single-pass RGBI4 route "
    "(coolscanpy.protocol.ls5000_single_pass) is implemented end to end."
)


class _BatchWorkerStillActive(DeviceBusy):
    """Fail closed when a scan worker has not acknowledged shutdown."""


class _OwnedRollBatchIterator(Iterator[Frame]):
    """A lazy batch whose Roll reservation is owned before first ``next``.

    A bare generator does not execute its ``try/finally`` until first
    iteration.  That leaves a gap where ``scan_many()`` has returned but a
    concurrent ``Roll.close()`` can release the physical reservation and the
    generator can subsequently start hardware.  This wrapper owns the batch
    token eagerly and releases it exactly once on exhaustion, error, or
    explicit close.
    """

    def __init__(self, roll: "Roll", iterator: Iterator[Frame]) -> None:
        self._roll = roll
        self._iterator = iterator
        self._condition = threading.Condition(threading.RLock())
        self._executing_thread: int | None = None
        self._closing_thread: int | None = None
        self._closed = False
        self._released = False
        self._ownership_uncertain = False

    def __iter__(self) -> "_OwnedRollBatchIterator":
        return self

    def __next__(self) -> Frame:
        with self._condition:
            if self._closed:
                raise StopIteration
            if self._closing_thread is not None:
                raise DeviceBusy("the roll batch is already closing")
            if self._executing_thread is not None:
                raise DeviceBusy("another thread is already consuming this roll batch")
            self._executing_thread = threading.get_ident()

        terminal = False
        try:
            return next(self._iterator)
        except BaseException as error:
            terminal = not isinstance(error, _BatchWorkerStillActive)
            if not terminal:
                self._mark_ownership_uncertain()
            raise
        finally:
            try:
                if terminal:
                    self._release_roll_once()
            finally:
                with self._condition:
                    self._executing_thread = None
                    if terminal:
                        self._closed = True
                    self._condition.notify_all()

    def close(self) -> None:
        """Stop, wait for a cross-thread ``next``, and close the generator."""

        current_thread = threading.get_ident()
        timed_out = False
        with self._condition:
            if self._ownership_uncertain:
                raise _BatchWorkerStillActive(
                    "scan worker shutdown was not confirmed; USB ownership is retained"
                )
            if self._closed:
                return
            if self._executing_thread == current_thread or (
                self._closing_thread == current_thread
            ):
                raise DeviceBusy(
                    "cannot close a roll batch from inside its active callback"
                )
            # Hold the iterator condition while setting the shared event. An
            # executing ``next`` cannot concurrently finish/release this batch
            # and let a later batch clear the event before this write.
            self._roll.safe_stop()
            deadline = time.monotonic() + _SCAN_WORKER_JOIN_TIMEOUT_SECONDS
            while (
                self._executing_thread is not None or self._closing_thread is not None
            ):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._ownership_uncertain = True
                    timed_out = True
                    break
                self._condition.wait(timeout=remaining)
            if not timed_out and self._ownership_uncertain:
                raise _BatchWorkerStillActive(
                    "scan worker shutdown was not confirmed; USB ownership is retained"
                )
            if not timed_out and self._closed:
                return
            if not timed_out:
                self._closing_thread = current_thread

        if timed_out:
            self._roll._retain_uncertain_batch(self)
            raise _BatchWorkerStillActive(
                "scan worker did not stop before the shutdown deadline; "
                "USB ownership is retained"
            )

        try:
            close_iterator = getattr(self._iterator, "close", None)
            if callable(close_iterator):
                close_iterator()
        except _BatchWorkerStillActive:
            with self._condition:
                self._closed = False
                self._ownership_uncertain = True
                self._closing_thread = None
                self._condition.notify_all()
            self._roll._retain_uncertain_batch(self)
            raise
        except BaseException:
            self._finish_definite_close()
            raise
        else:
            self._finish_definite_close()

    def _finish_definite_close(self) -> None:
        """Release ownership before another closer can observe completion."""

        try:
            self._release_roll_once()
        finally:
            with self._condition:
                self._closed = True
                self._closing_thread = None
                self._condition.notify_all()

    def _mark_ownership_uncertain(self) -> None:
        with self._condition:
            self._ownership_uncertain = True
        self._roll._retain_uncertain_batch(self)

    def _release_roll_once(self) -> None:
        with self._condition:
            if self._released:
                return
            self._released = True
        self._roll._batch_finished(self)

    def __del__(self) -> None:
        # Roll keeps only a weak reference, so abandoning a temporary iterator
        # (the common ``for ...: break`` shape) deterministically enters the
        # same safe-stop/cleanup path on CPython instead of orphaning ownership.
        try:
            self.close()
        except BaseException:
            pass


class Roll:
    """Owns the physical transport for one whole-roll batch.

    Acquired via :meth:`Device.roll`, released on :meth:`close`/context
    exit. Construct directly (rather than via ``Device.roll()``) only in
    tests that need to inject a ``CaptureProcessAdapter`` built with a fake
    ``runner``/``batch_spawner``, or an ``LS5000SinglePassWorkflow`` built
    with a fake decoder/quality assessor, mirroring the concrete test
    suite's own seams (see tests/test_facade.py).
    """

    def __init__(
        self,
        device: "Device",
        material: Material = Material.COLOR_NEGATIVE,
        *,
        adapter: CaptureProcessAdapter | None = None,
        workflow: LS5000SinglePassWorkflow | None = None,
        attempts_root: Path | None = None,
    ) -> None:
        self._device = device
        self._material = material
        self._session: RollPreviewSession | None = None
        self._session_usb_topology: tuple[int, int] | None = None
        self._approvals: dict[int, ManualFrameApproval] = {}
        self._stop_event = threading.Event()
        self._batch_lock = threading.Lock()
        self._state_condition = threading.Condition(threading.RLock())
        self._closing = False
        self._active_batch: weakref.ReferenceType[_OwnedRollBatchIterator] | None = None
        self._uncertain_batch: _OwnedRollBatchIterator | None = None
        self._active_batch_id: int | None = None
        self._preview_active = False
        self._preview_thread_id: int | None = None
        self._callback_threads: set[int] = set()
        self._closed = False
        self._owns_attempts_root = attempts_root is None
        self._attempts_root = (
            Path(attempts_root)
            if attempts_root is not None
            else Path(tempfile.mkdtemp(prefix="coolscanpy-roll-"))
        )
        self._adapter = adapter
        self._workflow = (
            workflow if workflow is not None else LS5000SinglePassWorkflow()
        )

    # -- lifecycle -----------------------------------------------------

    @property
    def material(self) -> Material:
        return self._material

    @property
    def slot_count(self) -> int:
        """Fixed adapter capacity for this traversal, from the last
        :meth:`preview`."""

        return len(self._require_session().slots)

    def __enter__(self) -> "Roll":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def close(self) -> None:
        """Idempotently stop owned work and end the transport reservation."""

        current_thread = threading.get_ident()
        deadline = time.monotonic() + _SCAN_WORKER_JOIN_TIMEOUT_SECONDS
        with self._state_condition:
            if current_thread in self._callback_threads or (
                self._preview_active and self._preview_thread_id == current_thread
            ):
                raise DeviceBusy(
                    "cannot close the Roll from inside an active progress callback"
                )
            while self._closing and not self._closed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise DeviceBusy(
                        "another Roll.close() did not finish before the ownership "
                        "deadline; the Roll reservation is retained"
                    )
                self._state_condition.wait(timeout=remaining)
            if self._closed:
                return
            self._closing = True
            self.safe_stop()
            while self._preview_active:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._closing = False
                    self._state_condition.notify_all()
                    raise DeviceBusy(
                        "roll preview did not stop before the ownership deadline; "
                        "the Roll reservation and attempt evidence are retained"
                    )
                self._state_condition.wait(timeout=remaining)
            active = self._active_batch_locked()
            while active is None and self._active_batch_id is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._closing = False
                    self._state_condition.notify_all()
                    raise DeviceBusy(
                        "active batch ownership did not become reachable before the "
                        "ownership deadline; the Roll reservation is retained"
                    )
                self._state_condition.wait(timeout=remaining)
                active = self._active_batch_locked()

        close_error: BaseException | None = None
        if active is not None:
            try:
                active.close()
            except BaseException as error:
                close_error = error

        if isinstance(close_error, DeviceBusy):
            with self._state_condition:
                self._closing = False
                self._state_condition.notify_all()
            raise close_error

        try:
            if self._owns_attempts_root:
                shutil.rmtree(self._attempts_root, ignore_errors=True)
            self._device._release_roll_lock()
        finally:
            with self._state_condition:
                self._closed = True
                self._closing = False
                self._state_condition.notify_all()
        if close_error is not None:
            raise close_error

    # -- preview ---------------------------------------------------------

    def preview(
        self,
        slots: Iterable[int] | None = None,
        *,
        on_progress: ProgressCallback | None = None,
    ) -> list[Thumbnail]:
        """One whole-roll transport read at ~97 dpi.

        Always a full-roll hardware read; ``slots`` only filters which
        Thumbnails are returned. Establishes this Roll's ``fingerprint``.
        Calling ``preview()`` again re-reads the transport, replaces the
        fingerprint and all Thumbnails, and clears any recorded approvals
        (they become stale).
        """

        with self._state_condition:
            self._require_open_locked()
            if self._has_active_batch_locked():
                raise DeviceBusy(
                    "an active roll batch owns the scanner; close or exhaust it "
                    "before previewing again"
                )
            if self._preview_active:
                raise DeviceBusy("another roll preview is already active")
            topology = self._preview_topology_locked()
            self._preview_active = True
            self._preview_thread_id = threading.get_ident()

        io_acquired = False
        try:
            self._device._acquire_io_lock("roll preview")
            io_acquired = True
            adapter = self._ensure_adapter()
            if on_progress is not None:
                self._invoke_progress(
                    on_progress,
                    Progress(
                        stage="preview",
                        slot=None,
                        index=0,
                        total=1,
                        fraction=0.0,
                        message="reading whole-roll transport index",
                    ),
                )
            request = CaptureRequest(
                mode=CaptureMode.PREVIEW,
                expected_usb_bus=(topology[0] if topology is not None else None),
                expected_usb_address=(topology[1] if topology is not None else None),
            )
            try:
                attempt = adapter.run_attempt(request)
            except CaptureStopped as error:
                raise SafeStopRequested(str(error)) from error

            if attempt.outcome is CaptureOutcome.BOOTSTRAP_FAILED:
                raise CaptureWorkerBootstrapFailed(
                    _bootstrap_error(attempt)
                    or "CAPTURE_WORKER_BOOTSTRAP_FAILED: bundled capture worker "
                    "failed before scanner dispatch"
                )
            if attempt.outcome is CaptureOutcome.RECOVERY_REQUIRED:
                raise FeederParked(
                    _journal_error(attempt)
                    or "scanner requires a power cycle before the next attempt"
                )
            if attempt.outcome is not CaptureOutcome.COMPLETE:
                raise PyCoolscanError(
                    _journal_error(attempt)
                    or f"preview attempt did not complete: {attempt.outcome}"
                )

            session = build_roll_preview_session(attempt, material=self._material)
            with self._state_condition:
                if session.preview.usb_topology != topology:
                    raise RollMismatch(
                        "completed preview evidence belongs to a different USB "
                        "topology than this Roll"
                    )
                self._session = session
                self._session_usb_topology = topology
                self._approvals.clear()

            if on_progress is not None:
                self._invoke_progress(
                    on_progress,
                    Progress(
                        stage="preview",
                        slot=None,
                        index=1,
                        total=1,
                        fraction=1.0,
                        message="preview complete",
                    ),
                )

            wanted = None if slots is None else set(slots)
            return [
                _thumbnail_from_slot(slot)
                for slot in session.slots
                if wanted is None or slot.slot_id in wanted
            ]
        finally:
            if io_acquired:
                self._device._release_io_lock()
            with self._state_condition:
                self._preview_active = False
                self._preview_thread_id = None
                self._state_condition.notify_all()

    def restore_preview_session(
        self,
        payload: str,
        slots: Iterable[int] | None = None,
    ) -> list[Thumbnail]:
        """Restore one saved preview review without touching the scanner.

        The serialized session is accepted only after its journal, preview,
        and transport-table bytes are re-read and content-verified. Its film
        material and recorded USB topology must also match this ``Roll``.
        Restoring never carries approvals forward: callers must approve every
        currently flagged slot again before fine scanning.
        """

        with self._state_condition:
            self._require_mutable_review_locked()
            session = RollPreviewSession.from_json(payload)
            if session.material is not self._material:
                raise RollMismatch(
                    "saved preview material does not match this Roll's material"
                )
            topology = self._preview_topology_locked()
            if session.preview.usb_topology != topology:
                raise RollMismatch(
                    "saved preview USB topology does not match this Roll's device"
                )

            requested = None if slots is None else tuple(slots)
            if requested is not None:
                for slot in requested:
                    self._check_slot(session, slot)
            wanted = None if requested is None else set(requested)

            self._session = session
            self._session_usb_topology = topology
            self._approvals.clear()
            return [
                _thumbnail_from_slot(slot)
                for slot in session.slots
                if wanted is None or slot.slot_id in wanted
            ]

    # -- spacing offset ----------------------------------------------------

    def spacing_offset(self, slot: int) -> int:
        with self._state_condition:
            session = self._require_session_locked()
            self._check_slot(session, slot)
            return session.slots[slot - 1].boundary_offset_rows

    def set_spacing_offset(self, slot: int, offset_rows: int) -> Thumbnail:
        """Nudge ``slot``'s transport boundary by ``offset_rows`` native rows
        at preview resolution. Invalidates any existing approval for this
        slot and returns the freshly re-cropped preview thumbnail."""

        with self._state_condition:
            self._require_mutable_review_locked()
            session = self._require_session_locked()
            self._check_slot(session, slot)
            updated_session = session.with_boundary_offset(slot, offset_rows)
            self._session = updated_session
            self._approvals.pop(slot, None)
            return _thumbnail_from_slot(updated_session.slots[slot - 1])

    # -- fingerprint ---------------------------------------------------

    @property
    def fingerprint(self) -> RollFingerprint:
        with self._state_condition:
            session = self._require_session_locked()
            reviewed = session.reviewed_fingerprint()
            return RollFingerprint(
                sha256=reviewed.binding_sha256,
                slot_count=len(session.slots),
                preview_shape=reviewed.preview_shape,
            )

    # -- manual review / approval --------------------------------------

    def approve(self, slot: int) -> ManualFrameApproval:
        """Approve ``slot`` and return its immutable, content-bound receipt.

        The returned receipt is the exact object retained for the subsequent
        batch. Raises ``ValueError`` if the slot doesn't need approval.
        """

        with self._state_condition:
            self._require_mutable_review_locked()
            session = self._require_session_locked()
            self._check_slot(session, slot)
            offset = session.slots[slot - 1].boundary_offset_rows
            approval = session.approve_manual_origin(slot, offset)
            self._approvals[slot] = approval
            return approval

    def needs_approval(self, slot: int) -> bool:
        with self._state_condition:
            session = self._require_session_locked()
            self._check_slot(session, slot)
            return session.slots[slot - 1].manual_review

    # -- scanning --------------------------------------------------------

    def scan(self, slot: int) -> Frame:
        """Fine-scan one slot. Sugar for ``next(iter(scan_many([slot])))``."""

        iterator = self.scan_many([slot])
        try:
            return next(iterator)
        finally:
            close_iterator = getattr(iterator, "close", None)
            if callable(close_iterator):
                close_iterator()

    def scan_many(
        self,
        slots: Iterable[int],
        *,
        on_progress: ProgressCallback | None = None,
    ) -> Iterator[Frame]:
        """One continuous transport reservation for the whole ordered
        ``slots`` list, yielding a Frame as each completes.

        Color batches run on a background worker thread; each decoded Frame
        crosses back through a one-frame bounded queue, so the caller receives
        it immediately without accumulating a whole roll in memory. Abandoning
        the iterator early (a temporary ``for`` loop that breaks, or explicit
        ``.close()``) requests the same frame-boundary safe stop as
        :meth:`safe_stop` and closes the owned transport before releasing the
        reservation.

        Only ``Material.COLOR_NEGATIVE`` (single-pass RGBI4) is implemented;
        a ``Material.BLACK_AND_WHITE_NEGATIVE`` Roll raises
        ``NotImplementedError`` here (see the module docstring). Argument
        validation happens eagerly; hardware access begins lazily when the
        iterator is consumed.
        """

        with self._state_condition:
            self._require_mutable_review_locked()
            session = self._require_session_locked()
            ordered_slots = tuple(slots)
            if not ordered_slots:
                raise ValueError("scan_many requires at least one slot")
            for slot in ordered_slots:
                self._check_slot(session, slot)
            if tuple(sorted(set(ordered_slots))) != ordered_slots:
                raise ValueError(
                    "batch scanner slots must be unique and strictly increasing"
                )

            approvals = dict(self._approvals)
            for slot in ordered_slots:
                if session.slots[slot - 1].manual_review:
                    approval = approvals.get(slot)
                    offset = session.slots[slot - 1].boundary_offset_rows
                    if approval is None or not session.validate_manual_approval(
                        approval,
                        slot_id=slot,
                        boundary_offset_rows=offset,
                    ):
                        raise ManualReviewRequired(
                            f"slot {slot} requires visual review; "
                            f"call approve({slot}) before scanning it",
                            slot=slot,
                        )

            if session.recipe.capture_route is not CaptureRoute.SINGLE_PASS_RGBI4:
                raise NotImplementedError(_BLACK_AND_WHITE_NOT_WIRED)
            topology = self._session_usb_topology
            if topology is None:
                raise BatchIntegrityError(
                    "color batch has no exact USB topology from its reviewed preview"
                )
            requests = tuple(
                CaptureRequest(
                    mode=CaptureMode.FULL,
                    selected_slot=slot,
                    boundary_offset_rows=session.slots[slot - 1].boundary_offset_rows,
                    manual_review_approval=approvals.get(slot),
                )
                for slot in ordered_slots
            )
            batch_request = CaptureBatchRequest(
                frames=requests,
                reviewed_fingerprint=session.reviewed_fingerprint(),
                expected_usb_bus=topology[0],
                expected_usb_address=topology[1],
            )
            iterator = self._scan_many(
                batch_request,
                ordered_slots,
                on_progress,
            )
            return self._reserve_batch_locked(iterator)

    def _scan_many(
        self,
        batch_request: CaptureBatchRequest,
        slots: tuple[int, ...],
        on_progress: ProgressCallback | None,
    ) -> Iterator[Frame]:
        if self._stop_event.is_set():
            raise SafeStopRequested(
                f"safe stop requested; 0 of {len(slots)} requested frames completed"
            )
        adapter = self._ensure_adapter()
        single_pass_session = SinglePassSession(
            root=self._attempts_root,
            session_id=f"scan-{uuid4().hex}",
        )
        workflow = self._workflow
        device_id = self._device._info.id
        produced_count = 0
        density_preview_evidence: NikonDensityEvidence | None = None

        # maxsize=1: the worker may finish decoding/finalizing at most one
        # frame beyond whatever is already queued before it blocks on
        # put(), which is exactly the "~2 frames in flight" bound this
        # queue exists to enforce.
        frame_queue: "queue.Queue[tuple[str, Any]]" = queue.Queue(maxsize=1)

        def frame_handler(attempt_result: Any) -> BatchAckAction:
            nonlocal density_preview_evidence, produced_count
            density_evidence = getattr(attempt_result, "density_evidence", None)
            if density_evidence is not None:
                existing = density_preview_evidence
                if existing is not None and density_evidence != existing:
                    raise BatchIntegrityError(
                        "batch attempts disagree on Nikon preview density evidence"
                    )
                density_preview_evidence = density_evidence
            density_ownership = getattr(attempt_result, "density_ownership", None)
            if density_preview_evidence is None or density_ownership is None:
                raise BatchIntegrityError(
                    "batch frame has no exact Nikon density preview ownership"
                )
            try:
                density_ownership.validate_evidence(density_preview_evidence)
            except (TypeError, ValueError) as error:
                raise BatchIntegrityError(
                    f"batch frame Nikon density ownership is invalid: {error}"
                ) from error
            single_pass_attempt = SinglePassAttempt.from_capture_result(
                session=single_pass_session,
                result=attempt_result,
            )
            try:
                finalization = workflow.finalize_attempt(single_pass_attempt)
            except SinglePassWorkflowError as error:
                raise _translate_finalization_error(error) from error
            meter_rgbi, final_f02_denominators = _read_exact_analyzer_source(
                single_pass_attempt,
                finalization,
            )
            try:
                exact_builder_evidence = build_nikon_exact_builder_evidence(
                    density_preview_evidence,
                    density_ownership,
                    analyzer_rgb=meter_rgbi[:, :, :3],
                    final_f02_denominators=final_f02_denominators,
                )
            except (TypeError, ValueError, RuntimeError) as error:
                raise BatchIntegrityError(
                    f"batch frame Nikon exact builder evidence is invalid: {error}"
                ) from error
            frame = _read_frame(
                finalization,
                slot=attempt_result.request.selected_slot,
                device_id=device_id,
                meter_rgbi=meter_rgbi,
                density_evidence=density_preview_evidence,
                density_ownership=density_ownership,
                exact_builder_evidence=exact_builder_evidence,
            )
            produced_count += 1
            if on_progress is not None:
                self._invoke_progress(
                    on_progress,
                    Progress(
                        stage="fine-scan",
                        slot=frame.slot,
                        index=produced_count - 1,
                        total=len(slots),
                        fraction=1.0,
                        message=f"slot {frame.slot} complete",
                    ),
                )
            # Blocks until the consumer (or an abandonment drain) makes
            # room -- this, not a size counter, is the backpressure.
            frame_queue.put(("frame", frame))
            return (
                BatchAckAction.STOP
                if self._stop_event.is_set()
                else BatchAckAction.CONTINUE
            )

        def run_batch() -> None:
            try:
                try:
                    result = adapter.run_batch_session(
                        batch_request, frame_handler=frame_handler
                    )
                except CaptureStopped as error:
                    try:
                        raise SafeStopRequested(str(error)) from error
                    except SafeStopRequested as translated:
                        frame_queue.put(("error", translated))
                    return
                except CaptureBatchProcessError as error:
                    # frame_handler's own exceptions (including the typed
                    # ones frame_handler above already translates) arrive
                    # here wrapped, chained via `from handler_error` --
                    # unwrap back to the original typed exception rather
                    # than leaking the adapter's internal wrapper type.
                    cause = error.__cause__
                    try:
                        if error.outcome is CaptureOutcome.BOOTSTRAP_FAILED:
                            raise CaptureWorkerBootstrapFailed(str(error)) from error
                        if isinstance(cause, PyCoolscanError):
                            raise cause from error
                        raise BatchIntegrityError(str(error)) from error
                    except BaseException as translated:
                        frame_queue.put(("error", translated))
                    return

                if result.outcome is CaptureOutcome.BOOTSTRAP_FAILED:
                    frame_queue.put(
                        (
                            "error",
                            CaptureWorkerBootstrapFailed(
                                (result.session_journal or {}).get("error")
                                or "CAPTURE_WORKER_BOOTSTRAP_FAILED: bundled "
                                "capture worker failed before scanner dispatch"
                            ),
                        )
                    )
                    return
                if result.outcome is CaptureOutcome.RECOVERY_REQUIRED:
                    frame_queue.put(
                        (
                            "error",
                            FeederParked(
                                (result.session_journal or {}).get("error")
                                or "scanner requires a power cycle before the next attempt"
                            ),
                        )
                    )
                    return
                if result.outcome is CaptureOutcome.SYNCHRONIZED_REFUSAL:
                    message = (result.session_journal or {}).get("error") or (
                        "roll batch was refused before any frame was captured"
                    )
                    if (
                        "does not match the reviewed roll fingerprint" in message
                        or "does not match its reviewed visual fingerprint" in message
                    ):
                        frame_queue.put(
                            (
                                "error",
                                FingerprintRefused(
                                    message,
                                    comparison=FingerprintComparison(
                                        matches=False,
                                        reason=message,
                                        compared_frames=0,
                                        visual_median_hamming=None,
                                        visual_p90_hamming=None,
                                        frame_start_median_delta_rows=None,
                                        frame_start_max_delta_rows=None,
                                    ),
                                ),
                            )
                        )
                        return
                    if "transport origin requires manual review" in message:
                        frame_queue.put(
                            ("error", ManualReviewRequired(message, slot=slots[0]))
                        )
                        return
                    frame_queue.put(("error", RollMismatch(message)))
                    return

                frame_queue.put(
                    ("stopped", produced_count)
                    if result.stopped
                    else ("complete", None)
                )
            except BaseException as error:  # pragma: no cover - safety net
                # Guarantees the consumer's queue.get() is never left
                # waiting forever for a terminal item that a genuinely
                # unexpected exception here would otherwise skip.
                frame_queue.put(("error", error))

        def run_owned_batch() -> None:
            try:
                run_batch()
            except BaseException as error:
                self._device._mark_fault_if_cleanup_error(error)
                frame_queue.put(("error", error))

        worker_thread = threading.Thread(
            target=run_owned_batch,
            name="coolscanpy-roll-scan-many",
            daemon=True,
        )
        worker_thread.start()
        try:
            while True:
                kind, payload = frame_queue.get()
                if kind == "frame":
                    yield payload
                    continue
                if kind == "error":
                    raise payload
                if kind == "stopped":
                    raise SafeStopRequested(
                        f"safe stop requested; {payload} of {len(slots)} "
                        "requested frames completed"
                    )
                return  # kind == "complete"
        except GeneratorExit:
            self.safe_stop()
            _drain_abandoned_scan_queue(frame_queue, worker_thread)
            raise
        finally:
            worker_thread.join(timeout=_SCAN_WORKER_JOIN_TIMEOUT_SECONDS)
            if worker_thread.is_alive():
                raise _BatchWorkerStillActive(
                    "scan worker did not stop before the ownership deadline; "
                    "USB ownership is retained"
                )

    # -- eject / safe stop -------------------------------------------------

    def safe_stop(self) -> None:
        """Request a graceful stop. The frame in flight always finishes;
        the next one raises ``SafeStopRequested`` instead of starting."""

        self._stop_event.set()

    def eject(self) -> bool:
        return self._device.eject()

    # -- internals -------------------------------------------------------

    def _ensure_adapter(self) -> CaptureProcessAdapter:
        if self._adapter is None:
            self._adapter = CaptureProcessAdapter.packaged(self._attempts_root)
        return self._adapter

    def _reserve_batch_locked(
        self,
        iterator: Iterator[Frame],
    ) -> _OwnedRollBatchIterator:
        """Reserve one already-frozen lazy batch while state lock is held."""

        if self._has_active_batch_locked():
            raise DeviceBusy("another roll batch is already active")
        self._device._acquire_io_lock("roll batch reservation")
        batch_acquired = False
        try:
            if not self._batch_lock.acquire(blocking=False):
                raise DeviceBusy("another roll batch is already active")
            batch_acquired = True
            self._stop_event.clear()
            owned = _OwnedRollBatchIterator(self, iterator)
            self._active_batch = weakref.ref(owned)
            self._uncertain_batch = None
            self._active_batch_id = id(owned)
            return owned
        except BaseException:
            if batch_acquired:
                self._batch_lock.release()
            self._device._release_io_lock()
            raise

    def _batch_finished(self, batch: _OwnedRollBatchIterator) -> None:
        with self._state_condition:
            if self._active_batch_id != id(batch):
                return
            self._active_batch = None
            self._uncertain_batch = None
            self._active_batch_id = None
            self._batch_lock.release()
            self._device._release_io_lock()
            self._state_condition.notify_all()

    def _invoke_progress(
        self,
        callback: ProgressCallback,
        progress: Progress,
    ) -> None:
        thread_id = threading.get_ident()
        with self._state_condition:
            self._callback_threads.add(thread_id)
        try:
            callback(progress)
        finally:
            with self._state_condition:
                self._callback_threads.discard(thread_id)
                self._state_condition.notify_all()

    def _active_batch_locked(self) -> _OwnedRollBatchIterator | None:
        if self._uncertain_batch is not None:
            return self._uncertain_batch
        reference = self._active_batch
        return None if reference is None else reference()

    def _retain_uncertain_batch(self, batch: _OwnedRollBatchIterator) -> None:
        """Keep fail-closed ownership reachable until explicitly resolved."""

        with self._state_condition:
            if self._active_batch_id != id(batch):
                return
            self._uncertain_batch = batch
            self._state_condition.notify_all()

    def _has_active_batch_locked(self) -> bool:
        return self._active_batch_id is not None

    def _preview_topology_locked(self) -> tuple[int, int] | None:
        """Bind preview to exact USB topology whenever it is knowable."""

        device_id = self._device._info.id
        topology = _COOLSCAN3_TOPOLOGY.fullmatch(device_id)
        if topology is None:
            topology = _USB_FALLBACK_TOPOLOGY.fullmatch(device_id)
        if topology is None:
            raise BatchIntegrityError(
                "roll preview requires an exact local coolscan3 or USB fallback "
                "topology; remote SANE IDs are not supported"
            )
        return int(topology.group("bus")), int(topology.group("address"))

    def _require_mutable_review_locked(self) -> None:
        self._require_open_locked()
        if self._closing:
            raise DeviceBusy("the Roll is closing")
        if self._has_active_batch_locked():
            raise DeviceBusy(
                "an active roll batch freezes the reviewed session and approvals"
            )
        if self._preview_active:
            raise DeviceBusy("an active roll preview freezes the reviewed session")

    def _require_open(self) -> None:
        with self._state_condition:
            self._require_open_locked()

    def _require_open_locked(self) -> None:
        if self._closed or self._closing:
            raise RuntimeError("this Roll has been closed")

    def _require_session(self) -> RollPreviewSession:
        with self._state_condition:
            return self._require_session_locked()

    def _require_session_locked(self) -> RollPreviewSession:
        self._require_open_locked()
        if self._session is None:
            raise RuntimeError("preview() has not been called yet")
        return self._session

    @staticmethod
    def _check_slot(session: RollPreviewSession, slot: int) -> None:
        if (
            isinstance(slot, bool)
            or not isinstance(slot, int)
            or not 1 <= slot <= len(session.slots)
        ):
            raise ValueError(f"unknown roll slot: {slot!r}")


def _public_fingerprint_comparison(value: Any) -> FingerprintComparison:
    return FingerprintComparison(
        matches=value.matches,
        reason=value.reason,
        compared_frames=value.compared_frames,
        visual_median_hamming=value.visual_median_hamming,
        visual_p90_hamming=value.visual_p90_hamming,
        frame_start_median_delta_rows=value.frame_start_median_delta_rows,
        frame_start_max_delta_rows=value.frame_start_max_delta_rows,
    )


def _drain_abandoned_scan_queue(
    frame_queue: "queue.Queue[tuple[str, Any]]",
    worker_thread: threading.Thread,
) -> None:
    """Unblock a ``_scan_many`` worker stuck writing to a full queue after
    the consumer abandoned the iterator mid-batch (``GeneratorExit``).

    The caller has already requested a safe stop, so at most one more frame
    (already in flight) and then exactly one terminal marker are still
    coming; discard whatever frames arrive -- nobody wants them anymore --
    until the terminal marker appears or the bounded deadline passes.
    """

    deadline = time.monotonic() + _SCAN_WORKER_JOIN_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            kind, _payload = frame_queue.get(timeout=0.5)
        except queue.Empty:
            if not worker_thread.is_alive():
                return
            continue
        if kind != "frame":
            return


def _thumbnail_from_slot(slot: Any) -> Thumbnail:
    return Thumbnail(
        slot=slot.slot_id,
        image=slot.thumbnail,
        boundary_rows=slot.boundary_rows,
        spacing_offset=slot.boundary_offset_rows,
        needs_approval=slot.manual_review,
        warnings=slot.warnings,
    )


def _journal_error(attempt: Any) -> str | None:
    journal = attempt.journal
    if isinstance(journal, dict):
        error = journal.get("error")
        if isinstance(error, str):
            return error
    return None


def _bootstrap_error(attempt: Any) -> str | None:
    """Return only the adapter's already-validated pre-dispatch detail.

    Recovery outcomes intentionally continue to read only a trustworthy
    worker journal. A bootstrap attempt has no such journal, so its bounded
    marker detail is carried separately in ``journal_error``.
    """

    if attempt.outcome is not CaptureOutcome.BOOTSTRAP_FAILED:
        return None
    detail = attempt.journal_error
    return detail if isinstance(detail, str) and detail else None


def _translate_finalization_error(error: SinglePassWorkflowError) -> PyCoolscanError:
    """Map a completed-frame finalization failure to the public exception
    it corresponds to in the API contract's exception table.

    ``LS5000SinglePassWorkflow.finalize_attempt`` raises one shared
    ``SinglePassIntegrityError``/``SinglePassWorkflowError`` for every
    failure mode (decode-shape mismatch, roll-identity inconsistency, smear
    QC refusal, ...) -- there is no per-cause exception type to catch
    instead. The two causes the API contract names explicitly are
    recognized by message text; everything else falls back to
    ``BatchIntegrityError`` (self-verification failed before publication),
    which is the contract's own catch-all for this layer.
    """

    message = str(error)
    if "stopped-transport smear QC refused" in message:
        verdict = "smear"
        reason = message
        marker = "refused decoded RGB: "
        if marker in message:
            tail = message.split(marker, 1)[1]
            verdict, _, reason = tail.partition(": ")
        return TransportSmearDetected(
            message,
            assessment=TransportSmearAssessment(
                verdict=verdict
                if verdict in ("smear", "indeterminate")
                else "indeterminate",
                start_row=None,
                suffix_rows=0,
                minimum_matches=0,
                tail_median_rms=None,
                tail_min_corr=None,
                pre_tail_median_rms=None,
                texture_span=None,
                reason=reason or message,
            ),
        )
    if "decoder returned" in message and "expected" in message:
        return GeometryValidationError(message)
    return BatchIntegrityError(message)


def _array_evidence(array: np.ndarray) -> ArtifactEvidence:
    contiguous = np.ascontiguousarray(array)
    payload = memoryview(contiguous).cast("B")
    return ArtifactEvidence(
        sha256=hashlib.sha256(payload).hexdigest(),
        byte_length=payload.nbytes,
        shape=tuple(contiguous.shape),
        dtype=str(contiguous.dtype),
    )


def _ticks_to_microseconds(raw: object) -> float:
    """Convert one raw 10ns hardware exposure tick count to microseconds."""

    return (
        float(raw) * 0.01
        if isinstance(raw, (int, float)) and not isinstance(raw, bool)
        else 0.0
    )


def _build_receipt(
    manifest: dict[str, Any],
    *,
    device_id: str,
    artifacts: dict[str, ArtifactEvidence],
    storage_transform: str,
    density_ownership: NikonDensityFrameOwnershipReceipt | None = None,
) -> Receipt:
    """Adapt a completed ``LS5000SinglePassWorkflow`` manifest dict into the
    public ``Receipt`` shape.

    ``exposure.focus_position``/``.exposure_multiplier`` are fixed
    placeholders (0 / 1.0): the single-pass RGBI4 protocol's own telemetry is
    raw per-channel hardware exposure ticks with no focus-position or
    exposure-multiplier concept, unlike the SANE-based plain-scan path's
    ``ScannerCaptureState``. ``red/green/blue_exposure_us`` are populated
    faithfully by converting those raw 10ns ticks to microseconds.
    ``split_alignment`` is always ``None`` for this route: RGB and IR share
    one pass with no separate registration step. ``storage_transform`` is
    required (Sol adversarial review 2026-07-26, finding 2): the caller
    passes this frame's own ``DigitalIceAcquisitionEvidence.storage_transform``
    so the value published on the public Receipt can never drift from the
    value actually used to build the scanner-native Digital ICE pair.
    """

    capture = manifest["capture"]
    frame_evidence = manifest["frame_evidence"]
    exposure_evidence = manifest["exposure_evidence"]
    quality_control = manifest["quality_control"]
    identity = manifest["identity"]

    roll_identity = frame_evidence.get("roll_identity") or {}
    manual_payload = frame_evidence.get("manual_review_approval")
    manual_approval = None
    if manual_payload:
        manual_approval = ApprovalReceipt(
            reviewed_fingerprint_sha256=manual_payload["reviewed_fingerprint_sha256"],
            slot=manual_payload["slot"],
            spacing_offset=manual_payload["boundary_offset_rows"],
            thumbnail_sha256=manual_payload["thumbnail_sha256"],
            reviewed_lookup_row=manual_payload["reviewed_lookup_row"],
            reviewed_native_origin=manual_payload["reviewed_native_origin"],
            review_reasons=tuple(manual_payload["review_reasons"]),
        )

    wire = (exposure_evidence.get("accepted_contract") or {}).get(
        "wire_colors_raw_10ns"
    ) or {}
    exposure = ExposureVector(
        focus_position=0,
        exposure_multiplier=1.0,
        red_exposure_us=_ticks_to_microseconds(wire.get("1")),
        green_exposure_us=_ticks_to_microseconds(wire.get("2")),
        blue_exposure_us=_ticks_to_microseconds(wire.get("3")),
    )

    smear = quality_control["stopped_transport_smear"]["assessment"]
    transport_smear = TransportSmearAssessment(
        verdict=smear["verdict"],
        start_row=smear.get("start_row"),
        suffix_rows=smear["suffix_rows"],
        minimum_matches=smear["minimum_matches"],
        tail_median_rms=smear.get("tail_median_rms"),
        tail_min_corr=smear.get("tail_min_corr"),
        pre_tail_median_rms=smear.get("pre_tail_median_rms"),
        texture_span=smear.get("texture_span"),
        reason=smear["reason"],
    )
    clip = quality_control["capture_clipping"]
    clipping = ClippingTelemetry(
        fractions=tuple(clip["fractions"]),
        clip_level=clip["clip_level"],
        warning_fraction=clip["warning_fraction"],
        warning=clip["warning"],
    )
    focus = quality_control["focus_detail"]
    focus_detail = FocusDetailTelemetry(
        method=focus["method"],
        verdict=focus["verdict"],
        score=focus.get("score"),
        texture_span=focus["texture_span"],
    )

    return Receipt(
        version=RECEIPT_VERSION,
        slot=identity["selected_slot"],
        spacing_offset=identity["boundary_offset_rows"],
        dpi=LS5000_FINE_DPI,
        depth=LS5000_FINE_DEPTH,
        device_id=device_id,
        device_model=capture["scanner_identity"],
        reviewed_fingerprint_sha256=roll_identity.get(
            "reviewed_fingerprint_sha256", ""
        ),
        fresh_fingerprint_sha256=roll_identity.get("fresh_fingerprint_sha256", ""),
        manual_approval=manual_approval,
        exposure=exposure,
        split_alignment=None,
        clipping=clipping,
        focus_detail=focus_detail,
        transport_smear=transport_smear,
        artifacts=artifacts,
        storage_transform=storage_transform,
        nikon_density_ownership=density_ownership,
    )


def _stable_file_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_bound_regular_file(
    path: Path,
    *,
    expected_bytes: int,
    label: str,
) -> bytes:
    """Read one exact-size, stable, non-symlink acquisition artifact."""

    if type(expected_bytes) is not int or expected_bytes < 1:
        raise BatchIntegrityError(f"{label} byte count is malformed")
    try:
        linked = os.lstat(path)
        if stat.S_ISLNK(linked.st_mode):
            raise BatchIntegrityError(f"{label} must not be a symlink")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
    except BatchIntegrityError:
        raise
    except OSError as error:
        raise BatchIntegrityError(
            f"{label} cannot be opened safely: {error}"
        ) from error
    try:
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise BatchIntegrityError(f"{label} is not a regular file")
            if (linked.st_dev, linked.st_ino) != (before.st_dev, before.st_ino):
                raise BatchIntegrityError(f"{label} changed while it was opened")
            if before.st_size != expected_bytes:
                raise BatchIntegrityError(
                    f"{label} has {before.st_size} bytes; expected {expected_bytes}"
                )
            payload = handle.read(expected_bytes + 1)
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise BatchIntegrityError(f"{label} could not be read: {error}") from error
    if len(payload) != expected_bytes:
        raise BatchIntegrityError(
            f"{label} read {len(payload)} bytes; expected {expected_bytes}"
        )
    if _stable_file_identity(before) != _stable_file_identity(after):
        raise BatchIntegrityError(f"{label} changed while it was read")
    return payload


def _validated_wire_exposures(value: object, *, label: str) -> dict[str, int]:
    if type(value) is not dict or set(value) != {"1", "2", "3", "9"}:
        raise BatchIntegrityError(f"{label} must contain exact RGB+IR wire colors")
    result: dict[str, int] = {}
    for color in ("1", "2", "3", "9"):
        exposure = value[color]
        if type(exposure) is not int or not 1 <= exposure <= 0xFFFFFFFF:
            raise BatchIntegrityError(f"{label} color {color} is not a nonzero uint32")
        result[color] = exposure
    return result


def _read_exact_analyzer_source(
    attempt: SinglePassAttempt,
    finalization: SinglePassFinalizationResult,
) -> tuple[np.ndarray, tuple[int, int, int]]:
    """Recover the settled same-frame 285-dpi raster and final f02 RGB.

    Both inputs are accepted only when the finalized manifest, immutable
    capture journal, full three-pass sidecar, pass histories, and controller
    decision all agree. Missing legacy sidecars therefore fail closed instead
    of silently producing a frame that cannot drive Nikon-exact inversion.
    """

    manifest = finalization.manifest
    sources = manifest.get("sources")
    journal_evidence = sources.get("capture_journal") if type(sources) is dict else None
    if (
        type(journal_evidence) is not dict
        or journal_evidence.get("path") != attempt.journal_path.name
        or type(journal_evidence.get("bytes")) is not int
        or type(journal_evidence.get("sha256")) is not str
    ):
        raise BatchIntegrityError(
            "finalized frame has no exact capture-journal source binding"
        )
    journal_bytes = journal_evidence["bytes"]
    if not 1 <= journal_bytes <= 16 * 1024 * 1024:
        raise BatchIntegrityError("finalized capture journal size is out of bounds")
    journal_payload = _read_bound_regular_file(
        attempt.journal_path,
        expected_bytes=journal_bytes,
        label="capture journal",
    )
    journal_sha256 = hashlib.sha256(journal_payload).hexdigest()
    if not hmac.compare_digest(journal_sha256, journal_evidence["sha256"]):
        raise BatchIntegrityError("capture journal changed after finalization")
    try:
        journal = json.loads(journal_payload)
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise BatchIntegrityError("capture journal is not valid JSON") from error
    if type(journal) is not dict:
        raise BatchIntegrityError("capture journal root is malformed")

    meter_path = attempt.stream_path.with_name(f"{attempt.stream_path.stem}-meter.bin")
    meter_evidence = journal.get("meter_evidence")
    expected_meter_bytes = _METER_PASS_BYTES * 3
    if (
        type(meter_evidence) is not dict
        or meter_evidence.get("path") != str(meter_path.resolve())
        or meter_evidence.get("bytes") != expected_meter_bytes
        or meter_evidence.get("complete") is not True
        or meter_evidence.get("durable_completed_passes") != 3
        or type(meter_evidence.get("sha256")) is not str
        or journal.get("meter_evidence_persisted_before_fine_arm") is not True
    ):
        raise BatchIntegrityError(
            "frame has no complete durable three-pass meter-sidecar binding"
        )
    if journal.get("meter_group_bytes") != [_METER_PASS_BYTES] * 3:
        raise BatchIntegrityError("meter sidecar pass byte counts are inconsistent")
    if journal.get("meter_group_offsets") != [
        0,
        _METER_PASS_BYTES,
        _METER_PASS_BYTES * 2,
    ]:
        raise BatchIntegrityError("meter sidecar pass offsets are inconsistent")
    if (
        journal.get("meter_completed_bytes") != expected_meter_bytes
        or journal.get("meter_completed_reads") != 15
    ):
        raise BatchIntegrityError("meter sidecar completion counters are inconsistent")
    expected_layout = {
        "passes": 3,
        "rows_per_pass": 425,
        "columns": 281,
        "decoded_raster_channel_order": ["R", "G", "B", "IR"],
        "wire_window_color_order": [9, 1, 2, 3],
        "wire_color_to_controller_channel": {
            "9": "IR",
            "1": "R",
            "2": "G",
            "3": "B",
        },
        "sample_byte_order": "big-endian-u16",
        "row_core_bytes": 2_248,
        "row_stride_bytes": 2_560,
        "row_tail_bytes": 312,
    }
    if journal.get("meter_layout") != expected_layout:
        raise BatchIntegrityError("meter sidecar wire layout is not the pinned layout")

    pass_history = journal.get("meter_pass_exposures_raw_10ns")
    if type(pass_history) is not list or len(pass_history) != 3:
        raise BatchIntegrityError(
            "meter sidecar has no exact three-pass exposure history"
        )
    pass_exposures = [
        _validated_wire_exposures(value, label=f"meter pass {index} exposure")
        for index, value in enumerate(pass_history, start=1)
    ]
    if journal.get("meter_observed_exposures_raw_10ns") != pass_exposures:
        raise BatchIntegrityError("meter observed exposure history changed")
    commanded = journal.get("meter_pass_commanded_exposures")
    if type(commanded) is not list or len(commanded) != 3:
        raise BatchIntegrityError("meter commanded exposure history is incomplete")
    for index, (record, wire) in enumerate(
        zip(commanded, pass_exposures, strict=True),
        start=1,
    ):
        expected_controller = {
            "R": wire["1"],
            "G": wire["2"],
            "B": wire["3"],
            "IR": wire["9"],
        }
        if (
            type(record) is not dict
            or record.get("pass") != index
            or record.get("wire_colors_raw_10ns") != wire
            or record.get("controller_channels_raw_10ns") != expected_controller
        ):
            raise BatchIntegrityError(
                f"meter pass {index} commanded exposure binding changed"
            )

    exposure_evidence = manifest.get("exposure_evidence")
    accepted_contract = (
        exposure_evidence.get("accepted_contract")
        if type(exposure_evidence) is dict
        else None
    )
    final_wire_value = (
        accepted_contract.get("wire_colors_raw_10ns")
        if type(accepted_contract) is dict
        else None
    )
    final_wire = _validated_wire_exposures(
        final_wire_value,
        label="final SET_WINDOW exposure",
    )
    final_controller = {
        "R": final_wire["1"],
        "G": final_wire["2"],
        "B": final_wire["3"],
        "IR": final_wire["9"],
    }
    if (
        accepted_contract.get("controller_channels_raw_10ns") != final_controller
        or journal.get("meter_final_exposures") != accepted_contract
    ):
        raise BatchIntegrityError(
            "final f02 exposure contract changed after acceptance"
        )
    controller = journal.get("meter_controller_final_result")
    steps = controller.get("steps") if type(controller) is dict else None
    last_observation = (
        steps[-1].get("observation")
        if type(steps) is list and len(steps) == 1 and type(steps[-1]) is dict
        else None
    )
    third_wire = pass_exposures[-1]
    third_controller = {
        "R": third_wire["1"],
        "G": third_wire["2"],
        "B": third_wire["3"],
        "IR": third_wire["9"],
    }
    if (
        type(controller) is not dict
        or controller.get("accepted") is not True
        or type(last_observation) is not dict
        or last_observation.get("exposures_raw_10ns") != third_controller
    ):
        raise BatchIntegrityError(
            "settled third meter pass is not bound to the accepted controller result"
        )
    # Since the guarded nikon-parity solve became the RGB command authority,
    # the commanded contract is bound to the active controller's accepted
    # solve THROUGH the journaled authority record: active solve -> authority
    # -> commanded contract, with infrared passing through unchanged.
    authority = journal.get("active_exposure_authority")
    if (
        type(authority) is not dict
        or authority.get("rgb_source") != "nikon-parity-guarded-v2"
        or authority.get("ir_source") != "active-controller"
        or authority.get("commanded_channels_raw_10ns") != final_controller
        or authority.get("active_controller_channels_raw_10ns")
        != controller.get("final_exposures_raw_10ns")
        or type(controller.get("final_exposures_raw_10ns")) is not dict
        or final_controller.get("IR")
        != controller["final_exposures_raw_10ns"].get("IR")
    ):
        raise BatchIntegrityError(
            "commanded exposure contract is not bound to the parity authority "
            "and the accepted controller result"
        )

    meter_payload = _read_bound_regular_file(
        meter_path,
        expected_bytes=expected_meter_bytes,
        label="meter sidecar",
    )
    meter_sha256 = hashlib.sha256(meter_payload).hexdigest()
    if not hmac.compare_digest(meter_sha256, meter_evidence["sha256"]):
        raise BatchIntegrityError("meter sidecar does not match its capture digest")
    from coolscanpy.protocol.ls5000_single_pass.meter import decode_meter_pass

    try:
        decoded = decode_meter_pass(meter_payload[_METER_PASS_BYTES * 2 :])
    except (TypeError, ValueError) as error:
        raise BatchIntegrityError(
            f"settled meter pass cannot be decoded: {error}"
        ) from error
    return decoded.image, (final_wire["1"], final_wire["2"], final_wire["3"])


def _read_frame(
    finalization: SinglePassFinalizationResult,
    *,
    slot: int,
    device_id: str,
    meter_rgbi: "np.ndarray | None" = None,
    density_evidence: NikonDensityEvidence | None = None,
    density_ownership: NikonDensityFrameOwnershipReceipt | None = None,
    exact_builder_evidence: NikonExactBuilderEvidence | None = None,
) -> Frame:
    output_paths = finalization.output_paths
    rgb = tifffile.imread(output_paths["rgb"])
    ir = tifffile.imread(output_paths["ir"])
    ir_validity = tifffile.imread(output_paths["ir_valid_mask"]).astype(bool)
    if meter_rgbi is None or density_ownership is None:
        raise BatchIntegrityError(
            "color frame cannot publish without its meter and reservation ownership"
        )
    artifacts = {"rgb": _array_evidence(rgb), "ir": _array_evidence(ir)}
    try:
        digital_ice_evidence = build_digital_ice_acquisition_evidence(
            slot=slot,
            reservation_id=density_ownership.reservation_id,
            capture_attempt_id=density_ownership.frame_capture_attempt_id,
            storage_rgb=rgb,
            storage_ir=ir,
            storage_ir_validity=ir_validity,
            meter_rgbi=meter_rgbi,
        )
    except (TypeError, ValueError) as error:
        raise BatchIntegrityError(
            f"Digital ICE acquisition evidence could not be bound: {error}"
        ) from error
    receipt = _build_receipt(
        finalization.manifest,
        device_id=device_id,
        artifacts=artifacts,
        storage_transform=digital_ice_evidence.storage_transform,
        density_ownership=density_ownership,
    )
    _cleanup_finalization(finalization)
    return Frame(
        slot=slot,
        rgb=rgb,
        ir=ir,
        ir_validity=ir_validity,
        receipt=receipt,
        meter_rgbi=meter_rgbi,
        nikon_density_evidence=density_evidence,
        nikon_exact_builder_evidence=exact_builder_evidence,
        digital_ice_evidence=digital_ice_evidence,
    )


def _cleanup_finalization(finalization: SinglePassFinalizationResult) -> None:
    """Remove the private scratch/output files this facade wrote so it never
    leaves a public-looking output folder behind (see module §8 in the API
    spec: this package returns arrays, not files)."""

    for path in finalization.output_paths.values():
        path.unlink(missing_ok=True)
    finalization.manifest_path.unlink(missing_ok=True)
    checkpoint = finalization.manifest_path.parent / "scratch-deletion.json"
    checkpoint.unlink(missing_ok=True)
    try:
        finalization.manifest_path.parent.rmdir()
    except OSError:
        pass
