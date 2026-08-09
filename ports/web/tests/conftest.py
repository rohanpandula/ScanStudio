from __future__ import annotations

import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from scanstudio_web.app import create_app
from scanstudio_web.settings import Settings

FAKE_ENGINE = Path(__file__).with_name("fake_engine.py")
ORIGIN = "http://testserver"
ACCESS_TOKEN = "test-access-token"


@pytest.fixture
def app_factory(tmp_path: Path) -> Callable[..., tuple[object, Path, Path]]:
    counter = 0

    def make(
        *,
        mode: str = "normal",
        token: str | None = ACCESS_TOKEN,
        static_dir: Path | None = None,
    ):
        nonlocal counter
        counter += 1
        request_log = tmp_path / f"requests-{counter}.ndjson"
        env_log = tmp_path / f"environment-{counter}.json"
        settings = Settings(
            engine_command=(
                sys.executable,
                str(FAKE_ENGINE),
                "--mode",
                mode,
                "--request-log",
                str(request_log),
                "--env-log",
                str(env_log),
            ),
            shared_token=token,
            allowed_origins=(ORIGIN,),
            static_dir=static_dir,
            lease_ttl_seconds=0.25,
            engine_startup_timeout_seconds=1.0,
            engine_request_timeout_seconds=1.0,
            engine_shutdown_timeout_seconds=0.15,
            event_queue_size=8,
        )
        return create_app(settings), request_log, env_log

    return make


def login(client, token: str = ACCESS_TOKEN):
    return client.post(
        "/api/v1/session/login",
        headers={"Origin": ORIGIN},
        json={"token": token},
    )


def claim(client) -> str:
    response = client.post("/api/v1/control/claim", headers={"Origin": ORIGIN})
    assert response.status_code == 200, response.text
    return response.json()["leaseToken"]


def post_engine(client, method: str, params=None, lease: str | None = None):
    headers = {"Origin": ORIGIN}
    if lease is not None:
        headers["X-ScanStudio-Control-Lease"] = lease
    return client.post(
        "/api/v1/engine/request",
        headers=headers,
        json={"method": method, "params": params or {}},
    )
