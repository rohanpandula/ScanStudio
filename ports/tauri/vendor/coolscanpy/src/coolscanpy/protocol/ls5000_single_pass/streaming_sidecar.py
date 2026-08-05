"""Fail-open streaming decode sidecar for LS-5000 single-pass capture.

The USB capture loop owns acquisition and the durable raw stream.  This module
adds a streaming decode that runs concurrently, off the USB hot path, and can
publish a *privately persisted* decoded artifact plus a strict receipt so that
offline finalization may consume it instead of re-decoding the raw oracle --
a real speedup, while the raw capture stays authoritative and every guarantee
fails closed:

* the decoded RGBI frame is written directly into a private ``.npy`` backed by
  a temporary memmap, so there is no second full-frame allocation or copy;
* the data artifact and a strict receipt are published only after an exact,
  padding-valid finish whose decode proof is canonical (no invented defaults),
  durably fsynced, never overwritten, with the receipt written last as the
  commit marker;
* finalization re-validates everything (raw SHA/size binding, derived file
  hash, shape/dtype/layout) before consuming, and falls back to offline decode
  on any absent/abandoned/incomplete/corrupt/mismatched sidecar.

Timeouts cannot kill a wedged decoder thread.  If the consumer is still inside
``push`` when the bounded finish deadline expires, the session disables the
stream promptly but never unmaps, flushes, unlinks, or publishes the live
mapping.  Cleanup is deferred to a janitor that waits for the thread to
terminate; if it never does, a clearly private temporary partial may leak for
the process lifetime rather than risk a crash.

Two layers:

* :class:`FailOpenStreamConsumer` -- a generic, decoder-agnostic, nonblocking
  producer/consumer.  Submission never blocks and is bounded by a small queue;
  a queue-full, a consumer exception, or a failed finish permanently disables
  the stream for that frame and is reported, never raised.
* :class:`FineStreamSession` -- the LS-5000 adapter that feeds a
  :class:`~coolscanpy.protocol.ls5000_single_pass.packed.StreamingFrameDecoder`
  and publishes the bound artifact/receipt.

Neither layer imports USB or performs any scanner I/O.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import queue
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

import numpy as np

from .packed import (
    CHANNELS,
    FULL_RECORD_BYTES,
    HEIGHT,
    WIDTH,
    StreamingFrameDecoder,
)


_SENTINEL = object()
_UNSET = object()

DEFAULT_MAX_QUEUE = 4
# One short, explicit bound for the entire seal-and-collect wait after the data
# phase.  It only covers the residual bounded queue (the consumer decodes as
# records arrive), so it is materially below 60 s and keeps a wedged consumer
# from holding a retained batch reservation before ACK.  A timeout abandons
# streaming; it never aborts the capture and never kills the decoder thread.
DEFAULT_FINISH_TIMEOUT_SECONDS = 5.0
_POLL_SECONDS = 0.05

STREAM_DATA_SUFFIX = ".stream-rgbi.npy"
STREAM_RECEIPT_SUFFIX = ".stream-receipt.json"
STREAM_RECEIPT_KIND = "negpy.ls5000-stream-receipt"
STREAM_RECEIPT_VERSION = 1
STREAM_RECEIPT_STATUS = "complete"

# The exact, canonical decode proof.  A receipt layout must carry precisely
# these keys with precisely these values; the publisher never fills defaults.
CANONICAL_RGB_AVERAGE = "round-half-up uint16 average"
CANONICAL_DECODE_PROOF_KEYS = frozenset(
    {
        "padding_validated_records",
        "rgb_samples_decoded",
        "ir_planes_transferred",
        "rgb_average",
    }
)
STREAM_RECEIPT_KEYS = frozenset(
    {
        "kind",
        "version",
        "status",
        "derived_filename",
        "derived_sha256",
        "derived_bytes",
        "raw_sha256",
        "raw_bytes",
        "height",
        "width",
        "channels",
        "dtype",
        "layout",
    }
)
STREAM_RECEIPT_LAYOUT_KEYS = CANONICAL_DECODE_PROOF_KEYS

_LOWER_HEX = "0123456789abcdef"


def _is_lower_hex64(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in _LOWER_HEX for character in value)
    )


def _proof_is_canonical(layout: object, records: int) -> bool:
    if not isinstance(layout, dict) or set(layout) != CANONICAL_DECODE_PROOF_KEYS:
        return False
    padding = layout.get("padding_validated_records")
    return (
        type(padding) is int
        and padding == records
        and type(layout.get("rgb_samples_decoded")) is int
        and layout.get("rgb_samples_decoded") == 4
        and type(layout.get("ir_planes_transferred")) is int
        and layout.get("ir_planes_transferred") == 1
        and layout.get("rgb_average") == CANONICAL_RGB_AVERAGE
    )


class FailOpenStreamConsumer:
    """Bounded, nonblocking, fail-open feeder for any push/finish decoder.

    ``factory`` returns a fresh decoder exposing ``push(bytes)`` and
    ``finish() -> result``.  A single daemon thread drains a bounded queue into
    the decoder; the thread (and the factory) start lazily on first submission,
    so constructing a consumer allocates nothing.

    :meth:`submit` is nonblocking: a full queue or any error permanently
    disables the stream and returns ``False`` instead of raising, so a slow or
    dead consumer can never stall the producer.  Mutable ``bytearray`` /
    ``memoryview`` submissions are copied before queueing so later caller
    mutation cannot alter decode evidence; immutable ``bytes`` pass through
    cheaply.

    :meth:`disable` releases the *producer* and marks the stream dead; it cannot
    interrupt a decoder already wedged inside ``push`` -- that daemon thread may
    be abandoned -- but submission and :meth:`result` remain bounded so the
    capture continues.
    """

    def __init__(
        self,
        factory: Callable[[], Any],
        *,
        max_queue: int = DEFAULT_MAX_QUEUE,
        poll_seconds: float = _POLL_SECONDS,
    ) -> None:
        if max_queue <= 0:
            raise ValueError("max_queue must be positive")
        self._factory = factory
        self._poll_seconds = poll_seconds
        self._queue: "queue.Queue[Any]" = queue.Queue(maxsize=max_queue)
        self._stop = threading.Event()
        self._disabled = False
        self._failed = False
        self._error: Optional[str] = None
        self._result: Any = _UNSET
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None

    def _ensure_started(self) -> None:
        with self._lock:
            if self._thread is not None or self._disabled or self._failed:
                return
            thread = threading.Thread(
                target=self._run,
                name="coolscanpy-streaming-sidecar",
                daemon=True,
            )
            self._thread = thread
            thread.start()

    def _run(self) -> None:
        try:
            decoder = self._factory()
            while not self._stop.is_set():
                try:
                    item = self._queue.get(timeout=self._poll_seconds)
                except queue.Empty:
                    continue
                if item is _SENTINEL:
                    self._result = decoder.finish()
                    return
                decoder.push(item)
        except Exception as error:  # noqa: BLE001 - fail-open: never reach the producer
            with self._lock:
                self._failed = True
                self._error = f"{type(error).__name__}: {error}"

    def submit(self, chunk: bytes | bytearray | memoryview) -> bool:
        """Nonblocking submission; ``False`` means streaming is disabled."""

        with self._lock:
            if self._disabled or self._failed:
                return False
        try:
            # Freeze mutable/foreign buffers so post-submit caller mutation cannot
            # change the evidence the decoder consumes; bytes are immutable & cheap.
            item: bytes = chunk if isinstance(chunk, bytes) else bytes(chunk)
            self._ensure_started()
            self._queue.put_nowait(item)
            return True
        except queue.Full:
            self.disable("queue-full")
            return False
        except Exception as error:  # noqa: BLE001 - never let submission raise
            self.disable(f"{type(error).__name__}: {error}")
            return False

    def seal(self, timeout: float) -> bool:
        """Signal end-of-stream; bounded by ``timeout`` (off the hot path)."""

        with self._lock:
            if self._disabled or self._failed:
                return False
        self._ensure_started()
        try:
            self._queue.put(_SENTINEL, timeout=max(0.0, timeout))
            return True
        except queue.Full:
            self.disable("queue-full-at-seal")
            return False
        except Exception as error:  # noqa: BLE001
            self.disable(f"{type(error).__name__}: {error}")
            return False

    def result(self, timeout: float) -> Any:
        """Wait up to ``timeout`` for the decoder's finish result, else ``None``."""

        thread = self._thread
        if thread is not None:
            thread.join(max(0.0, timeout))
        with self._lock:
            if self._disabled or self._failed or self._result is _UNSET:
                return None
            return self._result

    def disable(self, reason: str = "disabled") -> None:
        """Permanently mark the stream dead and unblock the producer.

        A consumer thread wedged inside ``push`` cannot be interrupted and may
        be abandoned (it is a daemon); submission and result remain bounded.
        """

        with self._lock:
            self._disabled = True
            if self._error is None:
                self._error = reason
        self._stop.set()

    def thread_is_alive(self) -> bool:
        """True while the decoder thread may still be running (e.g. inside push)."""

        thread = self._thread
        return thread is not None and thread.is_alive()

    def join(self, timeout: Optional[float] = None) -> None:
        """Join the decoder thread; ``None`` waits until it terminates."""

        thread = self._thread
        if thread is not None:
            thread.join(timeout)

    @property
    def disabled(self) -> bool:
        return self._disabled

    @property
    def failed(self) -> bool:
        return self._failed

    @property
    def error(self) -> Optional[str]:
        return self._error


def _sha256_file(path: Path, *, chunk_bytes: int = 8 * 1024 * 1024) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while block := handle.read(chunk_bytes):
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def _fsync_file(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _publish_exclusive(temp: Path, destination: Path) -> None:
    """Hard-link ``temp`` to ``destination`` refusing any existing target.

    The caller removes ``temp`` only after recording ownership of the linked
    destination. That ordering prevents a temp-unlink failure from leaving an
    untracked published artifact.
    """

    os.link(temp, destination)


class FineStreamSession:
    """Streaming decode that persists a bound RGBI artifact for one capture.

    Submit each fine-read payload as it is durably written; call :meth:`finish`
    once the raw stream is complete and its SHA-256 is known.  The decoded frame
    is streamed directly into a private ``.npy`` memmap; on a complete,
    exact-length, padding-valid finish carrying the canonical decode proof, the
    data artifact and a strict receipt are durably published (fsynced, never
    overwritten -- a collision is a refusal, receipt last) bound to the raw
    SHA-256 and byte count.  Any failure cleanly abandons and removes only this
    session's scratch, leaving no committed image.  Every method is fail-open.
    """

    def __init__(
        self,
        output_path: Path | str,
        *,
        height: int = HEIGHT,
        width: int = WIDTH,
        max_queue: int = DEFAULT_MAX_QUEUE,
        finish_timeout_seconds: float = DEFAULT_FINISH_TIMEOUT_SECONDS,
        enabled: bool = True,
    ) -> None:
        if not (
            isinstance(finish_timeout_seconds, (int, float))
            and not isinstance(finish_timeout_seconds, bool)
            and math.isfinite(finish_timeout_seconds)
            and finish_timeout_seconds >= 0
        ):
            raise ValueError("finish_timeout_seconds must be a finite nonnegative number")
        self._output_path = Path(output_path)
        self._data_path = self._output_path.with_name(
            self._output_path.name + STREAM_DATA_SUFFIX
        )
        self._receipt_path = self._output_path.with_name(
            self._output_path.name + STREAM_RECEIPT_SUFFIX
        )
        self._height = height
        self._width = width
        self._channels = CHANNELS
        self._records = (height + 1) // 2
        self._expected_bytes = self._records * FULL_RECORD_BYTES
        self._finish_timeout = finish_timeout_seconds
        self._active = enabled
        self._memmap: Optional[np.memmap] = None
        self._temp_data_path: Optional[Path] = None
        self._published_data = False
        self._published_receipt = False
        self._terminal_result: Optional[dict[str, object]] = None
        self._cleanup_deferred = False
        self._consumer: Optional[FailOpenStreamConsumer] = None
        if enabled:
            self._consumer = FailOpenStreamConsumer(
                self._factory, max_queue=max_queue
            )

    # -- lifecycle -------------------------------------------------------

    def _factory(self) -> StreamingFrameDecoder:
        # Runs once, on the consumer thread, at first submission.  Allocating
        # the memmap here (not at construction) means a session that is built
        # but never fed -- or is disabled -- allocates nothing.
        self._output_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self._data_path.name}.", suffix=".tmp", dir=self._output_path.parent
        )
        os.close(descriptor)
        temp_path = Path(temporary_name)
        try:
            memmap = np.lib.format.open_memmap(
                str(temp_path),
                mode="w+",
                dtype=np.uint16,
                shape=(self._height, self._width, self._channels),
            )
        except BaseException:
            temp_path.unlink(missing_ok=True)
            raise
        self._temp_data_path = temp_path
        self._memmap = memmap
        return StreamingFrameDecoder(height=self._height, width=self._width, out=memmap)

    @property
    def data_path(self) -> Path:
        return self._data_path

    @property
    def receipt_path(self) -> Path:
        return self._receipt_path

    @property
    def active(self) -> bool:
        return (
            self._active
            and self._consumer is not None
            and not self._consumer.disabled
        )

    @property
    def failed(self) -> bool:
        return self._consumer is not None and self._consumer.failed

    def submit(self, payload: bytes | bytearray | memoryview) -> None:
        """Feed one fine-read payload; never raises, disables on any problem."""

        consumer = self._consumer
        if consumer is None or not self._active or self._terminal_result is not None:
            return
        try:
            if not consumer.submit(payload):
                self._active = False
        except Exception:  # noqa: BLE001 - submission must never abort a scan
            self._active = False
            consumer.disable("submit-exception")

    # -- abandonment / cleanup -------------------------------------------

    def _close_memmap(self, *, strict: bool = False) -> None:
        memmap = self._memmap
        self._memmap = None
        if memmap is None:
            return
        failure: Exception | None = None
        try:
            memmap.flush()
        except Exception as error:  # noqa: BLE001
            failure = error
        underlying = getattr(memmap, "_mmap", None)
        if underlying is not None:
            try:
                underlying.close()
            except Exception as error:  # noqa: BLE001
                failure = failure or error
        if strict and failure is not None:
            raise failure

    def _cleanup_scratch(self) -> bool:
        """Remove only scratch THIS session created, marker-first, then fsync.

        Removes this session's published receipt (the commit marker) before its
        published data before any temp; never a pre-existing file it did not
        create.  Durable deletions are followed by a parent-directory fsync.
        """

        removed = False
        complete = True
        if self._published_receipt:
            try:
                self._receipt_path.unlink(missing_ok=True)
                removed = True
            except OSError:
                complete = False
            else:
                self._published_receipt = False
        if self._published_data:
            try:
                self._data_path.unlink(missing_ok=True)
                removed = True
            except OSError:
                complete = False
            else:
                self._published_data = False
        if self._temp_data_path is not None:
            try:
                self._temp_data_path.unlink(missing_ok=True)
                removed = True
            except OSError:
                complete = False
            else:
                self._temp_data_path = None
        if removed:
            try:
                _fsync_directory(self._output_path.parent)
            except OSError:
                complete = False
        return complete

    def _defer_cleanup(self) -> None:
        """Defer mapping/temp cleanup until the decoder thread has terminated.

        Called when the finish deadline expired while the consumer may still be
        inside ``push`` writing to the memmap.  We must not unmap, flush, or
        unlink now.  Ownership of the mapping/temp moves to a janitor that waits
        for the thread to die; if it never does, the clearly private temp leaks
        for the process lifetime rather than risk a crash.
        """

        if self._cleanup_deferred:
            return
        self._cleanup_deferred = True
        consumer = self._consumer

        def _janitor() -> None:
            if consumer is not None:
                consumer.join()  # block until the decoder thread actually ends
            # Read the resources only after join: the factory may still have
            # been creating/assigning them when the finish deadline expired.
            self._close_memmap()
            self._cleanup_scratch()

        threading.Thread(
            target=_janitor, name="coolscanpy-stream-cleanup", daemon=True
        ).start()

    def abort(self, reason: str = "capture-aborted") -> dict[str, object]:
        """Idempotently abandon this session and remove only owned artifacts.

        This is safe during an active decoder write: cleanup is deferred until
        its thread terminates. It also retracts an already-published sidecar if
        capture fails before the worker can journal the successful outcome.
        """

        if (
            self._terminal_result is not None
            and self._terminal_result.get("status") != "ok"
        ):
            return dict(self._terminal_result)
        consumer = self._consumer
        if consumer is not None:
            consumer.disable(reason)
        if consumer is not None and consumer.thread_is_alive():
            self._defer_cleanup()
        else:
            self._close_memmap()
            self._cleanup_scratch()
        result: dict[str, object] = {
            "status": "abandoned",
            "receipt": None,
            "reason": reason,
        }
        self._active = False
        self._terminal_result = result
        return dict(result)

    def _abandon(self, reason: str) -> dict[str, object]:
        """Disable promptly; never touch a live mapping; clean up only when safe."""

        consumer = self._consumer
        error = reason
        if consumer is not None:
            consumer.disable(reason)
            error = consumer.error or reason
        if consumer is not None and consumer.thread_is_alive():
            self._defer_cleanup()
        else:
            self._close_memmap()
            self._cleanup_scratch()
        return {"status": "abandoned", "receipt": None, "reason": error}

    # -- publication -------------------------------------------------------

    def _publish_receipt(self, payload: dict[str, object]) -> None:
        """Atomically publish the receipt, tracking ownership after the link."""

        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self._receipt_path.name}.", suffix=".tmp", dir=self._receipt_path.parent
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            _publish_exclusive(temporary, self._receipt_path)
            # Ownership is tracked only after the link succeeds, so a later
            # directory-fsync failure still lets cleanup remove OUR receipt.
            self._published_receipt = True
            temporary.unlink()
            _fsync_directory(self._receipt_path.parent)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    def finish(self, *, raw_sha256: str, raw_bytes: int) -> dict[str, object]:
        """Seal once and return a cached terminal outcome on repeat calls."""

        if self._terminal_result is not None:
            return dict(self._terminal_result)
        result = self._finish_once(raw_sha256=raw_sha256, raw_bytes=raw_bytes)
        self._active = False
        self._terminal_result = dict(result)
        return dict(result)

    def _finish_once(self, *, raw_sha256: str, raw_bytes: int) -> dict[str, object]:
        """Seal, decode, and publish the bound artifact; fail-open throughout."""

        consumer = self._consumer
        if consumer is None:
            return {"status": "disabled", "receipt": None}
        # Validate the raw binding up front: no publication on a malformed or
        # mismatched raw identity (HIGH B).  These never invent evidence.
        if not _is_lower_hex64(raw_sha256):
            return self._abandon("raw-sha-invalid")
        if type(raw_bytes) is not int:
            return self._abandon("raw-bytes-invalid")
        raw_bytes_int = raw_bytes
        if raw_bytes_int != self._expected_bytes:
            return self._abandon("raw-bytes-mismatch")

        deadline = time.monotonic() + self._finish_timeout
        try:
            if not self._active or consumer.disabled or consumer.failed:
                return self._abandon(consumer.error or "disabled-before-finish")
            consumer.seal(timeout=max(0.0, deadline - time.monotonic()))
            result = consumer.result(timeout=max(0.0, deadline - time.monotonic()))
            if result is None or consumer.failed:
                return self._abandon(consumer.error or "no-complete-result")
            # A result means the thread set it and returned; make certain it has
            # truly terminated before we touch the mapping it wrote into.
            if consumer.thread_is_alive():
                consumer.join(timeout=max(0.0, deadline - time.monotonic()))
            if consumer.thread_is_alive():
                return self._abandon("consumer-still-alive")

            rgbi, layout = result
            # HIGH B: refuse to publish unless the decode proof is exactly
            # canonical, and the frame shape/dtype is exactly as claimed.
            if not _proof_is_canonical(layout, self._records):
                return self._abandon("invalid-decode-proof")
            rgbi = np.asarray(rgbi)
            expected_shape = (self._height, self._width, self._channels)
            if rgbi.shape != expected_shape or rgbi.dtype != np.uint16:
                return self._abandon("bad-shape")

            # The thread has terminated: safe to finalize the mapping and publish.
            self._close_memmap(strict=True)
            temp = self._temp_data_path
            if temp is None or not temp.is_file():
                self._cleanup_scratch()
                return {"status": "abandoned", "receipt": None, "reason": "no-artifact"}
            _fsync_file(temp)
            derived_sha256, derived_bytes = _sha256_file(temp)

            receipt: dict[str, object] = {
                "kind": STREAM_RECEIPT_KIND,
                "version": STREAM_RECEIPT_VERSION,
                "status": STREAM_RECEIPT_STATUS,
                "derived_filename": self._data_path.name,
                "derived_sha256": derived_sha256,
                "derived_bytes": derived_bytes,
                "raw_sha256": raw_sha256,
                "raw_bytes": raw_bytes_int,
                "height": int(self._height),
                "width": int(self._width),
                "channels": int(self._channels),
                "dtype": "uint16",
                "layout": dict(layout),  # the exact validated proof; no defaults
            }

            # Publish data first (exclusive, no overwrite), then the receipt last
            # as the commit marker (also exclusive).  Collisions and post-link
            # failures are refusals, never a claimed success.
            try:
                _publish_exclusive(temp, self._data_path)
            except FileExistsError:
                temp.unlink(missing_ok=True)
                self._temp_data_path = None
                # The colliding data file is not ours; leave it in place.
                return {
                    "status": "abandoned",
                    "receipt": None,
                    "reason": "data-collision",
                }
            self._published_data = True
            temp.unlink()
            self._temp_data_path = None
            _fsync_directory(self._data_path.parent)
            try:
                self._publish_receipt(receipt)
            except FileExistsError:
                # A stale/pre-existing receipt cannot bless this artifact;
                # remove our (now orphaned) data, never the existing receipt.
                self._cleanup_scratch()
                return {
                    "status": "abandoned",
                    "receipt": None,
                    "reason": "receipt-collision",
                }
            except Exception:
                # Receipt link/fsync failed after the data was published: remove
                # our receipt (if linked) before our data; never a foreign file.
                self._cleanup_scratch()
                return {
                    "status": "abandoned",
                    "receipt": None,
                    "reason": "receipt-publish-failed",
                }
            _fsync_file(self._receipt_path)
            _fsync_directory(self._receipt_path.parent)
            receipt_sha256, receipt_bytes = _sha256_file(self._receipt_path)
            return {
                "status": "ok",
                "receipt": self._receipt_path.name,
                "receipt_sha256": receipt_sha256,
                "receipt_bytes": receipt_bytes,
                "derived_filename": self._data_path.name,
                "derived_sha256": derived_sha256,
                "derived_bytes": derived_bytes,
                "bound_raw_sha256": raw_sha256,
                "bound_raw_bytes": raw_bytes_int,
            }
        except Exception as error:  # noqa: BLE001 - finish must never abort a scan
            type_name = type(error).__name__
            if consumer is not None and consumer.thread_is_alive():
                return self._abandon(f"finish-exception:{type_name}")
            consumer.disable(f"finish-exception: {type_name}")
            self._close_memmap()
            self._cleanup_scratch()
            return {"status": "abandoned", "receipt": None, "reason": "finish-exception"}


__all__ = [
    "CANONICAL_DECODE_PROOF_KEYS",
    "CANONICAL_RGB_AVERAGE",
    "DEFAULT_FINISH_TIMEOUT_SECONDS",
    "DEFAULT_MAX_QUEUE",
    "FailOpenStreamConsumer",
    "FineStreamSession",
    "STREAM_DATA_SUFFIX",
    "STREAM_RECEIPT_KIND",
    "STREAM_RECEIPT_KEYS",
    "STREAM_RECEIPT_LAYOUT_KEYS",
    "STREAM_RECEIPT_STATUS",
    "STREAM_RECEIPT_SUFFIX",
    "STREAM_RECEIPT_VERSION",
]
