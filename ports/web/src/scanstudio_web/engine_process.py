from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Callable
from collections import deque
from contextlib import suppress
from dataclasses import dataclass
from typing import Any

from .relay import EventBroker
from .settings import Settings

logger = logging.getLogger(__name__)


class EngineUnavailable(RuntimeError):
    pass


class EngineProtocolError(EngineUnavailable):
    pass


class EngineRequestTimeout(EngineUnavailable):
    pass


@dataclass(slots=True)
class PendingEngineRequest:
    _supervisor: EngineSupervisor
    request_id: int
    method: str
    future: asyncio.Future[dict[str, Any]]
    timeout: float

    async def result(self) -> dict[str, Any]:
        return await self._supervisor._await_response(
            self.request_id,
            self.method,
            self.future,
            self.timeout,
        )


class EngineSupervisor:
    """Own exactly one ScanStudio engine child and its NDJSON connection."""

    def __init__(
        self,
        settings: Settings,
        events: EventBroker,
        *,
        on_fatal: Callable[[str], None] | None = None,
    ) -> None:
        self._settings = settings
        self._events = events
        self._on_fatal = on_fatal
        self._process: asyncio.subprocess.Process | None = None
        self._stdout_task: asyncio.Task[None] | None = None
        self._stderr_task: asyncio.Task[None] | None = None
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self._abandoned_ids: deque[int] = deque(maxlen=4_096)
        self._abandoned_set: set[int] = set()
        self._next_id = 1
        self._write_lock = asyncio.Lock()
        self._lifecycle_lock = asyncio.Lock()
        self._ever_started = False
        self._ready = False
        self._closing = False
        self._hello_complete = False
        self._hello: dict[str, Any] | None = None
        self._fatal_error: str | None = None
        self._fatal_notified = False
        self._stderr_tail: deque[str] = deque(maxlen=100)

    @property
    def ready(self) -> bool:
        return (
            self._ready
            and not self._closing
            and self._process is not None
            and self._process.returncode is None
        )

    def health(self) -> dict[str, Any]:
        process = self._process
        running = process is not None and process.returncode is None
        return {
            "running": running,
            "ready": self.ready,
            "pid": process.pid if running else None,
            "simulatorOnly": True,
            "protocolVersion": self._hello.get("protocolVersion")
            if self._hello
            else None,
            "error": self._fatal_error,
        }

    async def start(self) -> None:
        async with self._lifecycle_lock:
            if self._ever_started:
                raise EngineUnavailable(
                    "the singleton engine supervisor was already started"
                )
            self._ever_started = True
            self._closing = False
            self._fatal_error = None

            environment = {
                name: value
                for name, value in os.environ.items()
                if not name.startswith("SCANSTUDIO_WEB_")
                and name not in {"SCANSTUDIO_BRIDGE_CMD", "SCANSTUDIO_HW_MOTION"}
            }
            # Simulator-only is an enforced child-process boundary, not a
            # convention. Inherited live-operation settings and gateway
            # secrets/configuration are never exposed to the Rust child.
            try:
                self._process = await asyncio.create_subprocess_exec(
                    *self._settings.engine_command,
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    env=environment,
                    limit=self._settings.max_engine_line_bytes + 1,
                )
            except (OSError, ValueError) as exc:
                self._fatal_error = f"could not start scanstudio-engine: {exc}"
                raise EngineUnavailable(self._fatal_error) from exc

            self._stdout_task = asyncio.create_task(
                self._read_stdout(), name="scanstudio-engine-stdout"
            )
            self._stderr_task = asyncio.create_task(
                self._read_stderr(), name="scanstudio-engine-stderr"
            )

            try:
                hello_envelope = await self._transact(
                    "engine.hello",
                    {"clientName": "scanstudio-web", "protocolVersion": 1},
                    timeout=self._settings.engine_startup_timeout_seconds,
                    allow_unready=True,
                )
                hello = self._require_result(hello_envelope, "engine.hello")
                self._validate_hello(hello)
                self._hello_complete = True

                devices_envelope = await self._transact(
                    "scanner.list",
                    {},
                    timeout=self._settings.engine_startup_timeout_seconds,
                    allow_unready=True,
                )
                devices = self._require_result(devices_envelope, "scanner.list")
                self._validate_simulator_only(devices)
                self._hello = hello
                self._ready = True
            except BaseException:
                await self._close_locked()
                raise

    async def request(
        self,
        method: str,
        params: dict[str, Any],
    ) -> dict[str, Any]:
        pending = await self.submit(method, params)
        return await pending.result()

    async def submit(
        self,
        method: str,
        params: dict[str, Any],
    ) -> PendingEngineRequest:
        if self._closing:
            raise EngineUnavailable("scanstudio-engine is shutting down")
        if not self.ready:
            raise EngineUnavailable(
                self._fatal_error or "scanstudio-engine is not ready"
            )
        request_id, future = await self._write_request(method, params)
        return PendingEngineRequest(
            _supervisor=self,
            request_id=request_id,
            method=method,
            future=future,
            timeout=self._settings.engine_request_timeout_seconds,
        )

    async def close(self) -> None:
        async with self._lifecycle_lock:
            await self._close_locked()

    async def _close_locked(self) -> None:
        if self._closing and self._process is None:
            return
        self._closing = True
        self._ready = False
        await self._events.close()

        process = self._process
        if process is not None and process.returncode is None and self._hello_complete:
            with suppress(EngineUnavailable, asyncio.TimeoutError, BrokenPipeError):
                await self._transact(
                    "engine.shutdown",
                    {},
                    timeout=self._settings.engine_shutdown_timeout_seconds,
                    allow_unready=True,
                    allow_closing=True,
                )

        if process is not None and process.stdin is not None:
            process.stdin.close()
            with suppress(BrokenPipeError, ConnectionResetError):
                await process.stdin.wait_closed()

        if process is not None and process.returncode is None:
            try:
                await asyncio.wait_for(
                    process.wait(),
                    timeout=self._settings.engine_shutdown_timeout_seconds,
                )
            except asyncio.TimeoutError:
                with suppress(ProcessLookupError):
                    process.terminate()
                try:
                    await asyncio.wait_for(
                        process.wait(),
                        timeout=self._settings.engine_shutdown_timeout_seconds,
                    )
                except asyncio.TimeoutError:
                    with suppress(ProcessLookupError):
                        process.kill()
                    await process.wait()

        self._fail_pending(EngineUnavailable("scanstudio-engine has stopped"))
        await self._finish_reader_task(self._stdout_task)
        await self._finish_reader_task(self._stderr_task)
        self._stdout_task = None
        self._stderr_task = None
        self._process = None

    async def _finish_reader_task(self, task: asyncio.Task[None] | None) -> None:
        if task is None or task is asyncio.current_task():
            return
        if not task.done():
            task.cancel()
        with suppress(asyncio.CancelledError, EngineUnavailable):
            await task

    async def _transact(
        self,
        method: str,
        params: dict[str, Any],
        *,
        timeout: float,
        allow_unready: bool,
        allow_closing: bool = False,
    ) -> dict[str, Any]:
        if not allow_closing and self._closing:
            raise EngineUnavailable("scanstudio-engine is shutting down")
        if not allow_unready and not self.ready:
            raise EngineUnavailable(
                self._fatal_error or "scanstudio-engine is not ready"
            )

        request_id, future = await self._write_request(method, params)
        return await self._await_response(request_id, method, future, timeout)

    async def _await_response(
        self,
        request_id: int,
        method: str,
        future: asyncio.Future[dict[str, Any]],
        timeout: float,
    ) -> dict[str, Any]:
        try:
            return await asyncio.wait_for(asyncio.shield(future), timeout=timeout)
        except asyncio.TimeoutError as exc:
            self._abandon(request_id)
            raise EngineRequestTimeout(f"engine request '{method}' timed out") from exc
        except asyncio.CancelledError:
            # Never retry a canceled HTTP request. The response may still
            # arrive, so retain a bounded tombstone for its gateway-owned id.
            self._abandon(request_id)
            raise

    async def _write_request(
        self, method: str, params: dict[str, Any]
    ) -> tuple[int, asyncio.Future[dict[str, Any]]]:
        process = self._process
        if process is None or process.returncode is not None or process.stdin is None:
            raise EngineUnavailable("scanstudio-engine is not running")

        async with self._write_lock:
            request_id = self._next_id
            self._next_id += 1
            wire = (
                json.dumps(
                    {"id": request_id, "method": method, "params": params},
                    separators=(",", ":"),
                    ensure_ascii=False,
                    allow_nan=False,
                ).encode("utf-8")
                + b"\n"
            )
            future: asyncio.Future[dict[str, Any]] = (
                asyncio.get_running_loop().create_future()
            )
            self._pending[request_id] = future
            try:
                process.stdin.write(wire)
                await asyncio.wait_for(
                    process.stdin.drain(),
                    timeout=self._settings.engine_write_timeout_seconds,
                )
            except asyncio.TimeoutError as exc:
                self._cancel_pending(request_id)
                message = (
                    "engine stdin remained blocked beyond the configured write timeout"
                )
                await self._mark_fatal(message)
                raise EngineUnavailable(message) from exc
            except asyncio.CancelledError:
                # The bytes may already be in the pipe. Retain issued-id history
                # so a later response is ignored instead of poisoning the engine.
                self._abandon(request_id)
                raise
            except (BrokenPipeError, ConnectionResetError) as exc:
                self._cancel_pending(request_id)
                await self._mark_fatal("engine stdin closed while writing a request")
                raise EngineUnavailable(self._fatal_error or str(exc)) from exc
            return request_id, future

    async def _read_stdout(self) -> None:
        process = self._process
        assert process is not None and process.stdout is not None
        try:
            while True:
                try:
                    line = await process.stdout.readline()
                except (ValueError, asyncio.LimitOverrunError) as exc:
                    raise EngineProtocolError(
                        "engine stdout line exceeded the configured limit"
                    ) from exc
                if not line:
                    if not self._closing:
                        raise EngineUnavailable(
                            "scanstudio-engine stdout closed unexpectedly"
                        )
                    return
                if len(line) > self._settings.max_engine_line_bytes:
                    raise EngineProtocolError(
                        "engine stdout line exceeded the configured limit"
                    )
                if not line.endswith(b"\n"):
                    raise EngineProtocolError(
                        "engine emitted a non-terminated NDJSON record"
                    )
                try:
                    message = json.loads(
                        line,
                        parse_constant=lambda value: (_ for _ in ()).throw(
                            ValueError(f"invalid JSON constant {value}")
                        ),
                    )
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                    raise EngineProtocolError("engine emitted malformed JSON") from exc
                if not isinstance(message, dict):
                    raise EngineProtocolError(
                        "engine emitted a non-object NDJSON record"
                    )
                await self._route_message(message)
        except asyncio.CancelledError:
            raise
        except EngineUnavailable as exc:
            await self._mark_fatal(str(exc), failure=exc)

    async def _read_stderr(self) -> None:
        process = self._process
        assert process is not None and process.stderr is not None
        try:
            while chunk := await process.stderr.read(8_192):
                # Chunked reads keep draining even if one diagnostic line is
                # enormous. Retain/log only bounded fragments.
                rendered = chunk.decode("utf-8", errors="replace")
                for fragment in rendered.splitlines():
                    if fragment:
                        bounded = fragment[:2_000]
                        self._stderr_tail.append(bounded)
                        logger.warning("scanstudio-engine stderr: %s", bounded)
        except asyncio.CancelledError:
            raise

    async def _route_message(self, message: dict[str, Any]) -> None:
        if "id" in message:
            request_id = message["id"]
            if (
                isinstance(request_id, bool)
                or not isinstance(request_id, int)
                or request_id < 0
            ):
                raise EngineProtocolError("engine response id is not an integer")
            has_result = "result" in message
            has_error = "error" in message
            if has_result == has_error:
                raise EngineProtocolError(
                    "engine response must contain exactly one of result or error"
                )
            future = self._pending.pop(request_id, None)
            if future is None:
                self._abandoned_set.discard(request_id)
                # IDs are allocated monotonically without gaps. A positive ID
                # below _next_id was issued by this supervisor, even if its
                # bounded abandonment tombstone has since been evicted or an
                # engine emitted a duplicate response. Late issued responses
                # are harmless; a never-issued ID still fails the protocol.
                if 1 <= request_id < self._next_id:
                    return
                raise EngineProtocolError(
                    f"engine returned unknown response id {request_id}"
                )
            if future.done():
                raise EngineProtocolError(
                    f"engine returned duplicate response id {request_id}"
                )
            # The public API never exposes the gateway-owned correlation id.
            future.set_result(
                {key: value for key, value in message.items() if key != "id"}
            )
            return

        if isinstance(message.get("event"), str) and isinstance(
            message.get("payload"), dict
        ):
            await self._events.publish(message)
            return
        raise EngineProtocolError("engine emitted an unknown NDJSON envelope")

    def _abandon(self, request_id: int) -> None:
        self._cancel_pending(request_id)
        if len(self._abandoned_ids) == self._abandoned_ids.maxlen:
            oldest = self._abandoned_ids[0]
            self._abandoned_set.discard(oldest)
        self._abandoned_ids.append(request_id)
        self._abandoned_set.add(request_id)

    def _cancel_pending(self, request_id: int) -> None:
        future = self._pending.pop(request_id, None)
        if future is not None and not future.done():
            future.cancel()

    async def _mark_fatal(
        self,
        message: str,
        *,
        failure: EngineUnavailable | None = None,
    ) -> None:
        if self._fatal_error is None:
            self._fatal_error = message
        self._ready = False
        await self._events.close()
        self._notify_fatal()
        self._fail_pending(failure or EngineUnavailable(message))
        process = self._process
        if process is not None and process.returncode is None and not self._closing:
            with suppress(ProcessLookupError):
                process.terminate()

    def _notify_fatal(self) -> None:
        if self._fatal_notified:
            return
        self._fatal_notified = True
        callback = self._on_fatal
        if callback is None:
            return
        try:
            callback(self._fatal_error or "scanstudio-engine stopped unexpectedly")
        except Exception:
            # Lifecycle cleanup and pending request failure must continue even
            # if an embedding host's notification hook is defective.
            logger.exception("scanstudio-engine fatal callback failed")

    def _fail_pending(self, error: EngineUnavailable) -> None:
        pending = tuple(self._pending.values())
        self._pending.clear()
        for future in pending:
            if not future.done():
                future.set_exception(error)

    @staticmethod
    def _require_result(envelope: dict[str, Any], method: str) -> dict[str, Any]:
        if "error" in envelope:
            raise EngineProtocolError(
                f"{method} failed during gateway startup: {envelope['error']!r}"
            )
        result = envelope.get("result")
        if not isinstance(result, dict):
            raise EngineProtocolError(f"{method} returned a non-object result")
        return result

    @staticmethod
    def _validate_hello(hello: dict[str, Any]) -> None:
        capabilities = hello.get("capabilities")
        if (
            hello.get("engineName") != "scanstudio-engine"
            or hello.get("protocolVersion") != 1
            or not isinstance(capabilities, list)
            or "simulated-ls5000" not in capabilities
        ):
            raise EngineProtocolError(
                "engine.hello did not satisfy protocol v1 simulator requirements"
            )

    @staticmethod
    def _validate_simulator_only(result: dict[str, Any]) -> None:
        devices = result.get("devices")
        if not isinstance(devices, list) or len(devices) != 1:
            raise EngineProtocolError(
                "simulator-only engine must expose exactly one device"
            )
        device = devices[0]
        if (
            not isinstance(device, dict)
            or device.get("deviceId") != "sim-ls5000-0"
            or device.get("kind") != "simulated"
        ):
            raise EngineProtocolError("engine exposed a non-simulator device")
