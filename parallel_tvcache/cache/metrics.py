"""Append-only JSONL metrics for Exp B sequential / Exp C Design A TVCache.

``inflight`` (Design A WAIT) counts as a reuse hit for Table 2 rates.
"""

from __future__ import annotations

import json
import os
import statistics
import threading
import time
from pathlib import Path
from typing import Any, Iterable

_lock = threading.Lock()

# Misses slower than this are treated as pathological (gateway restart / hang)
# when estimating a "typical" execute cost for tool-wait saved.
_TYPICAL_MISS_MAX_S = 5.0


def metrics_path() -> Path:
    raw = os.environ.get("SYSML_TVCACHE_METRICS", "").strip()
    if raw:
        return Path(raw)
    prefix = os.environ.get("SYSML_JOB_PREFIX", "tvcache")
    return Path("results") / "characterization" / prefix / "tvcache-metrics.jsonl"


def log_metric(event: dict[str, Any]) -> None:
    path = metrics_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {"ts": time.time(), **event}
    line = json.dumps(row, sort_keys=True) + "\n"
    with _lock:
        with path.open("a", encoding="utf-8") as f:
            f.write(line)


def _tool_wait_saved(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Estimate tool-wait saved vs counterfactual where every hit costs a typical miss.

    typical_miss = median of miss ``elapsed_s`` values below ``_TYPICAL_MISS_MAX_S``
    (falls back to median of all misses). Counterfactual replaces each hit's elapsed
    with that typical cost; misses keep their measured elapsed.
    """
    timed = [
        r
        for r in rows
        if r.get("source") in ("hit", "miss", "inflight", "bypass")
        and isinstance(r.get("elapsed_s"), (int, float))
    ]
    if not timed:
        return {
            "tool_wait_actual_s": None,
            "tool_wait_counterfactual_s": None,
            "tool_wait_saved_s": None,
            "tool_wait_saved_rate": None,
            "typical_miss_s": None,
        }
    # Reuse events (hit + Design A WAIT) are replaced by typical miss in the
    # counterfactual; miss/bypass keep measured elapsed.
    reuse = ("hit", "inflight")
    miss_like = [float(r["elapsed_s"]) for r in timed if r.get("source") not in reuse]
    clean = [x for x in miss_like if x < _TYPICAL_MISS_MAX_S]
    if clean:
        typical = float(statistics.median(clean))
    elif miss_like:
        typical = float(statistics.median(miss_like))
    else:
        typical = 0.0
    actual = float(sum(float(r["elapsed_s"]) for r in timed))
    counterfactual = float(
        sum(
            typical if r.get("source") in reuse else float(r["elapsed_s"])
            for r in timed
        )
    )
    saved = counterfactual - actual
    return {
        "tool_wait_actual_s": actual,
        "tool_wait_counterfactual_s": counterfactual,
        "tool_wait_saved_s": saved,
        "tool_wait_saved_rate": (saved / counterfactual) if counterfactual > 0 else None,
        "typical_miss_s": typical,
    }


def summarize_turn_hits(job_dirs: Iterable[Path]) -> dict[str, Any]:
    """Per-turn hit rate from Pi session ``details.tvcache.source``.

    A turn = one assistant message with ≥1 toolCall, followed by its toolResults.
    Turn is a hit-turn if any result has ``source`` in ``hit`` / ``inflight``.
    """
    turns_with_tools = 0
    turns_with_hit = 0
    call_hit = call_miss = call_other = 0
    reuse = ("hit", "inflight")
    for job in job_dirs:
        if not job.is_dir():
            continue
        for session in job.rglob("*.jsonl"):
            if "sessions" not in session.parts:
                continue
            msgs: list[dict[str, Any]] = []
            for line in session.read_text(encoding="utf-8", errors="replace").splitlines():
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") == "message" and isinstance(obj.get("message"), dict):
                    msgs.append(obj["message"])
            i = 0
            while i < len(msgs):
                m = msgs[i]
                if m.get("role") != "assistant":
                    i += 1
                    continue
                n_calls = sum(
                    1
                    for c in (m.get("content") or [])
                    if isinstance(c, dict) and c.get("type") == "toolCall"
                )
                if n_calls == 0:
                    i += 1
                    continue
                j = i + 1
                sources: list[str] = []
                while j < len(msgs) and msgs[j].get("role") == "toolResult":
                    det = (msgs[j].get("details") or {}).get("tvcache") or {}
                    src = det.get("source")
                    if src in reuse:
                        call_hit += 1
                        sources.append(str(src))
                    elif src in ("miss", "bypass"):
                        call_miss += 1
                        sources.append(str(src))
                    else:
                        call_other += 1
                    j += 1
                if sources:
                    turns_with_tools += 1
                    if any(s in reuse for s in sources):
                        turns_with_hit += 1
                i = j if j > i + 1 else i + 1
    return {
        "tool_turns": turns_with_tools,
        "tool_turns_with_hit": turns_with_hit,
        "per_turn_hit_rate": (
            turns_with_hit / turns_with_tools if turns_with_tools else None
        ),
        "session_call_hits": call_hit,
        "session_call_misses": call_miss,
        "session_call_other": call_other,
    }


def summarize_metrics(
    path: Path | None = None,
    *,
    job_dirs: Iterable[Path] | None = None,
) -> dict[str, Any]:
    """Summarize Exp B metrics for handout Table 2 columns.

    Always from JSONL: per-call hit rate + tool-wait saved (needs ``elapsed_s``).
    If ``job_dirs`` given (or discoverable): per-turn hit rate from Pi sessions.
    """
    p = path or metrics_path()
    empty: dict[str, Any] = {
        "path": str(p),
        "calls": 0,
        "hits": 0,
        "misses": 0,
        "inflights": 0,
        "per_call_hit_rate": None,
        "per_turn_hit_rate": None,
        "tool_turns": 0,
        "tool_turns_with_hit": 0,
        "tool_wait_actual_s": None,
        "tool_wait_counterfactual_s": None,
        "tool_wait_saved_s": None,
        "tool_wait_saved_rate": None,
        "typical_miss_s": None,
    }
    if not p.exists():
        return empty

    rows: list[dict[str, Any]] = []
    hits = misses = inflights = 0
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        rows.append(row)
        src = row.get("source")
        if src == "hit":
            hits += 1
        elif src == "inflight":
            inflights += 1
            hits += 1  # Design A WAIT = reuse
        elif src in ("miss", "bypass"):
            misses += 1
    total = hits + misses
    out: dict[str, Any] = {
        "path": str(p),
        "calls": total,
        "hits": hits,
        "misses": misses,
        "inflights": inflights,
        "per_call_hit_rate": (hits / total) if total else None,
    }
    out.update(_tool_wait_saved([r for r in rows if r.get("event") == "tool"]))

    dirs = list(job_dirs) if job_dirs is not None else []
    if dirs:
        out.update(summarize_turn_hits(dirs))
    else:
        out.setdefault("per_turn_hit_rate", None)
        out.setdefault("tool_turns", 0)
        out.setdefault("tool_turns_with_hit", 0)
    return out


def discover_job_dirs(metrics_file: Path, jobs_root: Path | None = None) -> list[Path]:
    """Find ``jobs/<prefix>-*`` dirs for a wave metrics file under results/characterization/<prefix>/."""
    root = jobs_root or Path("jobs")
    try:
        # .../results/characterization/<prefix>/tvcache-metrics.jsonl
        prefix = metrics_file.resolve().parent.name
    except OSError:
        return []
    if not root.is_dir() or not prefix:
        return []
    return sorted(p for p in root.glob(f"{prefix}-*") if p.is_dir())
