from __future__ import annotations

import asyncio

import pytest

from scanstudio_web.controller_lease import ControllerLease, LeaseRejected


@pytest.mark.asyncio
async def test_concurrent_claim_has_exactly_one_winner() -> None:
    lease = ControllerLease(30)

    async def attempt() -> bool:
        try:
            await lease.claim()
        except LeaseRejected:
            return False
        return True

    results = await asyncio.gather(*(attempt() for _ in range(50)))
    assert results.count(True) == 1
    assert results.count(False) == 49


@pytest.mark.asyncio
async def test_expired_lease_replacement_rejects_stale_capability() -> None:
    now = 10.0
    tokens = iter(("first-capability", "replacement-capability"))
    lease = ControllerLease(5, clock=lambda: now, token_factory=lambda: next(tokens))
    first = await lease.claim()
    assert await lease.state(first.token) == "owned"

    now = 16.0
    replacement = await lease.claim()
    assert replacement.token != first.token
    assert await lease.state(first.token) == "observer"
    with pytest.raises(LeaseRejected):
        await lease.heartbeat(first.token)
    with pytest.raises(LeaseRejected):
        await lease.release(first.token)
    assert await lease.state(replacement.token) == "owned"
