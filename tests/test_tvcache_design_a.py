"""Design A ownership: HIT / WAIT (inflight) / EXECUTE without rust."""

from __future__ import annotations

import asyncio

import pytest

from parallel_tvcache.cache.inflight import InflightCoordinator
from parallel_tvcache.cache.metrics import summarize_metrics
from parallel_tvcache.cache.tool_gateway import _cache_path, _resolve_design
from parallel_tvcache.cache.pi_tool_call import PiToolCall


@pytest.mark.asyncio
async def test_inflight_one_owner_waiters_share_result():
    coord = InflightCoordinator()
    key = ("task", "read:A")
    started = asyncio.Event()
    release = asyncio.Event()

    async def owner() -> str:
        leader, fut = await coord.claim(key)
        assert leader
        started.set()
        await release.wait()
        await coord.complete(key, fut, "OUT-A")
        return await fut

    async def waiter() -> tuple[bool, str]:
        await started.wait()
        leader, fut = await coord.claim(key)
        assert not leader
        return leader, await fut

    owner_task = asyncio.create_task(owner())
    waiter_task = asyncio.create_task(waiter())
    await started.wait()
    assert coord.pending == 1
    release.set()
    out_owner = await owner_task
    leader_flag, out_waiter = await waiter_task
    assert out_owner == "OUT-A"
    assert out_waiter == "OUT-A"
    assert leader_flag is False
    assert coord.pending == 0


@pytest.mark.asyncio
async def test_inflight_owner_failure_propagates():
    coord = InflightCoordinator()
    key = ("task", "read:B")
    started = asyncio.Event()
    release = asyncio.Event()

    async def owner() -> None:
        leader, fut = await coord.claim(key)
        assert leader
        started.set()
        await release.wait()
        await coord.fail(key, fut, RuntimeError("boom"))
        with pytest.raises(RuntimeError, match="boom"):
            await fut

    async def waiter() -> None:
        await started.wait()
        leader, fut = await coord.claim(key)
        assert not leader
        release.set()
        with pytest.raises(RuntimeError, match="boom"):
            await fut

    await asyncio.gather(owner(), waiter())
    assert coord.pending == 0


def test_cache_path_omits_prior_reads():
    hist = [
        PiToolCall("bash", {"command": "setup"}),
        PiToolCall("read", {"path": "a.txt"}),
        PiToolCall("read", {"path": "b.txt"}),
    ]
    path = _cache_path("t1", hist)
    # Prior read omitted; key = task + mutating bash + current read(b)
    assert path[0] == "t1"
    assert "bash" in path[1] or "setup" in path[1]
    assert path[-1]  # current call serialized
    assert len(path) == 3  # task + one mutate + current


def test_resolve_design_from_parallel_mode(monkeypatch):
    monkeypatch.delenv("SYSML_TVCACHE_DESIGN", raising=False)
    monkeypatch.setenv("SYSML_CACHE_MODE", "parallel")
    assert _resolve_design() == "A"
    monkeypatch.setenv("SYSML_TVCACHE_DESIGN", "B")
    assert _resolve_design() == "B"


def test_metrics_count_inflight_as_hit(tmp_path, monkeypatch):
    path = tmp_path / "m.jsonl"
    monkeypatch.setenv("SYSML_TVCACHE_METRICS", str(path))
    from parallel_tvcache.cache.metrics import log_metric

    log_metric({"event": "tool", "source": "miss", "tool": "read", "elapsed_s": 0.40})
    log_metric({"event": "tool", "source": "inflight", "tool": "read", "elapsed_s": 0.05})
    log_metric({"event": "tool", "source": "hit", "tool": "read", "elapsed_s": 0.01})
    s = summarize_metrics(path)
    assert s["calls"] == 3
    assert s["hits"] == 2
    assert s["inflights"] == 1
    assert s["misses"] == 1
    assert abs(s["per_call_hit_rate"] - 2 / 3) < 1e-9
    assert s["tool_wait_saved_rate"] is not None
    assert s["tool_wait_saved_rate"] > 0


@pytest.mark.asyncio
async def test_gateway_design_a_wait_joins_owner(monkeypatch, tmp_path):
    """Two rollouts, same readonly key: one EXECUTE, one WAIT (no second exec)."""
    monkeypatch.setenv("SYSML_TVCACHE_METRICS", str(tmp_path / "m.jsonl"))
    monkeypatch.setenv("SYSML_TVCACHE_DESIGN", "A")

    from parallel_tvcache.cache.tool_gateway import ToolGateway, RolloutSession

    class FakeFound:
        def __init__(self, value=None):
            self.value = value
            self.sandbox_id = None
            self.sandbox_path = []

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

    class FakeClient:
        async def find(self, task_name, path):
            return FakeFound(None)

        async def connect(self):
            return None

        async def close(self):
            return None

    class FakeExecutor:
        def __init__(self):
            self.total_calls = 0
            self.total_executions = 0
            self.task_name = "task"
            self.client = FakeClient()
            self._gate = asyncio.Event()
            self._started = asyncio.Event()

        def set_rollout_id(self, _rid: str) -> None:
            return None

        async def lookup_or_execute(self, history):
            self.total_calls += 1
            self.total_executions += 1
            self._started.set()
            await self._gate.wait()
            return "SHARED"

        async def close(self):
            return None

    gw = ToolGateway(design="A", sock_path="")
    # This test is about HIT/WAIT/EXECUTE ordering, not container warmup.
    gw._warmed.update({"c1", "c2"})
    ex1, ex2 = FakeExecutor(), FakeExecutor()
    # Second rollout should not execute — share first gate so waiter can join.
    ex2.lookup_or_execute = ex1.lookup_or_execute  # type: ignore[method-assign]
    sess1 = RolloutSession("task", "r1", "c1", ex1)
    sess2 = RolloutSession("task", "r2", "c2", ex2)
    gw._sessions[("task", "r1")] = sess1
    gw._sessions[("task", "r2")] = sess2

    async def resolve_noop(ref: str) -> str:
        return ref

    monkeypatch.setattr(
        "parallel_tvcache.cache.tool_gateway._resolve_container_id", resolve_noop
    )

    async def run1():
        return await gw.handle_tool(
            {
                "task_id": "task",
                "rollout_id": "r1",
                "container_id": "c1",
                "name": "read",
                "arguments": {"path": "a.txt"},
            }
        )

    async def run2():
        await ex1._started.wait()
        return await gw.handle_tool(
            {
                "task_id": "task",
                "rollout_id": "r2",
                "container_id": "c2",
                "name": "read",
                "arguments": {"path": "a.txt"},
            }
        )

    t1 = asyncio.create_task(run1())
    t2 = asyncio.create_task(run2())
    await ex1._started.wait()
    # Give waiter time to claim as non-leader.
    await asyncio.sleep(0.02)
    ex1._gate.set()
    r1, r2 = await asyncio.gather(t1, t2)
    assert r1["ok"] and r2["ok"]
    assert r1["output"] == r2["output"] == "SHARED"
    assert r1["source"] == "miss"
    assert r2["source"] == "inflight"
    assert ex1.total_executions == 1
