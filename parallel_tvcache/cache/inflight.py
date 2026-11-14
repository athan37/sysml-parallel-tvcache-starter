"""Design A in-flight ownership: one EXECUTE owner, concurrent WAIT joiners.

Used by the Mac tool gateway for readonly per-call lookups. Durable storage
remains tvcache-rust ``find``/``insert``; this map only coordinates ephemeral
cross-rollout races so duplicate work is not started.
"""

from __future__ import annotations

import asyncio
from typing import Hashable, TypeVar

T = TypeVar("T")
Key = Hashable


class InflightCoordinator:
    """Claim / wait / complete map keyed like Design A cache paths."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._inflight: dict[Key, asyncio.Future[T]] = {}  # type: ignore[type-arg]

    async def claim(self, key: Key) -> tuple[bool, asyncio.Future[T]]:
        """Return ``(leader, future)``. Leader must ``complete`` or ``fail``."""
        async with self._lock:
            fut = self._inflight.get(key)
            if fut is not None:
                return False, fut  # type: ignore[return-value]
            loop = asyncio.get_running_loop()
            fut = loop.create_future()
            self._inflight[key] = fut
            return True, fut  # type: ignore[return-value]

    async def complete(self, key: Key, fut: asyncio.Future[T], value: T) -> None:
        async with self._lock:
            if self._inflight.get(key) is fut:
                del self._inflight[key]
            if not fut.done():
                fut.set_result(value)

    async def fail(self, key: Key, fut: asyncio.Future[T], exc: BaseException) -> None:
        async with self._lock:
            if self._inflight.get(key) is fut:
                del self._inflight[key]
            if not fut.done():
                fut.set_exception(exc)
                # Avoid 'Future exception was never retrieved' with no waiters.
                fut.add_done_callback(
                    lambda f: f.exception() if not f.cancelled() else None
                )

    @property
    def pending(self) -> int:
        return len(self._inflight)
