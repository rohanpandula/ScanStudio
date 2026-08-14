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
    "capture_process.py": "c4d234c02bcabf5d10c83b9ef9f071c591546c2447ca004610cc0e0c804a3944",
    "worker.py": "08b9fdb46bc072923d46c1efc4d4a901fd943de542624bc536cd440c3fb6294b",
    "manual_frames.py": "f30f0003e081c3a98610d5700d7e6b6ee4d182b9d5228932f3304f1307d4815f",
    "usb_backend.py": "afb5b3cbb57404b758f4f8d8795f4307c07c8f6d01bbeccb3ced38026787fd62",
    "density.py": "c2c47de2886bc4b60197d2721b6d72050a76f1095760590fa7bb34a728b9da76",
    "packed.py": "856315714e4f7e81f42e1ca93917e4cc0feb03b24915c2ad604302bfdca46f87",
    "streaming_sidecar.py": "81ca79a72b37dee579d57be07bd00f59f6e7843a43710bab1811d8b9a94dffb7",
    "continuation_plan.py": "bfdebfaa28075c708f3e8ef070083edce36a28b497bba622173cbb6d1466a282",
    "meter.py": "6b17a06fd1baf1be872a19e819d4e642d42e542601c82b506891bb943969a25c",
    "roll_index.py": "ae64e28a5d7e442cc368995b47c60ea1097f95f272fff558e93c7fc50800a5ef",
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
