from __future__ import annotations

import asyncio
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import TypeVar

T = TypeVar("T")


class LeaseRejected(Exception):
    """The caller does not possess the one current controller capability."""


@dataclass(frozen=True, slots=True)
class LeaseGrant:
    token: str
    expires_in_seconds: float
    generation: int


@dataclass(frozen=True, slots=True)
class LeaseReservation:
    """Server-internal authorization ticket for one engine enqueue."""

    generation: int


@dataclass(slots=True)
class _ActiveLease:
    token: str
    deadline: float
    generation: int


class ControllerLease:
    """A single, monotonic, expiring capability lease.

    The random token is deliberately separate from the auth cookie so tabs
    sharing one browser cookie remain independent controller candidates.
    """

    def __init__(
        self,
        ttl_seconds: float,
        *,
        clock: Callable[[], float] = time.monotonic,
        token_factory: Callable[[], str] = lambda: secrets.token_urlsafe(32),
    ) -> None:
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        self._ttl = ttl_seconds
        self._clock = clock
        self._token_factory = token_factory
        self._active: _ActiveLease | None = None
        self._generation = 0
        self._lock = asyncio.Lock()

    async def state(self, presented_token: str | None = None) -> str:
        async with self._lock:
            active = self._current_locked()
            if active is None:
                return "available"
            if _tokens_match(presented_token, active.token):
                return "owned"
            return "observer"

    async def claim(self, presented_token: str | None = None) -> LeaseGrant:
        async with self._lock:
            active = self._current_locked()
            if active is not None:
                if _tokens_match(presented_token, active.token):
                    active.deadline = self._clock() + self._ttl
                    return self._grant_locked(active)
                raise LeaseRejected(
                    "another browser tab currently controls the scanner"
                )

            self._generation += 1
            active = _ActiveLease(
                token=self._token_factory(),
                deadline=self._clock() + self._ttl,
                generation=self._generation,
            )
            self._active = active
            return self._grant_locked(active)

    async def heartbeat(self, token: str | None) -> LeaseGrant:
        async with self._lock:
            active = self._require_locked(token)
            active.deadline = self._clock() + self._ttl
            return self._grant_locked(active)

    async def release(self, token: str | None) -> None:
        async with self._lock:
            self._require_locked(token)
            self._active = None

    async def require(self, token: str | None) -> None:
        async with self._lock:
            self._require_locked(token)

    async def reserve_submission(self, token: str | None) -> LeaseReservation:
        """Authorize activity now; actual enqueue must still commit this ticket."""

        async with self._lock:
            active = self._require_locked(token)
            active.deadline = self._clock() + self._ttl
            return LeaseReservation(generation=active.generation)

    async def commit_submission(
        self,
        reservation: LeaseReservation,
        enqueue: Callable[[], T],
    ) -> T:
        """Revalidate a reservation and synchronously enqueue under the lock.

        The engine may wait for its writer lane before calling this method.
        Release, expiry, or takeover invalidates the old generation, so a
        predecessor cannot enter the pipe after a successor owns the lease.
        Only the non-blocking `enqueue` call runs under the lease mutex; pipe
        drain and response waiting remain independent.
        """

        async with self._lock:
            active = self._current_locked()
            if active is None or active.generation != reservation.generation:
                raise LeaseRejected(
                    "the controller lease changed before the command was enqueued"
                )
            active.deadline = self._clock() + self._ttl
            return enqueue()

    def _current_locked(self) -> _ActiveLease | None:
        if self._active is not None and self._active.deadline <= self._clock():
            self._active = None
        return self._active

    def _require_locked(self, token: str | None) -> _ActiveLease:
        active = self._current_locked()
        if active is None or token is None:
            raise LeaseRejected("a current controller lease is required")
        if not _tokens_match(token, active.token):
            raise LeaseRejected(
                "the controller lease is missing, stale, or belongs to another tab"
            )
        return active

    def _grant_locked(self, active: _ActiveLease) -> LeaseGrant:
        return LeaseGrant(
            token=active.token,
            expires_in_seconds=max(0.0, active.deadline - self._clock()),
            generation=active.generation,
        )


def _tokens_match(presented: str | None, expected: str) -> bool:
    if presented is None:
        return False
    return secrets.compare_digest(
        presented.encode("utf-8"),
        expected.encode("utf-8"),
    )
