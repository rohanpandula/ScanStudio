"""The `Transport` contract `MockTransport` (transport/mock.py) and
`CoolscanPyTransport` (transport/coolscanpy_transport.py) both satisfy
structurally -- a `typing.Protocol`, no explicit inheritance needed. See
BRIDGE.md (nikon-coolscan4-software-archaeology,
app/ScanStudio/protocol/BRIDGE.md) for the wire-level meaning of every
method below; this module only fixes the in-process Python shape both
implementations share.
"""

from __future__ import annotations

import time
from typing import Callable, Protocol, TypeVar

from scanstudio_bridge import domain

_T = TypeVar("_T")

# `on_call(phase, name, elapsed_seconds, kind, *, call_outcome=None,
# exception_class=None)`: a call-boundary telemetry hook (Plan 10-04,
# nikon-coolscan4-software-archaeology
# .planning/phases/10-real-capture/LIVE-VERIFICATION-20260723.md) a
# Transport's start_scan may invoke around each of its own hardware/file
# calls -- `phase` is `"enter"` (elapsed_seconds is always `None`; nothing
# has elapsed yet) or `"exit"` (elapsed_seconds is the real wall-clock
# duration of that one call).
#
# `kind` (Plan 10-09, nikon-coolscan4-software-archaeology
# .planning/phases/10-real-capture/10-09-PLAN.md) distinguishes a
# fine-grained SDK/file call (`"call"`, telemetry method `scan.call` --
# Plan 10-04's original granularity, what the soft-timeout watchdog keys
# off) from a coarser conceptual workflow phase (`"phase"`, telemetry
# method `scan.phase` -- Plan 10-09's addition, e.g. one slot's whole
# fine-scan operation, which coolscanpy does not expose as separately
# callable position/autofocus/auto-exposure/read-pass sub-steps -- see
# coolscanpy_transport.py's `_scan_one_slot` docstring).
#
# `call_outcome`/`exception_class` (Plan 10-09) are populated only on an
# "exit" call: `call_outcome` is `"return"` when `fn()` returned normally or
# `"raise"` when it raised, and `exception_class` is that raised
# exception's `type(...).__name__` (`None` on a normal return). Previously
# an "exit" entry looked identical whether the wrapped call returned or
# raised -- this closes that gap without changing what "enter"/"exit"
# themselves mean.
#
# Every one of `kind`/`call_outcome`/`exception_class` is optional and
# defaulted so every pre-existing direct `start_scan(...)`/`on_call(...)`
# call site (this codebase's own test suite included, e.g.
# tests/test_scan_worker_telemetry.py's `_HangingTransport`, which calls
# `on_call("enter", name, None)` with only 3 positional args) keeps working
# unchanged.
OnCall = Callable[..., None]


class Transport(Protocol):
    def list_devices(self) -> list[domain.DeviceInfo]: ...

    def open_device(self, device_id: str) -> domain.DeviceInfo: ...

    def status(self) -> domain.DeviceStatus: ...

    def close_device(self) -> None: ...

    def preview(
        self,
        material: domain.Material,
        slots: list[int] | None,
        on_thumbnail: Callable[[domain.Thumbnail], None],
    ) -> domain.PreviewResult: ...

    def approve(self, slot: int, *, fingerprint: str | None = None) -> None:
        """Approve `slot`. `fingerprint`, when given, is the Roll
        fingerprint (BRIDGE.md's `roll.approve`) the approval being
        submitted was minted against -- additive (2026-08-08 adversarial
        review, S1): `None` is the pre-existing behavior (no comparison); a
        given value that no longer matches the roll's CURRENT fingerprint
        must be refused with `FINGERPRINT_REFUSED` before any underlying
        approval call, never silently approved against whatever session
        happens to be current now."""
        ...

    def set_spacing_offset(
        self, slot: int, offset_rows: int
    ) -> domain.Thumbnail: ...

    def manual_frames(
        self, rows: list[int]
    ) -> tuple[
        domain.PreviewResult,
        tuple[domain.Thumbnail, ...],
        tuple[domain.BoundarySnap, ...],
        domain.Material,
    ]:
        """Rung 4 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): re-slice the
        last completed preview attempt's already-decoded raster at
        operator-picked boundary rows -- no hardware call, no film
        movement. Usable only when a preview attempt (successful or
        refused) already exists this session; raises `NO_PREVIEW`
        otherwise. Leaves roll/session state armed exactly like a
        successful `preview()` -- the returned `domain.Material` is what
        the caller must re-arm `scan.start`'s own NO_PREVIEW gate with,
        since this call carries no `material` param of its own (the
        session already has one)."""
        ...

    def preview_strip(self) -> domain.PreviewStrip:
        """Rung 4: render the last completed preview attempt's whole
        captured raster to one image, for a manual-placement editor to
        draw boundary lines on before any row has been picked. Same
        precondition and NO_PREVIEW failure as `manual_frames`; no hardware
        call."""
        ...

    def start_scan(
        self,
        slots: list[int],
        recipe: domain.CaptureRecipe,
        output: domain.OutputSpec,
        on_progress: Callable[[domain.ScanProgress], None],
        on_retry: Callable[[int, int, str], None],  # slot, attempt, reason
        on_frame: Callable[[int, domain.ScanReceipt], None],
        on_call: OnCall | None = None,
    ) -> domain.ScanSummary: ...

    def request_stop(self) -> None: ...  # stop between transfers, per BRIDGE.md scan.stop

    def eject(self) -> bool: ...


class FrameRetryExhausted(Exception):
    """Raised by a Transport's start_scan when a slot's bounded retry budget
    (safety.MAX_FRAME_RETRIES additional attempts) is exhausted. Caught by
    Plan 08-03's service.py to run safety.anomaly_halt."""

    def __init__(self, slot: int, last_error: Exception) -> None:
        super().__init__(f"slot {slot}: frame retry budget exhausted: {last_error}")
        self.slot = slot
        self.last_error = last_error


def timed_call(
    on_call: OnCall | None, name: str, fn: Callable[[], _T], *, kind: str = "call"
) -> _T:
    """Runs `fn()`, calling `on_call("enter", name, None, kind)` immediately
    before and `on_call("exit", name, elapsed_seconds, kind, ...)`
    immediately after. Shared by both Transport implementations so every
    call-boundary measurement in this codebase uses identical timing
    semantics. If `fn` never returns at all (the exact failure mode Plan
    10-04's watchdog exists to catch), "exit" correctly never fires either
    -- that asymmetry (an "enter" with no matching "exit") is the
    diagnostic signal a stuck call leaves behind.

    Plan 10-09 (raise-aware call telemetry): unlike the pre-10-09 version,
    "exit" no longer looks identical on a normal return vs. a raised
    exception -- it now always fires (still unconditionally, on every exit
    path) but carries `call_outcome="return"` or `call_outcome="raise"` plus
    `exception_class=type(exc).__name__` so a telemetry reader can tell
    which happened without cross-referencing anything else. The exception
    itself is never swallowed or altered here -- always re-raised
    unchanged after the "exit" call-boundary telemetry is recorded.
    `kind` (`"call"` default, or `"phase"`) picks which telemetry method
    name (`scan.call` vs `scan.phase`) the entry is recorded under -- see
    `OnCall`'s own docstring above."""
    if on_call is not None:
        on_call("enter", name, None, kind)
    started_at = time.monotonic()
    try:
        result = fn()
    except BaseException as exc:
        if on_call is not None:
            on_call(
                "exit",
                name,
                time.monotonic() - started_at,
                kind,
                call_outcome="raise",
                exception_class=type(exc).__name__,
            )
        raise
    if on_call is not None:
        on_call(
            "exit", name, time.monotonic() - started_at, kind, call_outcome="return"
        )
    return result


def phased_call(on_call: OnCall | None, name: str, fn: Callable[[], _T]) -> _T:
    """`timed_call`, layered twice under one `name`: an outer `scan.phase`
    boundary (`kind="phase"`) wrapping an inner `scan.call` boundary
    (`kind="call"`) -- Plan 10-09's phase-boundary telemetry for a call
    boundary that has no further internal call-level granularity of its own
    (e.g. one file write: a single atomic operation, unlike a slot's
    fine-scan, which already has its own separate per-attempt `scan.call`
    granularity from retries -- see coolscanpy_transport.py's `start_scan`
    for how that case wires a `"phase"`-kind `timed_call` directly around
    `_scan_one_slot` instead of using this helper). The identical span is
    therefore meaningfully both a "call" (Plan 10-04's original
    per-SDK/file-call granularity, what the soft-timeout watchdog keys off)
    and a "phase" (Plan 10-09's coarser conceptual-workflow-step
    granularity) -- sharing one `name` lets a telemetry reader trivially
    correlate the two."""
    return timed_call(
        on_call, name, lambda: timed_call(on_call, name, fn, kind="call"), kind="phase"
    )
