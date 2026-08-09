from __future__ import annotations

import asyncio
import sys
from dataclasses import replace
from pathlib import Path

import pytest

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
        allowed_origins=("http://testserver",),
        engine_startup_timeout_seconds=1,
        engine_request_timeout_seconds=1,
        engine_shutdown_timeout_seconds=0.1,
    )


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
        assert fatal_notifications == [
            "scanstudio-engine stdout closed unexpectedly"
        ]
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
