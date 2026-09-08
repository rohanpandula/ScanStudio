"""Integrity identity for the package-owned LS-5000 capture bundle."""

from __future__ import annotations

import hashlib
import json
from importlib.resources import files
from pathlib import Path

from .continuation_plan import (
    CANONICAL_CONTINUATION_PLAN_FILENAME,
    CANONICAL_CONTINUATION_PLAN_SHA256,
    canonical_continuation_plan_bytes,
)
from .plan import CANONICAL_PLAN_SHA256, canonical_plan_bytes


DATA_PACKAGE = "coolscanpy.protocol.ls5000_single_pass.data"
CANONICAL_MANIFEST_FILENAME = "replay-first-rgbi4-manifest.json"

# These hashes bind the scanner-facing implementation and both wire resources.
# Update them only after the corresponding hardware-free regression suite passes.
# ``packed.py`` (the shared decode kernel and streaming decoder) and
# ``streaming_sidecar.py`` (the fail-open capture hook) are pinned because the
# capture worker imports them at runtime, so their bytes are part of the
# scanner-facing capture identity. ``density.py`` is pinned for the same
# reason: it validates the acquisition-specific READ(0x8c) replies, the
# density-source cap-0x10d/f03 exposures, the proven 97-dpi reservation-preview
# evidence, runtime arithmetic gate, and exact per-frame ownership receipt.
CAPTURE_BUNDLE_COMPONENT_SHA256 = {
    # Resealed 2026-09-08: held-child non-motion film-status rendezvous.
    # 0.7.9 preview: held metering/explicit refusal skips plus retained local
    # timing, required scanner identity and adapter-conditional replay.
    # Resealed 2026-09-07 (CoolscanPy 0.7.8): worker.py derives the 1-sample
    # fine READ and binds the selected USB identity; capture_process.py
    # validates the derived byte total and carries that identity; packed.py
    # validates the derived record geometry and trailing pad. The vendored
    # worker retains ScanStudio's timing and adapter-conditional replay.
    # meter.py gives IR its measured 0.95 correlation floor while R/G/B keep
    # 0.98. No wire resource, plan, or continuation template changed.
    # Resealed 2026-09-06 (samples_per_scan): capture_process.py and
    # worker.py gained the 1|4 samples-per-scan batch parameter that patches
    # the fine SET_WINDOW multi-read byte and its GET_WINDOW echo before
    # preflight; 4 remains a verified byte-for-byte no-op.
    # Resealed 2026-08-22 (ScanStudio #16): manual_frames.py gained an
    # honest direct_fraction on its RollDetection construction;
    # roll_index.py gained the degraded-gap-evidence confidence tier, the
    # DEGRADED_GAP_EVIDENCE_WARNING marker, and the additive
    # RollDetection.direct_fraction field.
    # Resealed 2026-08-13 (attended scan binding, feed-detector round;
    # ScanStudio #24/#16/#42): capture_process.py gained the
    # ATTENDED_ROLL_BINDING_* pair and ManualFrameApproval.
    # is_attended_roll_binding; worker.py gained the attended branch of the
    # roll-confidence gate plus its journal marker, layered on this copy's
    # standing issue #70 EVPD adapter-conditional replay below -- worker.py's
    # bytes are therefore unique to this bundle and re-hashed accordingly.
    # Resealed 2026-08-10 (issue #70): worker.py gained adapter-conditional
    # EVPD replay -- the live page-00h list gates which traced EVPD INQUIRY
    # entries the inserted adapter can answer (MA-21 drops page E2h).
    # Prior reseal 2026-08-07 (FEEDING-UX-LADDER-OVERNIGHT-20260807.md,
    # Rung 4): both files gained CaptureBatchRequest/LiveBatchJob's
    # additive manual_boundary_rows field plus its batch-job.json plumbing.
    # Resealed 2026-08-11: capture descendants remain in the bridge-owned
    # process group and inherit its exclusive process-ownership fence.
    "capture_process.py": "e66a50d07a4704a10f38f3d477432e0e2b3853c23c43a70e740950bd2dccb2ea",
    "worker.py": "d42ec7a564e16b53aa388969bda81a6dd536bbbc5332aa9440f729349701752e",
    "manual_frames.py": "8fc4ba82c177e1b7ecd6943354db33930b468ef3b4b82c712202b8caea54c9bb",
    "usb_backend.py": "afb5b3cbb57404b758f4f8d8795f4307c07c8f6d01bbeccb3ced38026787fd62",
    "density.py": "c2c47de2886bc4b60197d2721b6d72050a76f1095760590fa7bb34a728b9da76",
    # Resealed 2026-08-12 after a complete 2,980-record LS-5000 capture
    # established the strict EBDE-prefixed padding-counter dialect.
    "packed.py": "4388e6667ccdb8a1fba9ee4325a2913eee8b3965de13f81f0975afd1eacaadba",
    "streaming_sidecar.py": "81ca79a72b37dee579d57be07bd00f59f6e7843a43710bab1811d8b9a94dffb7",
    "continuation_plan.py": "bfdebfaa28075c708f3e8ef070083edce36a28b497bba622173cbb6d1466a282",
    "meter.py": "35adb86c43ccae29584768d929c253d595d0547b33dd0d0b784d2601b1ded9d6",
    "roll_index.py": "c99c54a434d0d53e94e51ed503f0289709b5f20365e16606f365264a617c8b17",
    "window.py": "5edd64a2f55cb3c968bb380d548d0d9002b41b26f5f4713e5d9b889910d5ed4f",
    "data/replay-first-rgbi4-plan.jsonl": CANONICAL_PLAN_SHA256,
    f"data/{CANONICAL_CONTINUATION_PLAN_FILENAME}": (
        CANONICAL_CONTINUATION_PLAN_SHA256
    ),
    "data/replay-first-rgbi4-manifest.json": "a87faad5aa4cb458d6044cc218ab4fc13ce84f03d5355e7ea47c04c76f290e5f",
}
CAPTURE_WORKER_SHA256 = CAPTURE_BUNDLE_COMPONENT_SHA256["worker.py"]
CAPTURE_BUNDLE_SHA256 = hashlib.sha256(
    json.dumps(
        CAPTURE_BUNDLE_COMPONENT_SHA256,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")
).hexdigest()


class CaptureBundleIntegrityError(RuntimeError):
    """The installed scanner capture bundle differs from its pinned identity."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def canonical_manifest_bytes() -> bytes:
    """Return the bundled Nikon wire manifest after validating its plan binding."""

    payload = files(DATA_PACKAGE).joinpath(CANONICAL_MANIFEST_FILENAME).read_bytes()
    expected = CAPTURE_BUNDLE_COMPONENT_SHA256[f"data/{CANONICAL_MANIFEST_FILENAME}"]
    actual = _sha256(payload)
    if actual != expected:
        raise CaptureBundleIntegrityError(
            f"canonical capture manifest SHA-256 mismatch: expected {expected}, got {actual}"
        )
    try:
        manifest = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CaptureBundleIntegrityError(
            f"canonical capture manifest is not valid JSON: {error}"
        ) from error
    if (
        not isinstance(manifest, dict)
        or manifest.get("plan_sha256") != CANONICAL_PLAN_SHA256
    ):
        raise CaptureBundleIntegrityError(
            "canonical capture manifest is not bound to the packaged replay plan"
        )
    return payload


def verify_capture_bundle(*, require_python_sources: bool) -> str:
    """Verify package resources and, when available, every Python source file.

    Installed wheels and source checkouts expose their ``.py`` files directly.
    A frozen app executes modules from PyInstaller's signed archive, so it can
    only revalidate the separately bundled wire resources at runtime; its code
    identity is the app bundle signature plus ``CAPTURE_BUNDLE_SHA256``.
    """

    if _sha256(canonical_plan_bytes()) != CANONICAL_PLAN_SHA256:
        raise CaptureBundleIntegrityError("canonical capture plan changed")
    if (
        _sha256(canonical_continuation_plan_bytes())
        != CANONICAL_CONTINUATION_PLAN_SHA256
    ):
        raise CaptureBundleIntegrityError("canonical continuation plan changed")
    canonical_manifest_bytes()
    if require_python_sources:
        package_root = Path(__file__).resolve().parent
        for relative, expected in CAPTURE_BUNDLE_COMPONENT_SHA256.items():
            if relative.startswith("data/"):
                continue
            path = package_root / relative
            if not path.is_file():
                raise CaptureBundleIntegrityError(
                    f"capture component is not a regular file: {path}"
                )
            actual = _sha256(path.read_bytes())
            if actual != expected:
                raise CaptureBundleIntegrityError(
                    f"capture component {relative} SHA-256 mismatch: "
                    f"expected {expected}, got {actual}"
                )
    return CAPTURE_BUNDLE_SHA256


__all__ = [
    "CANONICAL_MANIFEST_FILENAME",
    "CAPTURE_BUNDLE_COMPONENT_SHA256",
    "CAPTURE_BUNDLE_SHA256",
    "CAPTURE_WORKER_SHA256",
    "CaptureBundleIntegrityError",
    "canonical_manifest_bytes",
    "verify_capture_bundle",
]
