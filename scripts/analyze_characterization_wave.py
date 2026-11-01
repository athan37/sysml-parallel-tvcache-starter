#!/usr/bin/env python3
"""Analyze parallel-turn fraction for one Harbor job-prefix wave.

Usage:
  .venv/bin/python scripts/analyze_characterization_wave.py char-setup-10t-k5
  # or: bash scripts/analyze_characterization_wave.sh char-setup-10t-k5
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "prefix",
        nargs="?",
        default=None,
        help="Job prefix, e.g. char-setup-10t-k5 (dirs jobs/<prefix>-*)",
    )
    p.add_argument(
        "--jobs-dir",
        type=Path,
        default=ROOT / "jobs",
        help="Harbor jobs root (default: ./jobs)",
    )
    p.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output JSON path (default: results/characterization/<prefix>/parallel_summary.json)",
    )
    p.add_argument("--benchmark", default="DeepSWE")
    args = p.parse_args()

    prefix = args.prefix or __import__("os").environ.get("SYSML_JOB_PREFIX") or "char-setup-10t-k5"
    jobs_dir = args.jobs_dir
    matches = sorted(d for d in jobs_dir.glob(f"{prefix}-*") if d.is_dir())
    if not matches:
        print(f"No {jobs_dir}/{prefix}-* directories found. Run characterization first.", file=sys.stderr)
        sys.exit(2)

    # analyze() walks a single root; point it at jobs_dir but only keep matching sessions
    # by analyzing each job dir and merging (same denominator as one pooled wave).
    from collections import Counter

    from parallel_tvcache.measurement.trace import _cdf, read_pi_session

    groups: Counter[int] = Counter()
    by_tool: dict[str, Counter[int]] = {}
    n_turns = n_calls = n_multi = n_sessions = 0
    for job in matches:
        for path in sorted(job.rglob("*.jsonl")):
            turns = read_pi_session(path)
            if not turns:
                continue
            n_sessions += 1
            for turn in turns:
                calls = turn["calls"]
                count = len(calls)
                n_turns += 1
                n_calls += count
                n_multi += int(count > 1)
                groups[count] += 1
                per_tool = Counter(c["tool_name"] for c in calls)
                for name, frequency in per_tool.items():
                    by_tool.setdefault(name, Counter())[frequency] += 1

    tool_characterization = {}
    for name, frequencies in sorted(by_tool.items()):
        counts = frequencies.copy()
        absent = n_turns - sum(frequencies.values())
        if absent:
            counts[0] = absent
        tool_characterization[name] = {
            "turns": n_turns,
            "turns_with_tool": sum(frequencies.values()),
            "parallel_turn_fraction": (sum(v for k, v in counts.items() if k > 1) / n_turns) if n_turns else 0.0,
            "calls_per_turn_cdf": _cdf(counts),
        }

    result = {
        "prefix": prefix,
        "job_dirs": [str(d.relative_to(ROOT)) if d.is_relative_to(ROOT) else str(d) for d in matches],
        "sessions": n_sessions,
        "turns": n_turns,
        "tool_calls": n_calls,
        "parallel_turn_fraction": (n_multi / n_turns) if n_turns else 0.0,
        "calls_per_turn_cdf": _cdf(groups) if n_turns else [],
        "tool_characterization": tool_characterization,
        "denominator": "All assistant messages, including zero-call turns. Per-tool rows count only calls of that type over the same turns.",
        "benchmark": args.benchmark,
        "note": "Parallel-turn fraction means >1 model-emitted tool call; not measured concurrent execution.",
    }
    out = args.output or (ROOT / "results" / "characterization" / prefix / "parallel_summary.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")

    multi = n_multi
    print(f"prefix={prefix}")
    print(f"job_dirs={len(matches)} sessions={n_sessions} turns={n_turns} tool_calls={n_calls}")
    print(f"parallel_turn_fraction={result['parallel_turn_fraction']:.4f} ({multi}/{n_turns})")
    print(f"wrote={out}")


if __name__ == "__main__":
    main()
