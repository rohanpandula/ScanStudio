"""SAFE-02: armed latch, single hardware lane, telemetry log, and the
anomaly-halt helper. See BRIDGE.md's "SAFE-02 guardrails" section
(nikon-coolscan4-software-archaeology, app/ScanStudio/protocol/BRIDGE.md)
for the wire-level contract this module implements the mechanism for.

Every entry point accepts `base_dir` explicitly (defaulting to the real
`~/.scanstudio`) -- there is no module-level cached state anywhere in this
file, and the armed latch is re-read from disk on every single call. This
codebase's own test suite always passes `tmp_path` instead, so no test run
ever touches the real `~/.scanstudio`.
"""

from __future__ import annotations

import fcntl
import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

from scanstudio_bridge.protocol import BridgeError, ErrorCode

if TYPE_CHECKING:
    from scanstudio_bridge import transport

HW_MOTION_ENV_VAR = "SCANSTUDIO_HW_MOTION"
DEFAULT_BASE_DIR = Path.home() / ".scanstudio"
MAX_FRAME_RETRIES = 2  # additional attempts beyond the first; 3 total

_LATCH_FILENAME = "hw-motion-armed"
_LANE_LOCK_FILENAME = "hw-lane.lock"
_TELEMETRY_DIRNAME = "hw-telemetry"


def armed_media(base_dir: Path = DEFAULT_BASE_DIR) -> str | None:
    """Live re-check, never cached. `None` unless `SCANSTUDIO_HW_MOTION` is
    `"1"` AND `base_dir / "hw-motion-armed"` exists with non-empty stripped
    content, in which case that content (the loaded media's name) is
    returned."""
    if os.environ.get(HW_MOTION_ENV_VAR) != "1":
        return None
    try:
        content = (base_dir / _LATCH_FILENAME).read_text().strip()
    except OSError:
        return None
    return content or None


def require_armed(base_dir: Path = DEFAULT_BASE_DIR) -> str:
    """`armed_media(base_dir)`, or raise `BridgeError(HW_MOTION_NOT_ARMED)`
    when it's `None`."""
    media = armed_media(base_dir)
    if media is None:
        raise BridgeError(
            ErrorCode.HW_MOTION_NOT_ARMED,
            "motion refused: SCANSTUDIO_HW_MOTION unset or "
            "hw-motion-armed latch missing/empty",
        )
    return media


class HardwareLane:
    """Advisory single-lane lock: `base_dir / "hw-lane.lock"`, held for the
    duration of any motion-capable operation. A second contender's
    `__enter__` raises `BridgeError(HARDWARE_LANE_BUSY)` immediately rather
    than blocking."""

    def __init__(self, base_dir: Path = DEFAULT_BASE_DIR) -> None:
        self._lock_path = base_dir / _LANE_LOCK_FILENAME
        self._fh = None

    def __enter__(self) -> "HardwareLane":
        self._lock_path.parent.mkdir(parents=True, exist_ok=True)
        fh = self._lock_path.open("a+")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            fh.close()
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "hardware lane is already held by another operation",
            ) from exc
        self._fh = fh
        return self

    def __exit__(self, *exc: object) -> None:
        if self._fh is not None:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
            self._fh.close()
            self._fh = None


class TelemetryLog:
    """Appends one JSONL line per `record()` call to
    `base_dir / "hw-telemetry" / f"{session_id}.jsonl"`, flushed
    immediately so a mid-batch crash never loses an already-recorded
    entry."""

    def __init__(
        self, base_dir: Path = DEFAULT_BASE_DIR, session_id: str | None = None
    ) -> None:
        self.session_id = session_id if session_id is not None else uuid.uuid4().hex
        path = base_dir / _TELEMETRY_DIRNAME / f"{self.session_id}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = path.open("a")

    def record(self, method: str, outcome: str, **fields: object) -> None:
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": method,
            "outcome": outcome,
            **fields,
        }
        self._fh.write(json.dumps(entry))
        self._fh.write("\n")
        self._fh.flush()


def anomaly_halt(
    transport: "transport.Transport",
    telemetry: TelemetryLog,
    *,
    reason: str,
    code: str,
    slot: int | None,
) -> dict:
    """Best-effort `transport.eject()` (an anomaly response must never
    itself raise and mask the original fault), a telemetry record, and a
    result dict -- NOT `"laneReleased"`: the caller (service.py, Plan
    08-03) owns the `with HardwareLane(...)` block and adds that field
    itself once the block actually exits."""
    try:
        ejected = bool(transport.eject())
    except Exception:
        ejected = False
    telemetry.record(
        "hardware.anomaly",
        "halted",
        reason=reason,
        code=code,
        slot=slot,
        ejected=ejected,
    )
    return {"reason": reason, "code": code, "slot": slot, "ejected": ejected}
