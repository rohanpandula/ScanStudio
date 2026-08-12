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

try:
    import fcntl
except ImportError:  # Windows has byte-range locks instead of flock
    fcntl = None
    import msvcrt
import json
import os
import secrets
import stat
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
_PROCESS_OWNER_LOCK_FILENAME = "bridge-process-owner.lock"
_TELEMETRY_DIRNAME = "hw-telemetry"
_MAX_LATCH_BYTES = 4096

PROCESS_OWNER_FD_ENV_VAR = "SCANSTUDIO_BRIDGE_OWNER_FD"
PROCESS_OWNER_TOKEN_ENV_VAR = "SCANSTUDIO_BRIDGE_OWNER_TOKEN"


def armed_media(base_dir: Path = DEFAULT_BASE_DIR) -> str | None:
    """Live re-check, never cached. `None` unless `SCANSTUDIO_HW_MOTION` is
    `"1"` AND `base_dir / "hw-motion-armed"` is a regular, non-symlink file
    with non-empty stripped authorization text, which is returned."""
    if os.environ.get(HW_MOTION_ENV_VAR) != "1":
        return None
    descriptor = -1
    try:
        descriptor = os.open(
            base_dir / _LATCH_FILENAME,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            return None
        with os.fdopen(descriptor, "rb") as latch_file:
            descriptor = -1
            payload = latch_file.read(_MAX_LATCH_BYTES + 1)
            if len(payload) > _MAX_LATCH_BYTES:
                return None
            content = payload.decode("utf-8").strip()
    except (OSError, UnicodeError):
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
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
        contention_exc = BlockingIOError if fcntl is not None else OSError
        try:
            if fcntl is not None:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
        except contention_exc as exc:
            fh.close()
            raise BridgeError(
                ErrorCode.HARDWARE_LANE_BUSY,
                "hardware lane is already held by another operation",
            ) from exc
        self._fh = fh
        return self

    def __exit__(self, *exc: object) -> None:
        if self._fh is not None:
            try:
                if fcntl is not None:
                    fcntl.flock(self._fh, fcntl.LOCK_UN)
                else:
                    self._fh.seek(0)
                    msvcrt.locking(self._fh.fileno(), msvcrt.LK_UNLCK, 1)
            finally:
                self._fh.close()
                self._fh = None


class BridgeProcessOwnership:
    """Cross-process lifetime fence for a bridge and every capture worker.

    The production Windows lane launches this bridge inside WSL, where the
    inherited POSIX descriptor has the same lifetime semantics as Linux and
    macOS. A native-Windows invocation fails closed: msvcrt byte-range locks
    cannot be safely handed through the existing worker launcher.
    """

    def __init__(self, base_dir: Path = DEFAULT_BASE_DIR) -> None:
        self._path = base_dir / _PROCESS_OWNER_LOCK_FILENAME
        self._fd = -1
        self.token = secrets.token_hex(16)

    @property
    def fd(self) -> int:
        if self._fd < 0:
            raise RuntimeError("bridge process ownership has not been acquired")
        return self._fd

    def acquire(self) -> "BridgeProcessOwnership":
        if fcntl is None:
            raise BridgeError(
                ErrorCode.INTERNAL,
                "bridge process ownership requires the packaged WSL/POSIX runtime",
            )
        self._path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            self._path,
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
            0o600,
        )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise BridgeError(
                    ErrorCode.INTERNAL,
                    "bridge ownership lock is not a regular file owned by this user",
                )
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise BridgeError(
                    ErrorCode.HARDWARE_LANE_BUSY,
                    "another bridge or surviving capture worker still owns the scanner process group",
                ) from exc
            record = json.dumps(
                {"bridgePid": os.getpid(), "launchToken": self.token},
                separators=(",", ":"),
            ).encode("utf-8")
            os.ftruncate(descriptor, 0)
            os.write(descriptor, record)
            os.fsync(descriptor)
            os.set_inheritable(descriptor, True)
        except Exception:
            os.close(descriptor)
            raise

        self._fd = descriptor
        os.environ[PROCESS_OWNER_FD_ENV_VAR] = str(descriptor)
        os.environ[PROCESS_OWNER_TOKEN_ENV_VAR] = self.token
        return self

    def close(self) -> None:
        if self._fd < 0:
            return
        descriptor = self._fd
        self._fd = -1
        if os.environ.get(PROCESS_OWNER_FD_ENV_VAR) == str(descriptor):
            os.environ.pop(PROCESS_OWNER_FD_ENV_VAR, None)
        if os.environ.get(PROCESS_OWNER_TOKEN_ENV_VAR) == self.token:
            os.environ.pop(PROCESS_OWNER_TOKEN_ENV_VAR, None)
        # Do not unlock explicitly: surviving capture workers inherited this
        # open file description and must keep its scanner fence alive.
        os.close(descriptor)


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
