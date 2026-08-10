from __future__ import annotations

import asyncio
import json
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from scanstudio_web.controller_lease import ControllerLease, LeaseRejected
from scanstudio_web.engine_process import (
    EngineProtocolError,
    EngineRequestTimeout,
    EngineSupervisor,
    EngineUnavailable,
)
from scanstudio_web.relay import EventBroker, SubscriberClosed
from scanstudio_web.settings import Settings

FAKE_ENGINE = Path(__file__).with_name("fake_engine.py")


def settings_for(tmp_path: Path, mode: str) -> Settings:
    return Settings(
        engine_command=(
            sys.executable,
            str(FAKE_ENGINE),
            "--mode",
            mode,
            "--request-log",
            str(tmp_path / f"{mode}.ndjson"),
        ),
        shared_token="test-access-token",
        allowed_origins=("http://testserver",),
        engine_startup_timeout_seconds=1,
        engine_request_timeout_seconds=1,
        engine_shutdown_timeout_seconds=0.1,
    )


@pytest.mark.asyncio
async def test_engine_child_contract_is_exact_command_and_stdio_only(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = settings_for(tmp_path, "normal")
    captured: dict[str, object] = {}

    async def capture_spawn(*command: str, **kwargs: object):
        captured["command"] = command
        captured["kwargs"] = kwargs
        raise OSError("stop after contract capture")

    monkeypatch.setenv("SCANSTUDIO_WEB_AUTH_MODE", "trusted-lan-no-login")
    monkeypatch.setenv("SCANSTUDIO_WEB_BIND", "0.0.0.0")
    monkeypatch.setenv("SCANSTUDIO_WEB_PORT", "9876")
    monkeypatch.setattr(asyncio, "create_subprocess_exec", capture_spawn)
    supervisor = EngineSupervisor(settings, EventBroker(8))

    with pytest.raises(EngineUnavailable, match="could not start"):
        await supervisor.start()

    assert captured["command"] == settings.engine_command
    kwargs = captured["kwargs"]
    assert isinstance(kwargs, dict)
    assert kwargs["stdin"] is asyncio.subprocess.PIPE
    assert kwargs["stdout"] is asyncio.subprocess.PIPE
    assert kwargs["stderr"] is asyncio.subprocess.PIPE
    assert not any(name.startswith("SCANSTUDIO_WEB_") for name in kwargs["env"])
    assert "host" not in kwargs
    assert "port" not in kwargs


@pytest.mark.asyncio
async def test_out_of_order_responses_are_correlated(tmp_path: Path) -> None:
    supervisor = EngineSupervisor(
        settings_for(tmp_path, "out-of-order"), EventBroker(8)
    )
    await supervisor.start()
    try:
        first, second = await asyncio.gather(
            supervisor.request("scanner.status", {"sequence": "first"}),
            supervisor.request("scanner.status", {"sequence": "second"}),
        )
        assert first == {"result": {"sequence": "first"}}
        assert second == {"result": {"sequence": "second"}}
    finally:
        await supervisor.close()


@pytest.mark.asyncio
async def test_malformed_engine_output_marks_supervisor_unhealthy(
    tmp_path: Path,
) -> None:
    supervisor = EngineSupervisor(settings_for(tmp_path, "malformed"), EventBroker(8))
    await supervisor.start()
    with pytest.raises(EngineProtocolError):
        await supervisor.request("scanner.status", {})
    assert supervisor.ready is False
    assert supervisor.health()["error"] == "engine emitted malformed JSON"
    await supervisor.close()


@pytest.mark.asyncio
async def test_engine_death_closes_existing_event_subscribers(tmp_path: Path) -> None:
    events = EventBroker(8)
    subscriber = await events.subscribe()
    fatal_notifications: list[str] = []
    supervisor = EngineSupervisor(
        settings_for(tmp_path, "exit-on-status"),
        events,
        on_fatal=fatal_notifications.append,
    )
    await supervisor.start()
    try:
        with pytest.raises(
            EngineUnavailable,
            match="scanstudio-engine stdout closed unexpectedly",
        ):
            await supervisor.request("scanner.status", {})

        with pytest.raises(SubscriberClosed):
            await asyncio.wait_for(subscriber.next_event(), timeout=0.5)
        assert supervisor.ready is False
        assert fatal_notifications == ["scanstudio-engine stdout closed unexpectedly"]
        await supervisor._mark_fatal("duplicate fatal signal")
        assert len(fatal_notifications) == 1
    finally:
        # Fatal handling and normal lifespan shutdown may both close the broker.
        await supervisor.close()
    assert len(fatal_notifications) == 1


@pytest.mark.asyncio
async def test_normal_shutdown_does_not_send_fatal_notification(
    tmp_path: Path,
) -> None:
    fatal_notifications: list[str] = []
    supervisor = EngineSupervisor(
        settings_for(tmp_path, "normal"),
        EventBroker(8),
        on_fatal=fatal_notifications.append,
    )
    await supervisor.start()
    await supervisor.close()

    assert fatal_notifications == []


@pytest.mark.asyncio
async def test_late_response_after_timeout_is_tombstoned(tmp_path: Path) -> None:
    settings = replace(
        settings_for(tmp_path, "normal"), engine_request_timeout_seconds=0.03
    )
    supervisor = EngineSupervisor(settings, EventBroker(8))
    await supervisor.start()
    try:
        with pytest.raises(EngineRequestTimeout):
            await supervisor.request("test.delayed", {"seconds": 0.08})
        await asyncio.sleep(0.12)
        assert supervisor.ready is True
        listed = await supervisor.request("scanner.list", {})
        assert listed["result"]["devices"][0]["kind"] == "simulated"
    finally:
        await supervisor.close()


@pytest.mark.asyncio
async def test_stalled_stdin_marks_engine_fatal_and_releases_controller_lock(
    tmp_path: Path,
) -> None:
    class HangingStdin:
        def __init__(self) -> None:
            self.writes: list[bytes] = []
            self.write_started = asyncio.Event()

        def write(self, data: bytes) -> None:
            self.writes.append(data)
            self.write_started.set()

        async def drain(self) -> None:
            await asyncio.Event().wait()

    class HangingProcess:
        def __init__(self) -> None:
            self.returncode = None
            self.stdin = HangingStdin()
            self.terminated = False

        def terminate(self) -> None:
            self.terminated = True

    settings = replace(
        settings_for(tmp_path, "normal"), engine_write_timeout_seconds=0.5
    )
    fatal_notifications: list[str] = []
    supervisor = EngineSupervisor(
        settings,
        EventBroker(8),
        on_fatal=fatal_notifications.append,
    )
    process = HangingProcess()
    supervisor._process = process
    supervisor._ready = True

    lease = ControllerLease(30)
    grant = await lease.claim()
    reservation = await lease.reserve_submission(grant.token)
    submission = asyncio.create_task(
        supervisor.submit(
            "scanner.status",
            {},
            write_guard=lambda enqueue: lease.commit_submission(
                reservation,
                enqueue,
            ),
        )
    )
    await asyncio.wait_for(process.stdin.write_started.wait(), timeout=0.1)

    # Engine flow control owns its own lane. Controller-plane operations stay
    # live while drain is blocked, rather than waiting for its fatal timeout.
    assert (
        await asyncio.wait_for(lease.heartbeat(grant.token), timeout=0.1)
    ).token == grant.token

    with pytest.raises(EngineUnavailable, match="write timeout"):
        await asyncio.wait_for(submission, timeout=1)

    assert process.stdin.writes
    assert process.terminated is True
    assert supervisor.ready is False
    assert fatal_notifications == [
        "engine stdin remained blocked beyond the configured write timeout"
    ]
    assert (await lease.heartbeat(grant.token)).token == grant.token


@pytest.mark.asyncio
async def test_takeover_rejects_predecessor_waiting_for_engine_writer(
    tmp_path: Path,
) -> None:
    class GatedStdin:
        def __init__(self) -> None:
            self.writes: list[bytes] = []
            self.write_started = asyncio.Event()
            self.drain_gate = asyncio.Event()

        def write(self, data: bytes) -> None:
            self.writes.append(data)
            self.write_started.set()

        async def drain(self) -> None:
            await self.drain_gate.wait()

    class GatedProcess:
        def __init__(self) -> None:
            self.returncode = None
            self.stdin = GatedStdin()

    supervisor = EngineSupervisor(
        settings_for(tmp_path, "normal"),
        EventBroker(8),
    )
    process = GatedProcess()
    supervisor._process = process
    supervisor._ready = True

    # Occupy the writer lane so the old and replacement controller requests
    # both queue behind a real drain boundary.
    lane_owner = asyncio.create_task(supervisor.submit("scanner.status", {}))
    await asyncio.wait_for(process.stdin.write_started.wait(), timeout=0.1)

    tokens = iter(("old-capability", "replacement-capability"))
    lease = ControllerLease(30, token_factory=lambda: next(tokens))
    old_grant = await lease.claim()
    old_reservation = await lease.reserve_submission(old_grant.token)
    old_submission = asyncio.create_task(
        supervisor.submit(
            "scanner.connect",
            {"deviceId": "sim-ls5000-0"},
            write_guard=lambda enqueue: lease.commit_submission(
                old_reservation,
                enqueue,
            ),
        )
    )
    await asyncio.sleep(0)

    await lease.release(old_grant.token)
    replacement = await lease.claim()
    replacement_reservation = await lease.reserve_submission(replacement.token)
    replacement_submission = asyncio.create_task(
        supervisor.submit(
            "sim.loadMedia",
            {"carrier": "strip6"},
            write_guard=lambda enqueue: lease.commit_submission(
                replacement_reservation,
                enqueue,
            ),
        )
    )

    process.stdin.drain_gate.set()
    lane_pending = await lane_owner
    with pytest.raises(LeaseRejected, match="changed before the command was enqueued"):
        await old_submission
    replacement_pending = await replacement_submission

    methods = [json.loads(wire)["method"] for wire in process.stdin.writes]
    assert methods == ["scanner.status", "sim.loadMedia"]
    assert replacement_pending.request_id == lane_pending.request_id + 1

    supervisor._cancel_pending(lane_pending.request_id)
    supervisor._cancel_pending(replacement_pending.request_id)


@pytest.mark.asyncio
async def test_response_after_tombstone_eviction_is_ignored_but_never_issued_id_fails(
    tmp_path: Path,
) -> None:
    supervisor = EngineSupervisor(settings_for(tmp_path, "normal"), EventBroker(8))
    supervisor._next_id = 4_098
    for request_id in range(1, 4_098):
        supervisor._abandon(request_id)

    assert 1 not in supervisor._abandoned_set
    await supervisor._route_message({"id": 1, "result": {"late": True}})

    for never_issued in (0, 4_098):
        with pytest.raises(
            EngineProtocolError,
            match=rf"unknown response id {never_issued}",
        ):
            await supervisor._route_message({"id": never_issued, "result": {}})
