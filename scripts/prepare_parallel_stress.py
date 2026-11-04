#!/usr/bin/env python3
"""Build DeepSWE parallel-tool *stress* variants (NOT characterization).

Copies an existing setup-as-agent-actions task and prepends an explicit
multi-tool explore protocol so Harbor+Pi reliably emits turns with N>1
tool calls — enough surface to design/test parallel-aware TVCache
(per-call vs whole-turn vs hybrid, full/partial hits, in-flight dupes).

Does not mutate vendor/deep-swe or variants/deep-swe-setup.

  # From existing setup variants (default source):
  python scripts/prepare_parallel_stress.py katex-multicolumn-array-spans
  python scripts/prepare_parallel_stress.py --task-list configs/experiment-tasks-parallel-verify.txt --force

  # Then stress-run (local MLX):
  bash scripts/run_mlx_parallel_stress.sh
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

PARALLEL_STRESS_PREAMBLE = """\
# Parallel tool-call protocol (STRESS HARNESS — not stock DeepSWE)

This variant exists only to **maximize within-turn multi-tool emission** so we
can design and test parallel-aware TVCache. Do **not** report these parallel
rates as natural DeepSWE + Harbor Pi characterization.

**Primary objective for tool use:** emit **as many independent tool calls as
possible in the same assistant turn**. Prefer large parallel fan-outs (target
**5–10+** tool calls per explore turn) over many sequential turns with one call
each. Pack every independent read/search you can justify into one turn.

Rules:

1. **Default to parallel.** If two tool calls do not need each other's outputs,
   they MUST appear in the **same** turn. Issuing independent reads/searches
   one-per-turn is wrong for this harness.
2. **Explore turns:** each explore turn should fan out hard — multiple `read`s
   on different files **and** multiple independent `bash` searches
   (`ls`/`find`/`rg`/`grep` with different paths or patterns) together.
   Aim for the maximum number of useful independent calls you can issue at once.
3. **Mutating / dependent steps only** (writes, installs, commits, or a command
   that needs a prior result) may be sequential across turns. Everything else
   stays batched in one turn.
4. After a large parallel explore turn, you may edit/test; whenever you explore
   again, fan out again (do not drop back to one call per turn).

---

"""


def _read_task_list(path: Path) -> list[str]:
    tasks: list[str] = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            tasks.append(line)
    return tasks


def _patch_task_toml(text: str, *, task_id: str) -> str:
    text = re.sub(
        r'(?m)^(task_id\s*=\s*")[^"]*(")',
        rf"\g<1>{task_id}\g<2>",
        text,
        count=1,
    )
    # Mark variant in Harbor task name when present.
    text = re.sub(
        r'(?m)^(name\s*=\s*"datacurve/)([^"]+?)(-setup)?(")',
        rf"\g<1>\g<2>-parallel-stress\g<4>",
        text,
        count=1,
    )
    text = re.sub(
        r'(?m)^(name\s*=\s*"sysml/)([^"]+)(")',
        rf"\g<1>\g<2>-parallel-stress\g<3>",
        text,
        count=1,
    )
    # Soften description if present.
    if re.search(r'(?m)^description\s*=', text):
        text = re.sub(
            r'(?m)^(description\s*=\s*")[^"]*(")',
            r'\g<1>Parallel-tool stress variant (forced multi-tool explore; not characterization)\g<2>',
            text,
            count=1,
        )
    return text


def prepare_one(src: Path, dst: Path, *, force: bool) -> dict:
    if not (src / "task.toml").is_file():
        raise SystemExit(f"Missing task.toml: {src}")
    if not (src / "instruction.md").is_file():
        raise SystemExit(f"Missing instruction.md: {src}")
    if dst.exists():
        if not force:
            raise SystemExit(f"Will not overwrite: {dst} (pass --force)")
        shutil.rmtree(dst)

    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst)

    instruction = dst / "instruction.md"
    body = instruction.read_text()
    if "STRESS HARNESS — not stock DeepSWE" in body:
        raise SystemExit(f"Already has parallel-stress preamble: {instruction}")
    instruction.write_text(PARALLEL_STRESS_PREAMBLE + body)

    toml_path = dst / "task.toml"
    toml_path.write_text(_patch_task_toml(toml_path.read_text(), task_id=dst.name))

    manifest = {
        "kind": "parallel-tool-stress",
        "not_characterization": True,
        "source": str(src),
        "destination": str(dst),
        "preamble": "parallel multi-tool explore after setup, before edits",
        "use_with_agent": "parallel_tvcache.evaluation.multitool_pi:MultitoolPi",
        "verifier_untouched": True,
    }
    (dst / "PARALLEL_STRESS_MANIFEST.json").write_text(
        json.dumps(manifest, indent=2) + "\n"
    )
    (dst / "PARALLEL_STRESS.md").write_text(
        "Stress harness only. Forced multi-tool explore turns for parallel "
        "TVCache design. Do not mix into Exp A natural-rate tables.\n"
    )
    return manifest


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "task_ids",
        nargs="*",
        help="Task ids under --source (or use --task-list).",
    )
    p.add_argument(
        "--source",
        type=Path,
        default=Path("variants/deep-swe-setup/tasks"),
        help="Source tasks (default: setup-as-agent-actions variants).",
    )
    p.add_argument(
        "--destination",
        type=Path,
        default=Path("variants/deep-swe-parallel-stress/tasks"),
        help="Destination parent for stress variants.",
    )
    p.add_argument(
        "--task-list",
        type=Path,
        default=None,
        help="Optional file of task ids (one per line).",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Replace existing destination task dirs.",
    )
    a = p.parse_args()

    ids = list(a.task_ids)
    if a.task_list is not None:
        ids.extend(_read_task_list(a.task_list))
    # de-dupe, preserve order
    seen: set[str] = set()
    task_ids = []
    for tid in ids:
        if tid not in seen:
            seen.add(tid)
            task_ids.append(tid)
    if not task_ids:
        raise SystemExit("Provide task_ids and/or --task-list")

    summaries = []
    for tid in task_ids:
        src = a.source / tid
        dst = a.destination / tid
        summaries.append(prepare_one(src, dst, force=a.force))
        print(f"wrote {dst}")

    print(json.dumps({"count": len(summaries), "tasks": summaries}, indent=2))
    print(
        "\nNext: bash scripts/run_mlx_parallel_stress.sh\n"
        "Report parallel rates under a 'stress' label, not Exp A characterization."
    )


if __name__ == "__main__":
    main()
