"""Container warmup: one no-op exec per container, outside tool timing."""

from __future__ import annotations

import asyncio
import json

import pytest

from parallel_tvcache.cache.metrics import summarize_metrics
from parallel_tvcache.cache.tool_gateway import ToolGateway


class FakeProc:
    def __init__(self, returncode: int = 0, gate: asyncio.Event | None = None):
        self.returncode = returncode
        self.gate = gate
        self.killed = False

    async def communicate(self) -> tuple[bytes, bytes]:
        if self.gate is not None:
            await self.gate.wait()
        return b"", b""

    def kill(self) -> None:
        self.killed = True

    async def wait(self) -> int:
        return self.returncode


def _patch_exec(monkeypatch, calls: list, proc_factory):
    async def fake_exec(*args, **kwargs):
        calls.append(args)
        return proc_factory()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)


@pytest.mark.asyncio
async def test_warmup_once_and_not_counted(tmp_path, monkeypatch):
    metrics = tmp_path / "m.jsonl"
    monkeypatch.setenv("SYSML_TVCACHE_METRICS", str(metrics))
    calls: list = []
    _patch_exec(monkeypatch, calls, lambda: FakeProc())

    gw = ToolGateway(design="sequential")
    await gw._warm_container("cid-1", "task", "rollout")
    await gw._warm_container("cid-1", "task", "rollout")

    assert len(calls) == 1
    rows = [json.loads(line) for line in metrics.read_text().splitlines()]
    assert [row["event"] for row in rows] == ["warmup"]
    summary = summarize_metrics(metrics)
    assert summary["calls"] == 0
    assert summary["hits"] == 0
    assert summary["misses"] == 0


@pytest.mark.asyncio
async def test_warmup_single_flight_per_container(tmp_path, monkeypatch):
    metrics = tmp_path / "m.jsonl"
    monkeypatch.setenv("SYSML_TVCACHE_METRICS", str(metrics))
    calls: list = []
    gate = asyncio.Event()
    started = asyncio.Event()

    def factory():
        started.set()
        return FakeProc(gate=gate)

    _patch_exec(monkeypatch, calls, factory)

    gw = ToolGateway(design="sequential")
    first = asyncio.create_task(gw._warm_container("cid-1", "task", "r1"))
    await started.wait()
    second = asyncio.create_task(gw._warm_container("cid-1", "task", "r2"))
    await asyncio.sleep(0)
    assert len(calls) == 1

    gate.set()
    await asyncio.gather(first, second)
    assert len(calls) == 1

    rows = [json.loads(line) for line in metrics.read_text().splitlines()]
    assert [row["event"] for row in rows] == ["warmup"]


@pytest.mark.asyncio
async def test_warmup_failure_is_best_effort(tmp_path, monkeypatch):
    metrics = tmp_path / "m.jsonl"
    monkeypatch.setenv("SYSML_TVCACHE_METRICS", str(metrics))
    calls: list = []
    _patch_exec(monkeypatch, calls, lambda: FakeProc(returncode=127))

    gw = ToolGateway(design="sequential")
    await gw._warm_container("cid-1", "task", "rollout")

    assert len(calls) == 1
    assert not metrics.exists()


@pytest.mark.asyncio
async def test_warmup_timeout_kills_process(tmp_path, monkeypatch):
    metrics = tmp_path / "m.jsonl"
    monkeypatch.setenv("SYSML_TVCACHE_METRICS", str(metrics))
    monkeypatch.setenv("SYSML_TVCACHE_WARMUP_TIMEOUT_S", "0.01")
    calls: list = []
    gate = asyncio.Event()
    proc = FakeProc(gate=gate)
    _patch_exec(monkeypatch, calls, lambda: proc)

    gw = ToolGateway(design="sequential")
    await gw._warm_container("cid-1", "task", "rollout")

    assert len(calls) == 1
    assert proc.killed
    assert not metrics.exists()
