"""Host-side TVCache tool gateway (TCP + optional Unix socket).

Pi extensions inside Docker Desktop Linux VMs cannot use a Mac-host AF_UNIX
socket (bind-mount shows the inode but connect is ECONNREFUSED). Agents RPC
over TCP to ``host.docker.internal:SYSML_TVCACHE_GATEWAY_PORT`` (default 17878).
Optional Unix listen remains for host-local smoke tests.

``SYSML_TVCACHE_DESIGN=A`` (default when ``SYSML_CACHE_MODE=parallel``): Design A
readonly path — per-call HIT / WAIT (inflight) / EXECUTE with one owner.
Mutating calls stay sequential under a per-task lock. Stock tvcache-rust only.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from tvclient.executor import TvcacheToolExecutor

from parallel_tvcache.cache.context import live_container_var, rollout_id_var, task_id_var
from parallel_tvcache.cache.harbor_docker_sandbox import HarborDockerSandbox
from parallel_tvcache.cache.inflight import InflightCoordinator
from parallel_tvcache.cache.metrics import log_metric
from parallel_tvcache.cache.pi_tool_call import PiToolCall

LOG = logging.getLogger("sysml.tvcache.gateway")


def _resolve_design() -> str:
    raw = os.environ.get("SYSML_TVCACHE_DESIGN", "").strip().upper()
    if raw:
        return raw
    if os.environ.get("SYSML_CACHE_MODE", "").strip().lower() == "parallel":
        return "A"
    return ""


def _cache_path(task_id: str, history: list[PiToolCall]) -> tuple[str, ...]:
    """Durable TCG path: task + stateful prefix + current call (same as tvclient)."""
    prev, current = history[:-1], history[-1]
    stateful = [c for c in prev if c.will_mutate_state()]
    return (task_id, *(c.serialize() for c in stateful), current.serialize())


async def _resolve_container_id(ref: str) -> str:
    """Map hostname / short id to a full Docker container id when possible."""
    if not ref:
        return ref
    proc = await asyncio.create_subprocess_exec(
        "docker",
        "inspect",
        "-f",
        "{{.Id}}",
        ref,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out_b, _ = await proc.communicate()
    if proc.returncode == 0:
        cid = out_b.decode().strip()
        if cid:
            return cid
    return ref


@dataclass
class RolloutSession:
    task_id: str
    rollout_id: str
    container_id: str
    executor: TvcacheToolExecutor
    history: list[PiToolCall] = field(default_factory=list)
    closed: bool = False
    # tvclient uses one asyncio stream per connection — serialize RPCs.
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class ToolGateway:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 7878,
        sock_path: str | None = None,
        listen_host: str = "127.0.0.1",
        listen_port: int = 17878,
        design: str | None = None,
    ):
        self.host = host
        self.port = port
        self.listen_host = listen_host
        self.listen_port = listen_port
        raw_sock = sock_path if sock_path is not None else os.environ.get("SYSML_TVCACHE_SOCK")
        self.sock_path = Path(raw_sock) if raw_sock else None
        self.design = (design if design is not None else _resolve_design()).upper()
        self._sessions: dict[tuple[str, str], RolloutSession] = {}
        self._lock = asyncio.Lock()
        # Sequential mode: serialize all cache RPCs for smoke/baseline correctness.
        self._tv_lock = asyncio.Lock()
        # Design A: cross-rollout WAIT/EXECUTE ownership for readonly keys.
        self._inflight = InflightCoordinator()
        self._mutate_locks: dict[str, asyncio.Lock] = {}
        # Container warmup: one best-effort no-op exec per container, paid
        # before the tool-wait clock so cold `docker exec` is not a miss.
        self._warmed: set[str] = set()
        self._warm_locks: dict[str, asyncio.Lock] = {}

    def _mutate_lock(self, task_id: str) -> asyncio.Lock:
        lock = self._mutate_locks.get(task_id)
        if lock is None:
            lock = asyncio.Lock()
            self._mutate_locks[task_id] = lock
        return lock

    def _warm_lock(self, container_id: str) -> asyncio.Lock:
        lock = self._warm_locks.get(container_id)
        if lock is None:
            lock = asyncio.Lock()
            self._warm_locks[container_id] = lock
        return lock

    async def get_session(
        self, task_id: str, rollout_id: str, container_id: str
    ) -> RolloutSession:
        key = (task_id, rollout_id)
        async with self._lock:
            sess = self._sessions.get(key)
            if sess and not sess.closed:
                if container_id and sess.container_id != container_id:
                    sess.container_id = container_id
                return sess
        token = live_container_var.set(container_id)
        try:
            ex = TvcacheToolExecutor(
                HarborDockerSandbox,
                PiToolCall,
                task_id,
                host=self.host,
                port=self.port,
            )
            await ex.client.connect()
            try:
                ex.set_rollout_id(rollout_id)
            except OSError as exc:
                # tvclient always mkdir("./rollouts"); tolerate read-only cwd.
                LOG.warning("set_rollout_id skipped (%s); using logger only", exc)
                ex.rollout_id = rollout_id
                ex.logger = logging.getLogger(rollout_id)
        finally:
            live_container_var.reset(token)
        sess = RolloutSession(
            task_id=task_id,
            rollout_id=rollout_id,
            container_id=container_id,
            executor=ex,
        )
        async with self._lock:
            existing = self._sessions.get(key)
            if existing and not existing.closed:
                # Lost the create race — drop the spare connection.
                try:
                    await ex.close()
                except Exception:  # noqa: BLE001
                    pass
                if container_id and existing.container_id != container_id:
                    existing.container_id = container_id
                return existing
            self._sessions[key] = sess
            return sess

    async def _lookup_sequential(
        self, sess: RolloutSession, call: PiToolCall
    ) -> tuple[str, str]:
        """Existing Exp B path: one call at a time under global + session locks."""
        async with sess.lock, self._tv_lock:
            sess.history.append(call)
            before_exec = sess.executor.total_executions
            result = await sess.executor.lookup_or_execute(list(sess.history))
            source = "hit" if sess.executor.total_executions == before_exec else "miss"
            return result, source

    async def _lookup_design_a(
        self, sess: RolloutSession, call: PiToolCall
    ) -> tuple[str, str]:
        """Design A: readonly HIT/WAIT/EXECUTE; mutating calls ordered per task."""
        if call.will_mutate_state():
            async with self._mutate_lock(sess.task_id), sess.lock:
                sess.history.append(call)
                before_exec = sess.executor.total_executions
                result = await sess.executor.lookup_or_execute(list(sess.history))
                source = (
                    "hit" if sess.executor.total_executions == before_exec else "miss"
                )
                return result, source

        async with sess.lock:
            sess.history.append(call)
            history = list(sess.history)

        key = _cache_path(sess.task_id, history)

        # Durable peek (no execute). Release lease immediately after read.
        async with sess.lock:
            found = await sess.executor.client.find(
                sess.executor.task_name,
                list(key[1:]),
            )
            async with found:
                if found.value is not None:
                    sess.executor.total_calls += 1
                    return found.value, "hit"

        leader, fut = await self._inflight.claim(key)
        if not leader:
            value = await fut
            return value, "inflight"

        try:
            async with sess.lock:
                before_exec = sess.executor.total_executions
                result = await sess.executor.lookup_or_execute(history)
                source = (
                    "hit" if sess.executor.total_executions == before_exec else "miss"
                )
            await self._inflight.complete(key, fut, result)
            return result, source
        except BaseException as exc:
            await self._inflight.fail(key, fut, exc)
            raise

    async def _warm_container(
        self, container_id: str, task_id: str, rollout_id: str
    ) -> None:
        """Pay one no-op exec per container before the tool-wait clock.

        Best-effort: a missing container, missing ``bash``, or Docker timeout
        must never block the real tool call. The warmup row is logged separately
        and is not counted as a call, hit, or miss by ``summarize_metrics``.
        """
        if not container_id or container_id in self._warmed:
            return
        async with self._warm_lock(container_id):
            if container_id in self._warmed:
                return
            workdir = os.environ.get("SYSML_TVCACHE_WORKDIR", "/home/user")
            try:
                timeout_s = float(
                    os.environ.get("SYSML_TVCACHE_WARMUP_TIMEOUT_S", "30")
                )
            except ValueError:
                timeout_s = 30.0
            t0 = time.perf_counter()
            try:
                proc = await asyncio.create_subprocess_exec(
                    "docker",
                    "exec",
                    "-w",
                    workdir,
                    container_id,
                    "bash",
                    "-lc",
                    "echo tvcache-warm",
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
                try:
                    _, err_b = await asyncio.wait_for(
                        proc.communicate(), timeout=timeout_s
                    )
                except asyncio.TimeoutError:
                    try:
                        proc.kill()
                    except ProcessLookupError:
                        pass
                    await proc.wait()
                    LOG.warning(
                        "container warmup timed out cid=%s after %.1fs",
                        container_id,
                        timeout_s,
                    )
                    return
            except Exception as exc:  # noqa: BLE001 — warmup is best-effort
                LOG.warning("container warmup failed cid=%s: %s", container_id, exc)
                return
            elapsed = time.perf_counter() - t0
            if proc.returncode != 0:
                LOG.warning(
                    "container warmup failed cid=%s rc=%s: %s",
                    container_id,
                    proc.returncode,
                    err_b.decode(errors="replace").strip(),
                )
                return
            self._warmed.add(container_id)
            log_metric(
                {
                    "event": "warmup",
                    "task_id": task_id,
                    "rollout_id": rollout_id,
                    "container_id": container_id,
                    "elapsed_s": elapsed,
                }
            )

    async def handle_tool(self, req: dict[str, Any]) -> dict[str, Any]:
        task_id = str(req.get("task_id") or "unknown-task")
        rollout_id = str(req.get("rollout_id") or "unknown-rollout")
        container_id = await _resolve_container_id(str(req.get("container_id") or ""))
        name = str(req["name"])
        arguments = dict(req.get("arguments") or {})
        call = PiToolCall(name=name, arguments=arguments)

        sess = await self.get_session(task_id, rollout_id, container_id)
        token_c = live_container_var.set(sess.container_id)
        token_t = task_id_var.set(task_id)
        token_r = rollout_id_var.set(rollout_id)
        await self._warm_container(sess.container_id, task_id, rollout_id)
        t0 = time.perf_counter()
        try:
            if self.design == "A":
                result, source = await self._lookup_design_a(sess, call)
            else:
                result, source = await self._lookup_sequential(sess, call)
            elapsed = time.perf_counter() - t0
            log_metric(
                {
                    "event": "tool",
                    "task_id": task_id,
                    "rollout_id": rollout_id,
                    "tool": name,
                    "source": source,
                    "elapsed_s": elapsed,
                    "mutates": call.will_mutate_state(),
                    "design": self.design or "sequential",
                }
            )
            return {
                "ok": True,
                "output": result,
                "source": source,
                "elapsed_s": elapsed,
            }
        except Exception as exc:  # noqa: BLE001 — surface to Pi
            LOG.exception("tool gateway failure")
            log_metric(
                {
                    "event": "tool_error",
                    "task_id": task_id,
                    "rollout_id": rollout_id,
                    "tool": name,
                    "error": str(exc),
                    "design": self.design or "sequential",
                }
            )
            return {"ok": False, "error": str(exc), "output": f"Failed to execute: {exc}"}
        finally:
            live_container_var.reset(token_c)
            task_id_var.reset(token_t)
            rollout_id_var.reset(token_r)

    async def close_rollout(self, task_id: str, rollout_id: str) -> None:
        key = (task_id, rollout_id)
        async with self._lock:
            sess = self._sessions.pop(key, None)
        if sess and not sess.closed:
            sess.closed = True
            await sess.executor.close()

    async def close_all(self) -> None:
        async with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for sess in sessions:
            if not sess.closed:
                sess.closed = True
                await sess.executor.close()


async def _handle_client(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter, gateway: ToolGateway
) -> None:
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            req = json.loads(line.decode())
            op = req.get("op", "tool")
            if op == "tool":
                resp = await gateway.handle_tool(req)
            elif op == "close":
                await gateway.close_rollout(
                    str(req.get("task_id") or ""),
                    str(req.get("rollout_id") or ""),
                )
                resp = {"ok": True}
            elif op == "ping":
                resp = {
                    "ok": True,
                    "pong": True,
                    "design": gateway.design or "sequential",
                }
            else:
                resp = {"ok": False, "error": f"unknown op {op}"}
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass


async def serve_forever(gateway: ToolGateway) -> None:
    servers: list[asyncio.AbstractServer] = []
    handler = lambda r, w: _handle_client(r, w, gateway)  # noqa: E731

    tcp = await asyncio.start_server(handler, gateway.listen_host, gateway.listen_port)
    servers.append(tcp)
    LOG.info(
        "tool gateway listening on tcp://%s:%s design=%s",
        gateway.listen_host,
        gateway.listen_port,
        gateway.design or "sequential",
    )

    if gateway.sock_path is not None:
        gateway.sock_path.parent.mkdir(parents=True, exist_ok=True)
        if gateway.sock_path.exists():
            gateway.sock_path.unlink()
        unix = await asyncio.start_unix_server(handler, path=str(gateway.sock_path))
        servers.append(unix)
        LOG.info("tool gateway listening on unix:%s", gateway.sock_path)

    stop = asyncio.Event()

    def _stop(*_args: object) -> None:
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _stop)
        except NotImplementedError:
            pass
    try:
        await stop.wait()
    finally:
        for server in servers:
            server.close()
            await server.wait_closed()
        await gateway.close_all()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    p = argparse.ArgumentParser(description="SysML TVCache tool gateway")
    p.add_argument("--host", default=os.environ.get("SYSML_TVCACHE_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("SYSML_TVCACHE_PORT", "7878")))
    p.add_argument(
        "--listen-host",
        default=os.environ.get("SYSML_TVCACHE_GATEWAY_HOST", "127.0.0.1"),
        help="TCP bind for Pi agents (Docker uses host.docker.internal)",
    )
    p.add_argument(
        "--listen-port",
        type=int,
        default=int(os.environ.get("SYSML_TVCACHE_GATEWAY_PORT", "17878")),
    )
    p.add_argument(
        "--sock",
        default=os.environ.get("SYSML_TVCACHE_SOCK", "results/tvcache/tvcache.sock"),
        help="Optional Unix socket (host-local). Empty string disables.",
    )
    args = p.parse_args()
    sock = args.sock.strip() or None
    gateway = ToolGateway(
        host=args.host,
        port=args.port,
        sock_path=sock,
        listen_host=args.listen_host,
        listen_port=args.listen_port,
    )
    asyncio.run(serve_forever(gateway))


if __name__ == "__main__":
    main()
