"""Best-effort forwarding of CoolscanPy's per-frame exposure authority.

The block is already formed and validated by CoolscanPy.  This module only
locates the just-completed frame journal and converts that additive record
to the bridge wire dataclass.  Missing, ambiguous, or malformed evidence is
reported on stderr and returned as ``None``; it must never fail a scan.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from scanstudio_bridge import domain

__all__ = ["build_exposure_authority", "ExposureAuthorityRefused"]


class ExposureAuthorityRefused(Exception):
    """The journal could not establish one unambiguous authority block."""


def _log(message: str) -> None:
    try:
        print(
            f"scanstudio-bridge: exposure_authority: {message}",
            file=sys.stderr,
            flush=True,
        )
    except Exception:
        # Broken diagnostics must not turn optional provenance into a scan
        # failure.
        pass


def _load_json(path: Path) -> dict:
    if not path.is_file():
        raise ExposureAuthorityRefused(f"expected evidence file missing: {path}")
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ExposureAuthorityRefused(f"{path}: invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ExposureAuthorityRefused(f"{path}: journal root is not an object")
    return value


def _find_frame_attempt_directory(attempts_root: Path, slot: int) -> Path:
    frame_dirname = f"frame-{slot:03d}"
    candidates = sorted(
        attempts_root.glob(f"batch-slot*/{frame_dirname}/journal.json"),
        key=lambda path: path.stat().st_mtime,
    )
    if not candidates:
        raise ExposureAuthorityRefused(
            f"no {frame_dirname}/journal.json evidence found under any "
            f"batch-slot*/ directory in {attempts_root}"
        )
    if (
        len(candidates) > 1
        and candidates[-1].stat().st_mtime == candidates[-2].stat().st_mtime
    ):
        raise ExposureAuthorityRefused(
            f"{len(candidates)} {frame_dirname}/journal.json candidates found under "
            f"{attempts_root}, and the two newest are mtime-indistinguishable; "
            "refusing to guess which attempt is this frame's own"
        )
    return candidates[-1].parent


def _build_exposure_authority(
    *, attempts_root: Path | None, slot: int
) -> domain.ExposureAuthority:
    if attempts_root is None:
        raise ExposureAuthorityRefused(
            "no attempts_root for this transport/route; cannot locate capture evidence"
        )

    journal_path = _find_frame_attempt_directory(attempts_root, slot) / "journal.json"
    authority = _load_json(journal_path).get("active_exposure_authority")
    if not isinstance(authority, dict):
        raise ExposureAuthorityRefused(
            f"{journal_path}: no active_exposure_authority block; refusing to fabricate provenance"
        )

    try:
        return domain.ExposureAuthority(
            rgb_source=str(authority["rgb_source"]),
            ir_source=str(authority["ir_source"]),
            commanded_channels_raw_10ns=dict(authority["commanded_channels_raw_10ns"]),
            active_controller_channels_raw_10ns=dict(
                authority["active_controller_channels_raw_10ns"]
            ),
            device_bound_clamped_channels_raw_10ns=dict(
                authority["device_bound_clamped_channels_raw_10ns"]
            ),
            device_exposure_bounds_raw_10ns=tuple(
                authority["device_exposure_bounds_raw_10ns"]
            ),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise ExposureAuthorityRefused(
            f"{journal_path}: active_exposure_authority malformed: {error}"
        ) from error


def build_exposure_authority(
    *, attempts_root: Path | None, slot: int
) -> domain.ExposureAuthority | None:
    """Return the frame's authority block, or ``None`` on any failure."""
    try:
        authority = _build_exposure_authority(attempts_root=attempts_root, slot=slot)
    except ExposureAuthorityRefused as error:
        _log(f"slot {slot}: unavailable: {error}")
        return None
    except Exception as error:
        _log(f"slot {slot}: unavailable: unexpected {type(error).__name__}: {error}")
        return None
    _log(f"slot {slot}: assembled (rgbSource={authority.rgb_source!r})")
    return authority
