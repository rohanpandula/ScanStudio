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
