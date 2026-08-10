from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from starlette.websockets import WebSocketDisconnect

from conftest import ACCESS_TOKEN, ORIGIN, claim, login, post_engine
from scanstudio_web.app import EngineRequestBody, create_app
from scanstudio_web.engine_process import EngineProtocolError
from scanstudio_web.settings import AuthMode, ConfigurationError, Settings


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
    app, request_log, env_log = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )

    with TestClient(app) as client:
        health = client.get("/healthz")
        assert health.status_code == 200
        assert health.json() == {"status": "ok"}
        assert client.get("/startupz").json() == {"started": True}

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


def test_explicit_static_dir_requires_web_marker_and_serves_marked_bundle(
    app_factory, tmp_path: Path
) -> None:
    static_dir = tmp_path / "static"
    static_dir.mkdir()
    (static_dir / "index.html").write_text("<h1>ScanStudio</h1>", encoding="utf-8")

    unmarked_app, unmarked_log, _ = app_factory(static_dir=static_dir)
    with pytest.raises(ConfigurationError, match="scanstudio-web-runtime.json"):
        with TestClient(unmarked_app):
            pass
    assert not unmarked_log.exists()

    (static_dir / "scanstudio-web-runtime.json").write_text(
        '{"schemaVersion":1,"runtime":"simulator-only-web"}\n',
        encoding="utf-8",
    )
    marked_app, _, _ = app_factory(static_dir=static_dir)
    with TestClient(marked_app) as client:
        response = client.get("/")
        assert response.status_code == 200
        assert "ScanStudio" in response.text


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


def test_request_models_reject_unknown_fields_under_pydantic_v1(app_factory) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        login_extra = client.post(
            "/api/v1/session/login",
            headers={"Origin": ORIGIN},
            json={"token": ACCESS_TOKEN, "evil": True},
        )
        assert login_extra.status_code == 422
        assert login(client).status_code == 200

        claim_extra = client.post(
            "/api/v1/control/claim",
            headers={"Origin": ORIGIN},
            json={"evil": True},
        )
        assert claim_extra.status_code == 422

        engine_extra = client.post(
            "/api/v1/engine/request",
            headers={"Origin": ORIGIN},
            json={"method": "scanner.status", "params": {}, "evil": True},
        )
        assert engine_extra.status_code == 422


def test_request_models_reject_pydantic_v1_coercions(app_factory) -> None:
    app, _, _ = app_factory()
    with TestClient(app) as client:
        integer_token = client.post(
            "/api/v1/session/login",
            headers={"Origin": ORIGIN},
            json={"token": 1234},
        )
        assert integer_token.status_code == 422
        assert login(client).status_code == 200

        claim_array = client.post(
            "/api/v1/control/claim",
            headers={"Origin": ORIGIN},
            json=[],
        )
        assert claim_array.status_code == 422

        claim_string = client.post(
            "/api/v1/control/claim",
            headers={"Origin": ORIGIN},
            json="",
        )
        assert claim_string.status_code == 422

        integer_method = client.post(
            "/api/v1/engine/request",
            headers={"Origin": ORIGIN},
            json={"method": 123, "params": {}},
        )
        assert integer_method.status_code == 422

        params_array = client.post(
            "/api/v1/engine/request",
            headers={"Origin": ORIGIN},
            json={"method": "scanner.status", "params": [["key", "value"]]},
        )
        assert params_array.status_code == 422

    with pytest.raises(ValidationError, match="string keys"):
        EngineRequestBody(method="scanner.status", params={1: "value"})


def test_trusted_lan_private_peer_needs_no_login_but_still_needs_exact_origin(
    app_factory,
) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    with TestClient(app, client=("192.168.40.25", 50_000)) as client:
        session = client.get("/api/v1/session")
        assert session.status_code == 200
        assert session.json() == {
            "authenticated": True,
            "control": "available",
        }

        missing_origin = client.post("/api/v1/control/claim")
        assert missing_origin.status_code == 403
        assert missing_origin.json()["error"]["code"] == "ORIGIN_FORBIDDEN"

        wrong_origin = client.post(
            "/api/v1/control/claim",
            headers={"Origin": "http://evil.test"},
        )
        assert wrong_origin.status_code == 403
        assert wrong_origin.json()["error"]["code"] == "ORIGIN_FORBIDDEN"

        claimed = client.post(
            "/api/v1/control/claim",
            headers={"Origin": ORIGIN},
        )
        assert claimed.status_code == 200
        assert claimed.json()["leaseToken"]


@pytest.mark.parametrize(
    "peer",
    [
        ("8.8.8.8", 50_000),
        ("100.64.0.10", 50_000),
        ("169.254.1.10", 50_000),
        ("fe80::10", 50_000),
        ("not-an-address", 50_000),
        ("192.168.40.25", "not-a-port"),
        ("192.168.40.25", 0),
        None,
    ],
)
def test_trusted_lan_rejects_non_lan_http_peers_but_keeps_probes_minimal(
    app_factory,
    peer,
) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    with TestClient(app, client=peer) as client:
        rejected = client.get("/api/v1/session")
        assert rejected.status_code == 403
        assert rejected.json()["error"]["code"] == "PEER_FORBIDDEN"
        assert client.get("/not-a-probe").status_code == 403

        health = client.get("/healthz")
        startup = client.get("/startupz")
        assert health.status_code == 200
        assert health.json() == {"status": "ok"}
        assert startup.status_code == 200
        assert startup.json() == {"started": True}


@pytest.mark.parametrize(
    "header",
    ["Forwarded", "X-Forwarded-For", "X-Real-IP"],
)
def test_trusted_lan_rejects_proxy_client_headers_even_from_private_peer(
    app_factory,
    header,
) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    with TestClient(app, client=("192.168.40.25", 50_000)) as client:
        rejected = client.get(
            "/api/v1/session",
            headers={header: "for=192.168.40.25"},
        )
        assert rejected.status_code == 403
        assert rejected.json()["error"]["code"] == "PEER_FORBIDDEN"
        assert "proxy client-address headers" in rejected.json()["error"]["message"]


def test_trusted_lan_forwarded_private_address_cannot_spoof_public_peer(
    app_factory,
) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    with TestClient(app, client=("203.0.113.10", 50_000)) as client:
        rejected = client.get(
            "/api/v1/session",
            headers={"X-Forwarded-For": "192.168.40.25"},
        )
        assert rejected.status_code == 403
        assert rejected.json()["error"]["code"] == "PEER_FORBIDDEN"


def test_trusted_lan_peer_gate_covers_static_assets(
    app_factory, tmp_path: Path
) -> None:
    static_dir = tmp_path / "lan-static"
    static_dir.mkdir()
    (static_dir / "index.html").write_text("<h1>LAN UI</h1>", encoding="utf-8")
    (static_dir / "scanstudio-web-runtime.json").write_text(
        '{"schemaVersion":1,"runtime":"simulator-only-web"}\n',
        encoding="utf-8",
    )

    public_app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
        static_dir=static_dir,
    )
    with TestClient(public_app, client=("203.0.113.10", 50_000)) as client:
        assert client.get("/").status_code == 403

    private_app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
        static_dir=static_dir,
    )
    with TestClient(private_app, client=("fd12:3456::10", 50_000)) as client:
        response = client.get("/")
        assert response.status_code == 200
        assert "LAN UI" in response.text


def test_browser_session_limit_rejects_new_sessions_without_evicting_existing(
    app_factory,
) -> None:
    app, _, _ = app_factory(max_auth_sessions=2)
    with TestClient(app) as client:
        assert login(client).status_code == 200
        first_session = client.cookies.get("scanstudio_session")
        assert first_session is not None

        client.cookies.clear()
        assert login(client).status_code == 200
        second_session = client.cookies.get("scanstudio_session")
        assert second_session is not None and second_session != first_session

        client.cookies.clear()
        refused = login(client)
        assert refused.status_code == 429
        assert refused.json()["error"]["code"] == "SESSION_LIMIT_REACHED"

        existing = client.get(
            "/api/v1/session",
            headers={"Cookie": f"scanstudio_session={first_session}"},
        )
        assert existing.json()["authenticated"] is True


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


def test_trusted_lan_private_peer_opens_websocket_without_login(app_factory) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    with TestClient(app, client=("10.20.30.40", 50_000)) as client:
        with client.websocket_connect(
            "/api/v1/engine/events",
            headers={"Origin": ORIGIN},
        ):
            pass


@pytest.mark.parametrize(
    ("peer", "extra_headers"),
    [
        (("8.8.8.8", 50_000), {}),
        (("100.64.0.10", 50_000), {}),
        (("169.254.1.10", 50_000), {}),
        (("fe80::10", 50_000), {}),
        (("not-an-address", 50_000), {}),
        (("192.168.40.25", "not-a-port"), {}),
        (("192.168.40.25", 0), {}),
        (None, {}),
        (("192.168.40.25", 50_000), {"X-Forwarded-For": "10.0.0.2"}),
    ],
)
def test_trusted_lan_websocket_rejects_untrusted_peers_and_proxy_headers(
    app_factory,
    peer,
    extra_headers,
) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    headers = {"Origin": ORIGIN, **extra_headers}
    with TestClient(app, client=peer) as client:
        with pytest.raises(WebSocketDisconnect) as caught:
            with client.websocket_connect(
                "/api/v1/engine/events",
                headers=headers,
            ):
                pass
        assert caught.value.code == 4403


def test_trusted_lan_websocket_preserves_exact_origin_check(app_factory) -> None:
    app, _, _ = app_factory(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host="0.0.0.0",
        token=None,
    )
    with TestClient(app, client=("192.168.40.25", 50_000)) as client:
        with pytest.raises(WebSocketDisconnect) as caught:
            with client.websocket_connect(
                "/api/v1/engine/events",
                headers={"Origin": "http://evil.test"},
            ):
                pass
        assert caught.value.code == 4403


def test_event_subscriber_limit_rejects_excess_and_recovers_capacity(
    app_factory,
) -> None:
    app, _, _ = app_factory(max_event_subscribers=1)
    with TestClient(app) as client:
        assert login(client).status_code == 200
        with client.websocket_connect(
            "/api/v1/engine/events", headers={"Origin": ORIGIN}
        ):
            with pytest.raises(WebSocketDisconnect) as caught:
                with client.websocket_connect(
                    "/api/v1/engine/events", headers={"Origin": ORIGIN}
                ) as excess:
                    excess.receive_json()
            assert caught.value.code == 4429

        # Unsubscribing the first observer deterministically returns capacity.
        with client.websocket_connect(
            "/api/v1/engine/events", headers={"Origin": ORIGIN}
        ):
            pass


def test_public_health_endpoints_hide_engine_failure_details(app_factory) -> None:
    app, _, _ = app_factory(mode="exit-on-status")
    with TestClient(app) as client:
        assert login(client).status_code == 200
        failed = post_engine(client, "scanner.status")
        assert failed.status_code == 503

        health = client.get("/healthz")
        startup = client.get("/startupz")
        assert health.status_code == 503
        assert startup.status_code == 503
        assert health.json() == {"status": "unhealthy"}
        assert startup.json() == {"started": False}


@pytest.mark.asyncio
async def test_websocket_accept_failure_unsubscribes_observer() -> None:
    app = create_app(
        Settings(
            auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
            bind_host="0.0.0.0",
            allowed_origins=(ORIGIN,),
        )
    )
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
        scope = {"client": ("127.0.0.1", 50_000)}
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
