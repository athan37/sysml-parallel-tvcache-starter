# Experiment A — longer-context workload characterization

**Cell id:** `A1` · **prefix:** `char-setup-10t-ctx256k-t100` · **date:** 2026-11-01 → 2026-11-02 · **mode:** `none` (no TVCache)  
**Role:** same 10-task pass@5 characterization as baseline `A0`, with context and turn budget large enough that setup tool output is not the binding wall. Sibling of `docs/workload_characterization_report.md` (`A0`).

Artifacts: `results/characterization/char-setup-10t-ctx256k-t100/` · `jobs/char-setup-10t-ctx256k-t100-*/` · env: `configs/models/qwen3.5-9b-a1-tp4-256k.env.example` · reproduce: root `README.md`.

Wall clock: `A1_START` 2026-11-01T23:04:19Z → `A1_END exit=0` 2026-11-02T05:04:51Z (~6 h). Five Slurm serves (recycle every 2 tasks).

---

## Hyperparameters

| Knob | Value |
| --- | --- |
| Model | `Qwen/Qwen3.5-9B` |
| GPUs | **4** × A100 (TP=`4`; mix of **40 GB** and **80 GB** nodes under `interactive` / `urgent_gp`) |
| `max_model_len` / Pi `contextWindow` | **262144** |
| `max_tokens` (completion) | 2048 |
| `max_turns` | **100** |
| pass@k / Harbor `-n` / vLLM `max-num-seqs` | **5 / 5 / 5** |
| `gpu_memory_utilization` | **0.90** |
| thinking | off |
| Tasks | same 10 setup variants as `A0` (`configs/experiment-tasks.txt`) |
| Alloc recycle | every 2 tasks (`SYSML_TASKS_PER_ALLOC=2`) |

vLLM reported KV headroom for full 256 K sequences at serve start (~14× concurrency on 40 GB nodes, ~32× on 80 GB). Steady sampled use: **~37.5 GiB / 40 GiB** or **~74 GiB / 80 GiB**. No serve OOM; no config retune mid-wave.

---

## Headline metrics

| Metric | `A0` (8 K / turns=8 / 1 GPU) | **`A1` (this cell)** |
| --- | --- | --- |
| Sessions | 50 / 50 | **50 / 50** |
| Parallel-turn fraction | 0.00 (0 / 199) | **0.0008** (4 / 4989) |
| Calls/turn | 0: 50 · 1: 149 · ≥2: 0 | 0: 50 · 1: 4935 · **≥2: 4** |
| Tools | 149 (148 bash, 1 read) | **4947** (4070 bash, 435 read, 286 edit, 154 write, …) |
| Cross-rollout TCG prefix overlap | 10% of call steps; mean LCP 0.13; max shared 1 | **0.59%** (29 / 4947); mean LCP **0.19**; max shared **3** |
| Online sequential TCG hit rate | ~6% | **~0.32%** (16 / 4947) |
| Verifier | all 50 reward 0 | **all 50 reward 0** (`exception_info=null`) |
| How trials ended | final `length` 38 / `error` 12 | final **`error` 49** / **`length` 1** (see below) |
| Max prompt tokens observed | ~8 K (hard wall) | **~99 K** (well under 256 K) |
| Session length | mostly 2–7 turns | **49 / 50 sessions = 101 turns** (hit `max_turns=100` ceiling) |

**Read:** still almost no within-turn multi-call (Exp C surface remains tiny). Cross-rollout exact tool-prefix reuse is **thinner than A0** once trajectories are long — arguments diverge after a short shared prefix. The binding limit moved from **8 K context** to the **100-turn ceiling** (and per-completion `max_tokens=2048`), not vLLM context capacity.

---

## Workload

Same setup-as-agent-actions DeepSWE tasks under `variants/deep-swe-setup/tasks/`:

`clack-async-autocomplete-options`, `httpx-streaming-json-iteration`, `actionlint-action-pinning-lint`, `fastapi-deprecation-response-headers`, `bandit-incremental-cache-control`, `drizzle-orm-window-function-builders`, `ink-grid-box-layout`, `happy-dom-abort-pending-body-reads`, `go-git-worktree-merge-conflicts`, `katex-multicolumn-array-spans`

| Task | Sess | Turns | Calls | Multi | Max input | Final stop |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| clack-async-autocomplete-options | 5 | 505 | 504 | 2 | 55435 | error×5 |
| httpx-streaming-json-iteration | 5 | 505 | 500 | 0 | 82711 | error×5 |
| actionlint-action-pinning-lint | 5 | 505 | 500 | 0 | 82663 | error×5 |
| fastapi-deprecation-response-headers | 5 | 505 | 502 | 1 | 92059 | error×5 |
| bandit-incremental-cache-control | 5 | 505 | 500 | 0 | 55462 | error×5 |
| drizzle-orm-window-function-builders | 5 | 505 | 502 | 1 | 90918 | error×5 |
| ink-grid-box-layout | 5 | 505 | 500 | 0 | 65058 | error×5 |
| happy-dom-abort-pending-body-reads | 5 | 444 | 439 | 0 | 99314 | error×4, length×1 |
| go-git-worktree-merge-conflicts | 5 | 505 | 500 | 0 | 90733 | error×5 |
| katex-multicolumn-array-spans | 5 | 505 | 500 | 0 | 80069 | error×5 |

Session length: **≥100 turns ×49** · 40 turns ×1 (`happy-dom` … ended on a `length` completion with `output=2048`).

Tool mix is no longer bash-only: agents **read / edit / write** source after setup — expected once context survives the initial clone/install dump.

---

## Failure mode (why trials still fail)

1. **Turn ceiling, not context.** 49/50 sessions run to **101** assistant messages under `max_turns=100`, then stop with an empty final assistant stub (`stopReason=error`, `input=output=0`). Harbor `exception_info=null`; reward 0. This is **budget exhaustion**, not the A0-style HTTP 400 on ≥8192 tokens.

2. **Per-completion `max_tokens=2048`.** Mid-trajectory `stopReason=length` occurs **153** times; **all** have `output=2048`. These truncate a single generation (often mid-thought / mid-tool args) but do **not** mean the 256 K window filled.

3. **Capability / task hardness.** Even with ~50–99 K prompt tokens and ~100 turns of tool use, **f2p stays 0** on every trial (reward 0). Longer context changes the **trace shape**, not the grade.

So **`max_model_len=262144` removed the A0 wall**; the new operational limiter for this cell is **`max_turns=100`** (plus occasional 2 K completion truncation). Raising context alone without more turns would not have produced these traces; raising turns alone at 8 K would have repeated A0.

TCG prefix metric (same-task rollouts; call = name + canonical args): fraction of tool steps whose trajectory prefix appears in ≥2 of 5 rollouts → **29 / 4947 = 0.59%**. Details: `tcg_prefix_reuse.json`. Long trajectories amplify early divergence, so Exp B’s exact-prefix TVCache win looks **weaker on this cell than on the short A0 traces** unless a softer key (or early-turn-only cache) is used.

---

## Ops notes (this wave)

| Issue | What happened |
| --- | --- |
| Launch durability | `screen -dmS sysml-a1` (Cursor-shell `nohup` avoided) |
| First alloc | 4×A100-**40 GB** (`60662724`); later recycles also saw **80 GB** nodes — both served 256 K×5 |
| Recycles | 5 READY serves: `60662724`, `60665883`, `60669215`, `60673982`, `60675868` |
| QOS | `interactive` (landed on `urgent_gp`) |
| Config retune | **none** — TP=4 / 256 K / k=n=seqs=5 held for the full wave |

---

## Comparison to `A0` (one paragraph)

`A0` answered “do these agents emit parallel tool calls under setup-variant DeepSWE?” with **no**, and showed traces dying on **8 K context**. `A1` keeps the parallel answer (**~0**), but shows what the workload looks like when context is not the wall: **~100-turn, bash-dominated but edit-capable** trajectories, peak prompts **≪ 256 K**, verifier still **all fail**, and **exact cross-rollout TCG prefix reuse drops** as sequences lengthen. Parallel-TVCache motivation for Exp C remains unsupported here; Exp B needs a reuse metric that survives long divergent tails (or a different task slice).

---

## Next cell `A2` (pilots completed)

Pilot series (2026-11-02 → 03) raised `max_tokens` / turns and tested **thinking=high** + **TP=2**. Still **reward 0** on clack; F2P improves with thinking; TP=2 at 256 K is preferred for later 9B serves. Full write-up: [`docs/workload_characterization_report_A2.md`](workload_characterization_report_A2.md).

Reminder: `max_tokens` ≠ context window; hitting `max_turns` ≠ “out of 256 K tokens.” Reward 0 after long traces is mostly **task hardness / model capability**.

---

## Artifacts

`parallel_summary.json` · `tcg_prefix_reuse.json` · `manifest.json` · `run-batched.log` · `gpu-monitor.log`
