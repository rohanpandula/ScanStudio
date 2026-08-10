from __future__ import annotations

import pytest

from scanstudio_web.settings import ConfigurationError, Settings


def test_non_loopback_bind_requires_token_and_explicit_origin() -> None:
    with pytest.raises(ConfigurationError, match="TOKEN"):
        Settings(bind_host="0.0.0.0")
    with pytest.raises(ConfigurationError, match="ALLOWED_ORIGINS"):
        Settings(bind_host="0.0.0.0", shared_token="long-random-token")
    configured = Settings(
        bind_host="0.0.0.0",
        shared_token="long-random-token",
        allowed_origins=("https://scanner.example",),
    )
    assert configured.expected_origins == ("https://scanner.example",)


def test_loopback_defaults_include_gateway_and_vite_origins() -> None:
    origins = Settings().expected_origins
    assert "http://127.0.0.1:8787" in origins
    assert "http://localhost:1420" in origins


def test_capacity_and_engine_write_limits_are_explicit_and_bounded(
    monkeypatch,
) -> None:
    monkeypatch.setenv("SCANSTUDIO_WEB_MAX_AUTH_SESSIONS", "17")
    monkeypatch.setenv("SCANSTUDIO_WEB_MAX_EVENT_SUBSCRIBERS", "9")
    monkeypatch.setenv("SCANSTUDIO_WEB_ENGINE_WRITE_TIMEOUT_SECONDS", "1.25")
    settings = Settings.from_env()

    assert settings.max_auth_sessions == 17
    assert settings.max_event_subscribers == 9
    assert settings.engine_write_timeout_seconds == 1.25

    with pytest.raises(ConfigurationError, match="max_auth_sessions"):
        Settings(max_auth_sessions=0)
    with pytest.raises(ConfigurationError, match="max_auth_sessions"):
        Settings(max_auth_sessions=4_097)
    with pytest.raises(ConfigurationError, match="max_event_subscribers"):
        Settings(max_event_subscribers=0)
    with pytest.raises(ConfigurationError, match="max_event_subscribers"):
        Settings(max_event_subscribers=1_025)
    with pytest.raises(ConfigurationError, match="engine_write_timeout_seconds"):
        Settings(engine_write_timeout_seconds=0)
    with pytest.raises(ConfigurationError, match="engine_write_timeout_seconds"):
        Settings(engine_write_timeout_seconds=float("inf"))
