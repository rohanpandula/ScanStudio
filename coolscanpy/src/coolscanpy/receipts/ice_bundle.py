"""Acquisition and receipt-building for one dual-RGBI portable-ICE capture.

One selected roll slot becomes one dual-RGBI acquisition and one on-disk
bundle, handed off to a separate defect-repair engine for processing. The
scanner handle is closed before the bundle is written to disk, and
acquisition here is deliberately separate from whatever engine invocation and
publication step a caller builds on top of it.
"""

from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable

from coolscanpy.transport.libsane_dual_source import (
    DiceDualSourcePlan,
    Libsane,
    acquire_dual_sources,
    write_capture_bundle,
)

ICE_FRAME_RECEIPT_KIND = "negpy.ls5000-ice-frame"
ICE_FRAME_RECEIPT_VERSION = 1


class IceRollError(RuntimeError):
    """A roll ICE step failed in a way the caller must surface verbatim."""


def acquire_ice_bundle(
    *,
    device_id: str,
    plan: DiceDualSourcePlan,
    bundle_root: Path,
    run_id: str,
    progress: Callable[[float], None] | None = None,
) -> Path:
    """Acquire one dual-RGBI pair and persist it; the handle never outlives this call.

    The SANE session is opened and closed inside this function so the caller
    can prove the scanner is released before any processing starts.  The
    bundle is written after both closes: the arrays are already in memory and
    disk I/O has no business extending a hardware reservation.
    """

    sane = Libsane()
    try:
        identity = sane.require_ls5000(device_id)
        device = sane.open(identity.device_id, identity=identity)
        try:
            capture = acquire_dual_sources(device, plan, progress=progress)
        finally:
            device.close()
    finally:
        sane.close()
    return write_capture_bundle(
        bundle_root,
        device_id=capture.scanner_identity.device_id,
        plan=plan,
        capture=capture,
        run_id=run_id,
    )


def build_ice_receipt(
    processed: Any,
    *,
    roll_slot: int,
    boundary_offset_rows: int,
) -> dict[str, Any]:
    """Assemble the provenance receipt published beside the cleaned TIFF.

    ``processed`` is duck-typed (an object exposing ``.plan``,
    ``.bundle_manifest_sha256``, and ``.ice`` with ``.requested_backend``/
    ``.used_backend``/``.selection_reason``/``.receipt``) rather than a
    concrete type, since the engine-invocation result this reads lives
    outside this package.
    """

    return {
        "kind": ICE_FRAME_RECEIPT_KIND,
        "version": ICE_FRAME_RECEIPT_VERSION,
        "roll_slot": roll_slot,
        "boundary_offset_rows": boundary_offset_rows,
        "plan": processed.plan.semantic_dict(),
        "bundle_manifest_sha256": processed.bundle_manifest_sha256,
        "backend": {
            "requested": processed.ice.requested_backend.value,
            "used": processed.ice.used_backend.value,
            "selection_reason": processed.ice.selection_reason,
        },
        "engine_receipt": asdict(processed.ice.receipt),
    }


__all__ = [
    "ICE_FRAME_RECEIPT_KIND",
    "ICE_FRAME_RECEIPT_VERSION",
    "IceRollError",
    "acquire_ice_bundle",
    "build_ice_receipt",
]
