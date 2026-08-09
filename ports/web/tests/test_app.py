from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from conftest import ACCESS_TOKEN, ORIGIN, claim, login, post_engine
from scanstudio_web.app import create_app
from scanstudio_web.engine_process import EngineProtocolError
from scanstudio_web.settings import ConfigurationError, Settings


def read_requests(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_startup_health_first_hello_simulator_environment_and_shutdown(
    app_factory, monkeypatch
) -> None:
    monkeypatch.setenv("SCANSTUDIO_BRIDGE_CMD", "must-not-reach-child")
    monkeypatch.setenv("SCANSTUDIO_HW_MOTION", "1")
    monkeypatch.setenv("SCANSTUDIO_WEB_TOKEN", "must-not-reach-child")
    monkeypatch.setenv("SCANSTUDIO_WEB_ALLOWED_ORIGINS", "http://gateway-only.test")
    monkeypatch.setenv("SCANSTUDIO_ENGINE_TEST_SENTINEL", "preserve-for-engine")
    app, request_log, env_log = app_factory(token=None)

    with TestClient(app) as client:
        health = client.get("/healthz")
        assert health.status_code == 200
        assert (
            health.json()["engine"]
            | {
                "running": True,
                "ready": True,
                "simulatorOnly": True,
                "protocolVersion": 1,
            }
            == health.json()["engine"]
        )
        assert client.get("/startupz").json()["started"] is True

    requests = read_requests(request_log)
    assert [request["method"] for request in requests[:2]] == [
        "engine.hello",
        "scanner.list",
    ]
    assert requests[-1]["method"] == "engine.shutdown"
    assert json.loads(env_log.read_text(encoding="utf-8")) == {
        "bridge": None,
        "motion": None,
        "gatewayKeys": [],
        "engineSentinel": "preserve-for-engine",
    }


def test_explicit_static_dir_without_index_fails_startup(
    app_factory, tmp_path: Path
) -> None:
    static_dir = tmp_path / "incomplete-static"
    static_dir.mkdir()
    app, request_log, _ = app_factory(static_dir=static_dir)

    with pytest.raises(ConfigurationError, match="index.html"):
        with TestClient(app):
            pass

    # Configuration fails before the supervised engine can report ready.
    assert not request_log.exists()


def test_cookie_login_and_post_origin_checks(app_factory) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        assert client.get("/api/v1/session").json() == {
            "authenticated": False,
            "control": "available",
        }
        missing_origin = client.post(
            "/api/v1/session/login", json={"token": ACCESS_TOKEN}
        )
        assert missing_origin.status_code == 403
        wrong_token = login(client, "wrong")
        assert wrong_token.status_code == 401

        response = login(client)
        assert response.status_code == 200
        cookie = response.headers["set-cookie"].lower()
        assert "httponly" in cookie
        assert "samesite=strict" in cookie
        assert "path=/" in cookie
        session = client.get("/api/v1/session")
        assert session.json()["authenticated"] is True

        wrong_origin = client.post(
            "/api/v1/control/claim", headers={"Origin": "http://evil.test"}
        )
        assert wrong_origin.status_code == 403
        assert wrong_origin.json()["error"]["code"] == "ORIGIN_FORBIDDEN"
        wrong_port = client.post(
            "/api/v1/control/claim", headers={"Origin": "http://testserver:8080"}
        )
        assert wrong_port.status_code == 403


def test_lease_exact_allowlist_and_simulator_connect_gate(app_factory) -> None:
    app, request_log, _ = app_factory()
    with TestClient(app) as client:
        assert login(client).status_code == 200

        # Observer-safe reads do not claim or renew control.
        listed = post_engine(client, "scanner.list")
        assert listed.status_code == 200
        assert listed.json()["result"]["devices"][0]["deviceId"] == "sim-ls5000-0"

        no_lease = post_engine(client, "scanner.connect", {"deviceId": "sim-ls5000-0"})
        assert no_lease.status_code == 423

        lease = claim(client)
        second_claim = client.post("/api/v1/control/claim", headers={"Origin": ORIGIN})
        assert second_claim.status_code == 409

        for method in ("engine.hello", "engine.shutdown"):
            response = post_engine(client, method, lease=lease)
            assert response.status_code == 403
            assert response.json()["error"]["code"] == "RESERVED_ENGINE_METHOD"
        for method in ("scanner.eject", "scan.start", " scanner.list", "Scanner.list"):
            response = post_engine(client, method, lease=lease)
            assert response.status_code == 403
            assert response.json()["error"]["code"] == "METHOD_NOT_ALLOWED"

        real = post_engine(
            client,
            "scanner.connect",
            {"deviceId": "nikon-ls5000-real-0"},
            lease,
        )
        assert real.status_code == 400
        connected = post_engine(
            client,
            "scanner.connect",
            {"deviceId": "sim-ls5000-0", "options": {"timeScale": 0.01}},
            lease,
        )
        assert connected.status_code == 200
        loaded = post_engine(client, "sim.loadMedia", {"carrier": "strip6"}, lease)
        assert loaded.status_code == 200
        thumbnails = post_engine(
            client,
            "scanner.acquireThumbnails",
            {"frames": [1], "operationId": "web-test-preview"},
            lease,
        )
        assert thumbnails.json()["result"] == {"accepted": True, "frames": [1]}
        disconnected = post_engine(client, "scanner.disconnect", lease=lease)
        assert disconnected.status_code == 200

        heartbeat = client.post(
            "/api/v1/control/heartbeat",
            headers={"Origin": ORIGIN, "X-ScanStudio-Control-Lease": lease},
        )
        assert heartbeat.status_code == 200
        owned = client.get(
            "/api/v1/session", headers={"X-ScanStudio-Control-Lease": lease}
        )
        assert owned.json()["control"] == "owned"
        assert client.get("/api/v1/session").json()["control"] == "observer"

        released = client.post(
            "/api/v1/control/release",
            headers={"Origin": ORIGIN, "X-ScanStudio-Control-Lease": lease},
        )
        assert released.status_code == 200
        replacement = claim(client)
        assert replacement != lease
        stale_release = client.post(
            "/api/v1/control/release",
            headers={"Origin": ORIGIN, "X-ScanStudio-Control-Lease": lease},
        )
        assert stale_release.status_code == 423

    forwarded = [request["method"] for request in read_requests(request_log)]
    assert "scanner.eject" not in forwarded
    assert "scan.start" not in forwarded
    assert forwarded.count("engine.hello") == 1
    assert forwarded.count("engine.shutdown") == 1


def test_engine_error_payload_is_preserved(app_factory) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        assert login(client).status_code == 200
        response = post_engine(client, "scanner.status")
        assert response.status_code == 200
        assert response.json() == {
            "error": {
                "code": "NOT_CONNECTED",
                "message": "scanner is not connected",
                "recoverable": False,
                "fakeDetail": "preserve-me",
            }
        }


def test_authenticated_observer_websocket_receives_events(app_factory) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        assert login(client).status_code == 200
        lease = claim(client)
        with client.websocket_connect(
            "/api/v1/engine/events", headers={"Origin": ORIGIN}
        ) as websocket:
            response = post_engine(
                client,
                "scanner.connect",
                {"deviceId": "sim-ls5000-0"},
                lease,
            )
            assert response.status_code == 200
            assert websocket.receive_json()["event"] == "scanner.status"


@pytest.mark.asyncio
async def test_websocket_accept_failure_unsubscribes_observer() -> None:
    app = create_app(Settings(allowed_origins=(ORIGIN,)))
    events = app.state.events
    subscribed: list[Any] = []
    unsubscribed: list[Any] = []
    original_subscribe = events.subscribe
    original_unsubscribe = events.unsubscribe

    async def record_subscribe():
        subscriber = await original_subscribe()
        subscribed.append(subscriber)
        return subscriber

    async def record_unsubscribe(subscriber):
        unsubscribed.append(subscriber)
        await original_unsubscribe(subscriber)

    events.subscribe = record_subscribe
    events.unsubscribe = record_unsubscribe

    class AcceptFailure:
        headers = {"origin": ORIGIN}
        cookies: dict[str, str] = {}

        async def accept(self) -> None:
            raise OSError("client disconnected during accept")

    endpoint = next(
        route.endpoint
        for route in app.routes
        if getattr(route, "path", None) == "/api/v1/engine/events"
    )
    await endpoint(AcceptFailure())

    assert len(subscribed) == 1
    assert unsubscribed == subscribed


@pytest.mark.parametrize(
    ("origin", "login_first", "expected_code"),
    [
        (ORIGIN, False, 4401),
        ("http://evil.test", True, 4403),
        (None, True, 4403),
    ],
)
def test_websocket_rejects_missing_auth_or_wrong_origin(
    app_factory, origin, login_first, expected_code
) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        if login_first:
            assert login(client).status_code == 200
        headers = {} if origin is None else {"Origin": origin}
        with pytest.raises(WebSocketDisconnect) as caught:
            with client.websocket_connect(
                "/api/v1/engine/events", headers=headers
            ) as websocket:
                websocket.receive_json()
        assert caught.value.code == expected_code


@pytest.mark.parametrize("mode", ["bad-hello", "real-device"])
def test_startup_fails_closed_on_incompatible_or_real_engine(app_factory, mode) -> None:
    app, _, _ = app_factory(mode=mode)
    with pytest.raises(EngineProtocolError):
        with TestClient(app):
            pass


def test_request_body_limit_is_an_engine_error_envelope(app_factory) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        response = client.post(
            "/api/v1/session/login",
            headers={"Origin": ORIGIN, "Content-Length": "99999999"},
            content=b"{}",
        )
        assert response.status_code == 413
        assert response.json()["error"]["code"] == "REQUEST_TOO_LARGE"


def test_non_finite_json_never_reaches_engine(app_factory) -> None:
    app, request_log, _ = app_factory()
    with TestClient(app) as client:
        assert login(client).status_code == 200
        response = client.post(
            "/api/v1/engine/request",
            headers={"Origin": ORIGIN, "Content-Type": "application/json"},
            content=b'{"method":"scanner.status","params":{"value":NaN}}',
        )
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "INVALID_PARAMS"
    requests = read_requests(request_log)
    assert not any(
        request["method"] == "scanner.status" and "value" in request["params"]
        for request in requests
    )
