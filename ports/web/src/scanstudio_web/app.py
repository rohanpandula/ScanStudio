from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Callable
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field
from starlette.types import ASGIApp, Message, Receive, Scope, Send
from starlette.websockets import WebSocketDisconnect, WebSocketState

from .controller_lease import ControllerLease, LeaseRejected
from .engine_process import EngineRequestTimeout, EngineSupervisor, EngineUnavailable
from .relay import EventBroker, SubscriberClosed
from .security import AuthManager, AuthenticationError, OriginError
from .settings import ConfigurationError, Settings

CONTROL_LEASE_HEADER = "X-ScanStudio-Control-Lease"

READ_ONLY_METHODS = frozenset({"scanner.list", "scanner.status"})
MUTATING_METHODS = frozenset(
    {
        "scanner.connect",
        "sim.loadMedia",
        "scanner.acquireThumbnails",
        "scanner.disconnect",
    }
)
ALLOWED_METHODS = READ_ONLY_METHODS | MUTATING_METHODS
RESERVED_METHODS = frozenset({"engine.hello", "engine.shutdown"})


class LoginBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: str = Field(min_length=1, max_length=4_096)


class EngineRequestBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    method: str = Field(min_length=1, max_length=128)
    params: dict[str, Any] = Field(default_factory=dict)


class GatewayError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message

    def envelope(self) -> dict[str, Any]:
        return {
            "error": {
                "code": self.code,
                "message": self.message,
                "recoverable": False,
            }
        }


class RequestBodyLimitMiddleware:
    """Bound request bodies even when Content-Length is absent or dishonest."""

    def __init__(self, app: ASGIApp, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("method") not in {
            "POST",
            "PUT",
            "PATCH",
        }:
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))
        raw_length = headers.get(b"content-length")
        if raw_length is not None:
            try:
                if int(raw_length) > self.max_bytes:
                    await self._reject(scope, receive, send)
                    return
            except ValueError:
                await self._reject(scope, receive, send)
                return

        buffered: list[Message] = []
        total = 0
        while True:
            message = await receive()
            buffered.append(message)
            if message["type"] == "http.disconnect":
                return
            if message["type"] != "http.request":
                continue
            total += len(message.get("body", b""))
            if total > self.max_bytes:
                await self._reject(scope, receive, send)
                return
            if not message.get("more_body", False):
                break

        async def replay() -> Message:
            if buffered:
                return buffered.pop(0)
            return {"type": "http.request", "body": b"", "more_body": False}

        await self.app(scope, replay, send)

    @staticmethod
    async def _reject(scope: Scope, receive: Receive, send: Send) -> None:
        response = JSONResponse(
            status_code=413,
            content={
                "error": {
                    "code": "REQUEST_TOO_LARGE",
                    "message": "request body exceeds the configured limit",
                    "recoverable": False,
                }
            },
        )
        await response(scope, receive, send)


def create_app(
    settings: Settings | None = None,
    *,
    on_engine_fatal: Callable[[str], None] | None = None,
) -> FastAPI:
    resolved = settings or Settings.from_env()
    static_dir = _usable_static_dir(resolved.static_dir)
    events = EventBroker(resolved.event_queue_size)
    engine = EngineSupervisor(resolved, events, on_fatal=on_engine_fatal)
    auth = AuthManager(resolved)
    lease = ControllerLease(resolved.lease_ttl_seconds)

    def static_assets_ready() -> bool:
        if resolved.static_dir is None:
            return True
        return static_dir is not None and _usable_static_dir(static_dir) == static_dir

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if not static_assets_ready():
            raise ConfigurationError(
                "SCANSTUDIO_WEB_STATIC_DIR must name a directory containing "
                "index.html"
            )
        await engine.start()
        try:
            yield
        finally:
            await engine.close()

    app = FastAPI(
        title="ScanStudio Web Gateway",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.state.settings = resolved
    app.state.engine = engine
    app.state.auth = auth
    app.state.lease = lease
    app.state.events = events
    app.add_middleware(
        RequestBodyLimitMiddleware, max_bytes=resolved.max_request_body_bytes
    )

    @app.exception_handler(GatewayError)
    async def gateway_error_handler(_: Request, exc: GatewayError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.envelope())

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        _: Request, exc: RequestValidationError
    ) -> JSONResponse:
        # Keep user input out of the response: validation diagnostics can echo
        # secrets such as a malformed login token.
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "INVALID_REQUEST",
                    "message": "request body does not match the API contract",
                    "recoverable": False,
                    "fields": [
                        {"location": list(error["loc"]), "type": error["type"]}
                        for error in exc.errors()
                    ],
                }
            },
        )

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = (
            "camera=(), microphone=(), geolocation=()"
        )
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; "
            "object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob:; connect-src 'self' ws: wss:"
        )
        if request.url.path.startswith("/api/") or request.url.path.endswith("z"):
            response.headers["Cache-Control"] = "no-store"
        return response

    async def require_origin(request: Request) -> None:
        try:
            auth.require_origin(request.headers.get("origin"))
        except OriginError as exc:
            raise GatewayError(403, "ORIGIN_FORBIDDEN", str(exc)) from exc

    async def require_authenticated(request: Request) -> None:
        if not await auth.authenticated(request.cookies.get(resolved.cookie_name)):
            raise GatewayError(401, "AUTH_REQUIRED", "authentication is required")

    async def protect_post(request: Request) -> None:
        await require_origin(request)
        await require_authenticated(request)

    def control_token(request: Request) -> str | None:
        value = request.headers.get(CONTROL_LEASE_HEADER)
        if value is None or not value.strip() or len(value) > 256:
            return None
        try:
            value.encode("ascii")
        except UnicodeEncodeError:
            return None
        return value

    @app.get("/healthz")
    async def healthz() -> JSONResponse:
        snapshot = engine.health()
        healthy = snapshot["ready"] is True and static_assets_ready()
        return JSONResponse(
            status_code=200 if healthy else 503,
            content={"status": "ok" if healthy else "unhealthy", "engine": snapshot},
        )

    @app.get("/startupz")
    async def startupz() -> JSONResponse:
        snapshot = engine.health()
        ready = snapshot["ready"] is True and static_assets_ready()
        return JSONResponse(
            status_code=200 if ready else 503,
            content={"started": ready, "engine": snapshot},
        )

    @app.get("/api/v1/session")
    async def session(request: Request) -> JSONResponse:
        authenticated = await auth.authenticated(
            request.cookies.get(resolved.cookie_name)
        )
        control = (
            await lease.state(control_token(request)) if authenticated else "available"
        )
        return JSONResponse(
            content={"authenticated": authenticated, "control": control}
        )

    @app.post("/api/v1/session/login")
    async def login(request: Request, body: LoginBody) -> JSONResponse:
        await require_origin(request)
        try:
            session_id = await auth.login(
                body.token, request.cookies.get(resolved.cookie_name)
            )
        except AuthenticationError as exc:
            raise GatewayError(401, "INVALID_TOKEN", "invalid access token") from exc
        response = JSONResponse(
            content={"authenticated": True, "control": await lease.state()}
        )
        if session_id is not None:
            response.set_cookie(
                key=resolved.cookie_name,
                value=session_id,
                max_age=resolved.session_ttl_seconds,
                httponly=True,
                secure=resolved.cookie_secure,
                samesite="strict",
                path="/",
            )
        return response

    @app.post("/api/v1/control/claim")
    async def claim_control(request: Request) -> JSONResponse:
        await protect_post(request)
        try:
            grant = await lease.claim(control_token(request))
        except LeaseRejected as exc:
            raise GatewayError(409, "CONTROL_ALREADY_OWNED", str(exc)) from exc
        return JSONResponse(
            content={
                "leaseToken": grant.token,
                "expiresInSeconds": grant.expires_in_seconds,
            }
        )

    @app.post("/api/v1/control/heartbeat")
    async def heartbeat_control(request: Request) -> JSONResponse:
        await protect_post(request)
        try:
            grant = await lease.heartbeat(control_token(request))
        except LeaseRejected as exc:
            raise GatewayError(423, "CONTROL_LEASE_REQUIRED", str(exc)) from exc
        return JSONResponse(content={"expiresInSeconds": grant.expires_in_seconds})

    @app.post("/api/v1/control/release")
    async def release_control(request: Request) -> JSONResponse:
        await protect_post(request)
        try:
            await lease.release(control_token(request))
        except LeaseRejected as exc:
            raise GatewayError(423, "CONTROL_LEASE_REQUIRED", str(exc)) from exc
        return JSONResponse(content={"released": True})

    @app.post("/api/v1/engine/request")
    async def engine_request(request: Request, body: EngineRequestBody) -> JSONResponse:
        await protect_post(request)
        if body.method in RESERVED_METHODS:
            raise GatewayError(
                403,
                "RESERVED_ENGINE_METHOD",
                f"'{body.method}' is owned by the gateway",
            )
        if body.method not in ALLOWED_METHODS:
            raise GatewayError(
                403,
                "METHOD_NOT_ALLOWED",
                f"'{body.method}' is not available in the simulator-only web slice",
            )
        if (
            body.method == "scanner.connect"
            and body.params.get("deviceId") != "sim-ls5000-0"
        ):
            raise GatewayError(
                400,
                "SIMULATOR_DEVICE_REQUIRED",
                "scanner.connect is restricted to deviceId 'sim-ls5000-0'",
            )
        try:
            # Reject Python's permissive NaN/Infinity extension before it can
            # become non-standard JSON on the NDJSON wire.
            json.dumps(body.params, allow_nan=False)
            if body.method in MUTATING_METHODS:
                pending = await lease.submit_if_owned(
                    control_token(request),
                    lambda: engine.submit(body.method, body.params),
                )
                envelope = await pending.result()
            else:
                envelope = await engine.request(body.method, body.params)
        except LeaseRejected as exc:
            raise GatewayError(423, "CONTROL_LEASE_REQUIRED", str(exc)) from exc
        except (TypeError, ValueError) as exc:
            raise GatewayError(
                400, "INVALID_PARAMS", "params must contain finite JSON values"
            ) from exc
        except EngineRequestTimeout as exc:
            raise GatewayError(504, "ENGINE_TIMEOUT", str(exc)) from exc
        except EngineUnavailable as exc:
            raise GatewayError(503, "ENGINE_UNAVAILABLE", str(exc)) from exc
        # Engine result and error payloads pass through byte-for-structure,
        # including code/message/recoverable and forward-compatible fields.
        return JSONResponse(content=envelope)

    @app.websocket("/api/v1/engine/events")
    async def engine_events(websocket: WebSocket) -> None:
        try:
            auth.require_origin(websocket.headers.get("origin"))
        except OriginError:
            await websocket.close(code=4403, reason="origin forbidden")
            return
        session_id = websocket.cookies.get(resolved.cookie_name)
        if not await auth.authenticated(session_id, refresh=False):
            await websocket.close(code=4401, reason="authentication required")
            return

        subscriber = await events.subscribe()
        receive_task: asyncio.Task[Message] | None = None
        try:
            await websocket.accept()
            receive_task = asyncio.create_task(
                websocket.receive(), name="scanstudio-websocket-receive"
            )
            next_auth_check = time.monotonic() + 5.0
            while True:
                event_task = asyncio.create_task(subscriber.next_event())
                done, _ = await asyncio.wait(
                    {receive_task, event_task},
                    timeout=5.0,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                if not done:
                    event_task.cancel()
                    with suppress(asyncio.CancelledError):
                        await event_task
                    if not await auth.authenticated(session_id, refresh=False):
                        await websocket.close(code=4401, reason="session expired")
                        return
                    continue

                if receive_task in done:
                    event_task.cancel()
                    with suppress(asyncio.CancelledError):
                        await event_task
                    message = receive_task.result()
                    if message["type"] == "websocket.disconnect":
                        return
                    # This socket is intentionally server-to-browser only.
                    await websocket.close(code=1003, reason="messages are not accepted")
                    return

                assert event_task in done
                event = event_task.result()
                await websocket.send_json(event)
                if time.monotonic() >= next_auth_check:
                    if not await auth.authenticated(session_id, refresh=False):
                        await websocket.close(code=4401, reason="session expired")
                        return
                    next_auth_check = time.monotonic() + 5.0
        except SubscriberClosed:
            if websocket.application_state == WebSocketState.CONNECTED:
                await websocket.close(code=1013, reason="event consumer too slow")
        except (RuntimeError, OSError, WebSocketDisconnect):
            return
        finally:
            if receive_task is not None and not receive_task.done():
                receive_task.cancel()
                with suppress(asyncio.CancelledError):
                    await receive_task
            await events.unsubscribe(subscriber)

    if static_dir is not None:
        app.mount("/", StaticFiles(directory=static_dir, html=True), name="web-ui")

    return app


def _usable_static_dir(path: Path | None) -> Path | None:
    if path is None:
        return None
    resolved = path.resolve()
    if not resolved.is_dir() or not (resolved / "index.html").is_file():
        return None
    return resolved
