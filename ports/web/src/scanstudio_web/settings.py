from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


class ConfigurationError(ValueError):
    """Raised when a deployment would weaken the gateway's security boundary."""


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ConfigurationError(f"{name} must be true or false")


def _env_int(name: str, default: int, *, minimum: int, maximum: int) -> int:
    raw = os.getenv(name)
    try:
        value = default if raw is None else int(raw)
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ConfigurationError(f"{name} must be between {minimum} and {maximum}")
    return value


def _env_float(name: str, default: float, *, minimum: float, maximum: float) -> float:
    raw = os.getenv(name)
    try:
        value = default if raw is None else float(raw)
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be a number") from exc
    if not minimum <= value <= maximum:
        raise ConfigurationError(f"{name} must be between {minimum} and {maximum}")
    return value


def is_loopback_host(host: str) -> bool:
    normalized = host.strip().strip("[]").lower()
    if normalized == "localhost":
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


def normalize_origin(origin: str) -> str:
    """Return a canonical HTTP(S) origin or reject a URL with extra components."""

    parsed = urlsplit(origin.strip())
    if parsed.scheme.lower() not in {"http", "https"}:
        raise ConfigurationError("origins must use http or https")
    if (
        not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigurationError(
            "origins must contain only scheme, host, and optional port"
        )

    scheme = parsed.scheme.lower()
    host = parsed.hostname.lower()
    try:
        port = parsed.port
    except ValueError as exc:
        raise ConfigurationError("origin contains an invalid port") from exc
    default_port = 80 if scheme == "http" else 443
    port_suffix = "" if port is None or port == default_port else f":{port}"
    rendered_host = f"[{host}]" if ":" in host else host
    return f"{scheme}://{rendered_host}{port_suffix}"


@dataclass(frozen=True, slots=True)
class Settings:
    engine_command: tuple[str, ...] = ("scanstudio-engine",)
    bind_host: str = "127.0.0.1"
    port: int = 8787
    shared_token: str | None = None
    allowed_origins: tuple[str, ...] = ()
    static_dir: Path | None = None
    cookie_name: str = "scanstudio_session"
    cookie_secure: bool = False
    session_ttl_seconds: int = 43_200
    lease_ttl_seconds: float = 30.0
    engine_startup_timeout_seconds: float = 10.0
    engine_request_timeout_seconds: float = 30.0
    engine_shutdown_timeout_seconds: float = 3.0
    max_request_body_bytes: int = 1_048_576
    max_engine_line_bytes: int = 4_194_304
    event_queue_size: int = 256

    def __post_init__(self) -> None:
        if not self.engine_command or any(not item for item in self.engine_command):
            raise ConfigurationError(
                "engine_command must contain a non-empty executable"
            )
        if not 1 <= self.port <= 65_535:
            raise ConfigurationError("port must be between 1 and 65535")
        if self.shared_token is not None and not self.shared_token.strip():
            raise ConfigurationError("the configured access token must not be blank")
        if not is_loopback_host(self.bind_host) and self.shared_token is None:
            raise ConfigurationError(
                "SCANSTUDIO_WEB_TOKEN is required when binding outside loopback"
            )
        if not is_loopback_host(self.bind_host) and not self.allowed_origins:
            raise ConfigurationError(
                "SCANSTUDIO_WEB_ALLOWED_ORIGINS is required when binding outside loopback"
            )
        if self.lease_ttl_seconds <= 0:
            raise ConfigurationError("lease_ttl_seconds must be positive")
        if self.session_ttl_seconds <= 0:
            raise ConfigurationError("session_ttl_seconds must be positive")
        if self.event_queue_size < 1:
            raise ConfigurationError("event_queue_size must be positive")
        for origin in self.expected_origins:
            normalize_origin(origin)

    @property
    def authentication_required(self) -> bool:
        return self.shared_token is not None

    @property
    def expected_origins(self) -> tuple[str, ...]:
        if self.allowed_origins:
            return tuple(normalize_origin(item) for item in self.allowed_origins)
        # The no-token development mode binds only to loopback. Keep its
        # origin set explicit to resist DNS rebinding through an attacker Host.
        return (
            f"http://127.0.0.1:{self.port}",
            f"http://localhost:{self.port}",
            f"http://[::1]:{self.port}",
            "http://127.0.0.1:1420",
            "http://localhost:1420",
            "http://[::1]:1420",
        )

    @classmethod
    def from_env(cls) -> Settings:
        bind_host = os.getenv("SCANSTUDIO_WEB_BIND", "127.0.0.1").strip()
        port = _env_int("SCANSTUDIO_WEB_PORT", 8787, minimum=1, maximum=65_535)
        token = os.getenv("SCANSTUDIO_WEB_TOKEN")
        if token is not None and not token.strip():
            token = None

        origins_raw = os.getenv("SCANSTUDIO_WEB_ALLOWED_ORIGINS", "")
        origins = tuple(
            normalize_origin(item) for item in origins_raw.split(",") if item.strip()
        )
        all_origins_secure = bool(origins) and all(
            origin.startswith("https://") for origin in origins
        )
        static_raw = os.getenv("SCANSTUDIO_WEB_STATIC_DIR")
        static_dir = Path(static_raw).expanduser() if static_raw else None

        return cls(
            engine_command=(os.getenv("SCANSTUDIO_ENGINE_PATH", "scanstudio-engine"),),
            bind_host=bind_host,
            port=port,
            shared_token=token,
            allowed_origins=origins,
            static_dir=static_dir,
            cookie_secure=_env_bool("SCANSTUDIO_WEB_COOKIE_SECURE", all_origins_secure),
            session_ttl_seconds=_env_int(
                "SCANSTUDIO_WEB_SESSION_TTL_SECONDS",
                43_200,
                minimum=60,
                maximum=604_800,
            ),
            lease_ttl_seconds=_env_float(
                "SCANSTUDIO_WEB_LEASE_TTL_SECONDS",
                30.0,
                minimum=5.0,
                maximum=300.0,
            ),
            engine_startup_timeout_seconds=_env_float(
                "SCANSTUDIO_WEB_ENGINE_STARTUP_TIMEOUT_SECONDS",
                10.0,
                minimum=0.1,
                maximum=120.0,
            ),
            engine_request_timeout_seconds=_env_float(
                "SCANSTUDIO_WEB_ENGINE_REQUEST_TIMEOUT_SECONDS",
                30.0,
                minimum=0.1,
                maximum=600.0,
            ),
            engine_shutdown_timeout_seconds=_env_float(
                "SCANSTUDIO_WEB_ENGINE_SHUTDOWN_TIMEOUT_SECONDS",
                3.0,
                minimum=0.1,
                maximum=30.0,
            ),
            max_request_body_bytes=_env_int(
                "SCANSTUDIO_WEB_MAX_REQUEST_BODY_BYTES",
                1_048_576,
                minimum=1_024,
                maximum=16_777_216,
            ),
            max_engine_line_bytes=_env_int(
                "SCANSTUDIO_WEB_MAX_ENGINE_LINE_BYTES",
                4_194_304,
                minimum=65_536,
                maximum=67_108_864,
            ),
            event_queue_size=_env_int(
                "SCANSTUDIO_WEB_EVENT_QUEUE_SIZE",
                256,
                minimum=8,
                maximum=4_096,
            ),
        )
