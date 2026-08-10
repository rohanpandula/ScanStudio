from __future__ import annotations

import pytest

from scanstudio_web.settings import AuthMode, ConfigurationError, Settings


def test_non_loopback_bind_requires_token_and_explicit_origin() -> None:
    with pytest.raises(ConfigurationError, match="TOKEN"):
        Settings()
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
    origins = Settings(shared_token="local-development-token").expected_origins
    assert "http://127.0.0.1:8787" in origins
    assert "http://localhost:1420" in origins


def test_auth_mode_defaults_to_token_and_rejects_ambiguous_lan_settings() -> None:
    defaults = Settings(shared_token="local-development-token")
    assert defaults.auth_mode is AuthMode.TOKEN
    assert defaults.trusted_lan_no_login is False

    with pytest.raises(ConfigurationError, match="ALLOWED_ORIGINS"):
        Settings(
            auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
            bind_host="0.0.0.0",
        )
    with pytest.raises(ConfigurationError, match="TOKEN must be unset"):
        Settings(
            auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
            shared_token="must-not-be-ignored",
            allowed_origins=("http://scanner.test",),
        )
    with pytest.raises(ConfigurationError, match="auth_mode must be one of"):
        Settings(auth_mode="automatic")  # type: ignore[arg-type]


@pytest.mark.parametrize(
    "bind_host",
    [
        "0.0.0.0",
        "10.20.30.40",
        "172.16.0.1",
        "172.31.255.254",
        "192.168.50.10",
        "fc00::1",
        "fd12:3456::10",
    ],
)
def test_trusted_lan_mode_accepts_only_explicit_private_interface_binds(
    bind_host,
) -> None:
    settings = Settings(
        auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
        bind_host=bind_host,
        allowed_origins=("http://scanner.test",),
    )
    assert settings.bind_host == bind_host


@pytest.mark.parametrize(
    "bind_host",
    [
        "127.0.0.1",
        "localhost",
        "::1",
        "::",
        "8.8.8.8",
        "100.64.0.1",
        "169.254.1.1",
        "fe80::1",
        "scanner.internal",
        "not-an-address",
    ],
)
def test_trusted_lan_mode_rejects_ambiguous_or_non_private_binds(bind_host) -> None:
    with pytest.raises(ConfigurationError, match="SCANSTUDIO_WEB_BIND"):
        Settings(
            auth_mode=AuthMode.TRUSTED_LAN_NO_LOGIN,
            bind_host=bind_host,
            allowed_origins=("http://scanner.test",),
        )


def test_token_mode_allows_public_literal_bind_with_token_and_origin() -> None:
    settings = Settings(
        bind_host="8.8.8.8",
        shared_token="test-access-token",
        allowed_origins=("https://scanner.example",),
    )
    assert settings.auth_mode is AuthMode.TOKEN


def test_trusted_lan_mode_and_existing_bind_port_are_configurable_from_env(
    monkeypatch,
) -> None:
    monkeypatch.setenv("SCANSTUDIO_WEB_AUTH_MODE", "trusted-lan-no-login")
    monkeypatch.setenv("SCANSTUDIO_WEB_BIND", "0.0.0.0")
    monkeypatch.setenv("SCANSTUDIO_WEB_PORT", "9876")
    monkeypatch.setenv("SCANSTUDIO_WEB_ALLOWED_ORIGINS", "http://scanner.test:9876")
    monkeypatch.delenv("SCANSTUDIO_WEB_TOKEN", raising=False)

    settings = Settings.from_env()

    assert settings.auth_mode is AuthMode.TRUSTED_LAN_NO_LOGIN
    assert settings.bind_host == "0.0.0.0"
    assert settings.port == 9876
    assert settings.authentication_required is False
    assert settings.expected_origins == ("http://scanner.test:9876",)

    monkeypatch.setenv("SCANSTUDIO_WEB_AUTH_MODE", "implicit")
    with pytest.raises(ConfigurationError, match="SCANSTUDIO_WEB_AUTH_MODE"):
        Settings.from_env()


def test_https_origins_infer_secure_cookie_unless_explicitly_overridden(
    monkeypatch,
) -> None:
    monkeypatch.setenv("SCANSTUDIO_WEB_TOKEN", "test-access-token")
    monkeypatch.setenv(
        "SCANSTUDIO_WEB_ALLOWED_ORIGINS",
        "https://scanner.example.test",
    )
    monkeypatch.delenv("SCANSTUDIO_WEB_COOKIE_SECURE", raising=False)

    assert Settings.from_env().cookie_secure is True

    monkeypatch.setenv("SCANSTUDIO_WEB_COOKIE_SECURE", "false")
    assert Settings.from_env().cookie_secure is False


def test_capacity_and_engine_write_limits_are_explicit_and_bounded(
    monkeypatch,
) -> None:
    monkeypatch.setenv("SCANSTUDIO_WEB_TOKEN", "test-access-token")
    monkeypatch.setenv("SCANSTUDIO_WEB_MAX_AUTH_SESSIONS", "17")
    monkeypatch.setenv("SCANSTUDIO_WEB_MAX_EVENT_SUBSCRIBERS", "9")
    monkeypatch.setenv("SCANSTUDIO_WEB_ENGINE_WRITE_TIMEOUT_SECONDS", "1.25")
    settings = Settings.from_env()

    assert settings.max_auth_sessions == 17
    assert settings.max_event_subscribers == 9
    assert settings.engine_write_timeout_seconds == 1.25

    with pytest.raises(ConfigurationError, match="max_auth_sessions"):
        Settings(shared_token="test-access-token", max_auth_sessions=0)
    with pytest.raises(ConfigurationError, match="max_auth_sessions"):
        Settings(shared_token="test-access-token", max_auth_sessions=4_097)
    with pytest.raises(ConfigurationError, match="max_event_subscribers"):
        Settings(shared_token="test-access-token", max_event_subscribers=0)
    with pytest.raises(ConfigurationError, match="max_event_subscribers"):
        Settings(shared_token="test-access-token", max_event_subscribers=1_025)
    with pytest.raises(ConfigurationError, match="engine_write_timeout_seconds"):
        Settings(shared_token="test-access-token", engine_write_timeout_seconds=0)
    with pytest.raises(ConfigurationError, match="engine_write_timeout_seconds"):
        Settings(
            shared_token="test-access-token",
            engine_write_timeout_seconds=float("inf"),
        )
