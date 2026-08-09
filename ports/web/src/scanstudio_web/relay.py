from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any


class SubscriberClosed(Exception):
    pass


_CLOSED = object()


@dataclass(eq=False, slots=True)
class EventSubscriber:
    queue: asyncio.Queue[dict[str, Any] | object]

    async def next_event(self) -> dict[str, Any]:
        value = await self.queue.get()
        if value is _CLOSED:
            raise SubscriberClosed
        assert isinstance(value, dict)
        return value


class EventBroker:
    """Non-blocking bounded fanout for engine events.

    A slow observer is evicted rather than ever applying backpressure to the
    engine stdout reader. There is intentionally no event replay in this first
    simulator slice; reconnecting clients must re-read scanner state.
    """

    def __init__(self, queue_size: int) -> None:
        self._queue_size = queue_size
        self._subscribers: set[EventSubscriber] = set()
        self._closed = False
        self._lock = asyncio.Lock()

    async def subscribe(self) -> EventSubscriber:
        subscriber = EventSubscriber(asyncio.Queue(maxsize=self._queue_size))
        async with self._lock:
            if self._closed:
                subscriber.queue.put_nowait(_CLOSED)
            else:
                self._subscribers.add(subscriber)
        return subscriber

    async def unsubscribe(self, subscriber: EventSubscriber) -> None:
        async with self._lock:
            self._subscribers.discard(subscriber)

    async def publish(self, event: dict[str, Any]) -> None:
        async with self._lock:
            if self._closed:
                return
            overflowed: list[EventSubscriber] = []
            for subscriber in self._subscribers:
                try:
                    subscriber.queue.put_nowait(event)
                except asyncio.QueueFull:
                    overflowed.append(subscriber)
            for subscriber in overflowed:
                self._subscribers.discard(subscriber)
                try:
                    subscriber.queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
                subscriber.queue.put_nowait(_CLOSED)

    async def close(self) -> None:
        async with self._lock:
            if self._closed:
                return
            self._closed = True
            subscribers = tuple(self._subscribers)
            self._subscribers.clear()
            for subscriber in subscribers:
                while True:
                    try:
                        subscriber.queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                subscriber.queue.put_nowait(_CLOSED)
