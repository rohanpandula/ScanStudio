from __future__ import annotations

import asyncio
import secrets
import time
from collections.abc import Callable

from .settings import Settings, normalize_origin


class AuthenticationError(Exception):
    pass


class OriginError(Exception):
    pass


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
