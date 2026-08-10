from __future__ import annotations

import asyncio
import ipaddress
import secrets
import time
from collections.abc import Callable, Mapping
from typing import Any

from .settings import Settings, normalize_origin


class AuthenticationError(Exception):
    pass


class OriginError(Exception):
    pass


class SessionLimitReached(Exception):
    pass


class PeerAccessError(Exception):
    pass


_TRUSTED_IPV4_NETWORKS = tuple(
    ipaddress.ip_network(value)
    for value in ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)
_TRUSTED_IPV6_NETWORKS = tuple(
    ipaddress.ip_network(value) for value in ("::1/128", "fc00::/7")
)
_FORWARDED_CLIENT_HEADERS = frozenset({"forwarded", "x-forwarded-for", "x-real-ip"})


def socket_peer_is_trusted_lan(host: Any) -> bool:
    """Classify only a literal socket peer, never a proxy-supplied address."""

    if not isinstance(host, str) or not host or "%" in host:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False

    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    networks = (
        _TRUSTED_IPV4_NETWORKS
        if isinstance(address, ipaddress.IPv4Address)
        else _TRUSTED_IPV6_NETWORKS
    )
    return any(address in network for network in networks)


class AuthManager:
    """In-memory opaque browser sessions backed by one deployment token."""

    def __init__(
        self,
        settings: Settings,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._settings = settings
        self._clock = clock
        self._sessions: dict[str, float] = {}
        self._lock = asyncio.Lock()

    @property
    def required(self) -> bool:
        return self._settings.authentication_required

    def origin_is_allowed(self, value: str | None) -> bool:
        if value is None or value.strip().lower() == "null":
            return False
        try:
            normalized = normalize_origin(value)
        except ValueError:
            return False
        return normalized in self._settings.expected_origins

    def require_origin(self, value: str | None) -> None:
        if not self.origin_is_allowed(value):
            raise OriginError(
                "request Origin is missing or is not an allowed ScanStudio origin"
            )

    def require_trusted_peer(
        self,
        client: Any,
        headers: Mapping[str, str],
    ) -> None:
        if not self._settings.trusted_lan_no_login:
            return
        header_names = {name.lower() for name in headers}
        if header_names.intersection(_FORWARDED_CLIENT_HEADERS):
            raise PeerAccessError(
                "proxy client-address headers are forbidden in trusted LAN mode"
            )
        if (
            not isinstance(client, (tuple, list))
            or len(client) != 2
            or not isinstance(client[1], int)
            or isinstance(client[1], bool)
            or not 1 <= client[1] <= 65_535
            or not socket_peer_is_trusted_lan(client[0])
        ):
            raise PeerAccessError(
                "request did not arrive from an allowed trusted LAN socket peer"
            )

    async def login(
        self, token: str, existing_session: str | None = None
    ) -> str | None:
        if not self.required:
            return None
        expected = self._settings.shared_token
        assert expected is not None
        if not secrets.compare_digest(token.encode("utf-8"), expected.encode("utf-8")):
            raise AuthenticationError("invalid access token")

        now = self._clock()
        async with self._lock:
            self._remove_expired_locked(now)
            if existing_session in self._sessions:
                session_id = existing_session
            else:
                if len(self._sessions) >= self._settings.max_auth_sessions:
                    raise SessionLimitReached(
                        "the active browser session limit has been reached"
                    )
                session_id = secrets.token_urlsafe(32)
            self._sessions[session_id] = now + self._settings.session_ttl_seconds
            return session_id

    async def authenticated(
        self,
        session_id: str | None,
        *,
        refresh: bool = True,
    ) -> bool:
        if not self.required:
            return True
        if not session_id:
            return False
        now = self._clock()
        async with self._lock:
            deadline = self._sessions.get(session_id)
            if deadline is None or deadline <= now:
                self._sessions.pop(session_id, None)
                return False
            if refresh:
                self._sessions[session_id] = now + self._settings.session_ttl_seconds
            return True

    def _remove_expired_locked(self, now: float) -> None:
        expired = [key for key, deadline in self._sessions.items() if deadline <= now]
        for key in expired:
            self._sessions.pop(key, None)
