from __future__ import annotations

import errno
from typing import Any

import pytest

from scanstudio_web import cli
from scanstudio_web.settings import Settings


def test_process_group_isolation_is_opt_in(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[bool] = []
    monkeypatch.delenv("SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP", raising=False)
    monkeypatch.setattr(cli.os, "setsid", lambda: calls.append(True))

    cli._isolate_process_group_if_requested()

    assert calls == []


def test_requested_process_group_isolation_calls_setsid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[bool] = []
    monkeypatch.setenv("SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP", "1")
    monkeypatch.setattr(cli.os, "setsid", lambda: calls.append(True))

    cli._isolate_process_group_if_requested()

    assert calls == [True]


def test_requested_process_group_isolation_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP", "1")

    def fail() -> None:
        raise OSError("not permitted")

    monkeypatch.setattr(cli.os, "setsid", fail)

    with pytest.raises(RuntimeError, match="dedicated process group"):
        cli._isolate_process_group_if_requested()


def test_foundation_process_group_leader_is_already_isolated(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP", "1")
    monkeypatch.setattr(cli.os, "getpid", lambda: 4242)
    monkeypatch.setattr(cli.os, "getpgrp", lambda: 4242)

    def already_group_leader() -> None:
        raise OSError(errno.EPERM, "operation not permitted")

    monkeypatch.setattr(cli.os, "setsid", already_group_leader)

    cli._isolate_process_group_if_requested()


def test_main_requests_uvicorn_exit_after_engine_fatal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}
    settings = Settings(shared_token="test-access-token")

    def fake_create_app(
        configured: Settings,
        *,
        on_engine_fatal,
    ) -> object:
        assert configured is settings
        captured["on_fatal"] = on_engine_fatal
        return object()

    class FakeConfig:
        def __init__(self, app: object, **kwargs: Any) -> None:
            captured["app"] = app
            captured["config"] = kwargs

    class FakeServer:
        def __init__(self, config: FakeConfig) -> None:
            captured["server"] = self
            self.config = config
            self.should_exit = False

        def run(self) -> None:
            captured["on_fatal"]("engine died")

    monkeypatch.setattr(cli, "_isolate_process_group_if_requested", lambda: None)
    monkeypatch.setattr(cli.Settings, "from_env", lambda: settings)
    monkeypatch.setattr(cli, "create_app", fake_create_app)
    monkeypatch.setattr(cli.uvicorn, "Config", FakeConfig)
    monkeypatch.setattr(cli.uvicorn, "Server", FakeServer)

    cli.main()

    assert captured["server"].should_exit is True
    assert captured["config"] == {
        "host": "127.0.0.1",
        "port": 8787,
        "workers": 1,
        "reload": False,
        "proxy_headers": False,
        "server_header": False,
    }
