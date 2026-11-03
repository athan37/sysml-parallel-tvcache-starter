# Experiment A — baseline workload characterization

**Cell id:** `A0` · **prefix:** `char-setup-10t-k5` · **date:** 2026-11-01 · **mode:** `none` (no TVCache)  
**Role:** baseline before longer-context / higher-turn re-runs. Sibling reports should reuse this layout.

Artifacts: `results/characterization/char-setup-10t-k5/` · `jobs/char-setup-10t-k5-*/` · reproduce: root `README.md`.

---

## Hyperparameters

| Knob | Value |
| --- | --- |
| Model | `Qwen/Qwen3.5-9B` |
| GPUs | **1** × A100-80GB (m4999, 32 CPU, 56G, `shared_interactive`) |
| `max_model_len` / Pi `contextWindow` | **8192** |
| `max_tokens` (completion) | 2048 |
| `max_turns` | **8** |
| pass@k / Harbor `-n` / vLLM `max-num-seqs` | **5 / 5 / 5** |
| `gpu_memory_utilization` | **0.80** |
| thinking | off |
| Tasks | 10 setup variants (`configs/experiment-tasks.txt`) |
| Alloc recycle | every 2 tasks (`SYSML_TASKS_PER_ALLOC=2`) |

Steady GPU after load: **~65 GiB / 80 GiB**. No OOM at these knobs.

---

## Headline metrics

| Metric | Value |
| --- | --- |
| Sessions | **50 / 50** |
| Parallel-turn fraction | **0.00** (0 / 199 turns with >1 tool call) |
| Calls/turn | 0: 50 · 1: 149 · **≥2: 0** |
| Tools | 149 calls (148 `bash`, 1 `read`) |
| Cross-rollout TCG prefix overlap | **10%** of call steps share a prefix with another rollout of the same task; mean pairwise LCP **0.13**; max shared length **1** |
| Verifier | **all 50 failed** (reward 0) |
| How trials ended | final `stopReason`: **`length` 38**, **`error` 12**, clean stop **0** |

**Read:** no within-turn multi-call. Little exact cross-rollout tool-prefix reuse (arguments diverge fast). Binding failure mode is **8K context**, not the 8-turn cap.

---

## Workload

Setup-as-agent-actions DeepSWE tasks under `variants/deep-swe-setup/tasks/`:

`clack-async-autocomplete-options`, `httpx-streaming-json-iteration`, `actionlint-action-pinning-lint`, `fastapi-deprecation-response-headers`, `bandit-incremental-cache-control`, `drizzle-orm-window-function-builders`, `ink-grid-box-layout`, `happy-dom-abort-pending-body-reads`, `go-git-worktree-merge-conflicts`, `katex-multicolumn-array-spans`

| Task | Sess | Turns | Calls | Multi |
| --- | ---: | ---: | ---: | ---: |
| clack-async-autocomplete-options | 5 | 14 | 9 | 0 |
| httpx-streaming-json-iteration | 5 | 11 | 6 | 0 |
| actionlint-action-pinning-lint | 5 | 38 | 33 | 0 |
| fastapi-deprecation-response-headers | 5 | 13 | 8 | 0 |
| bandit-incremental-cache-control | 5 | 12 | 7 | 0 |
| drizzle-orm-window-function-builders | 5 | 20 | 15 | 0 |
| ink-grid-box-layout | 5 | 29 | 24 | 0 |
| happy-dom-abort-pending-body-reads | 5 | 12 | 7 | 0 |
| go-git-worktree-merge-conflicts | 5 | 32 | 27 | 0 |
| katex-multicolumn-array-spans | 5 | 18 | 13 | 0 |

Session length: 2 turns ×16 · 3×12 · 4–7×17 · ≥8×5.

---

## Failure mode (why short traces)

Typical short path: one large setup `bash` → huge tool stdout (clone / tag deletes / install) → next decode hits context.

- `length`: truncated / empty / stub text (`Setup`, `Now`, …), often `output=1`.  
- `error`: HTTP 400 — prompt already **≥8192** input tokens.

So **`max_turns=8` was not the main limiter**; **`max_model_len=8192` was**. Raising turns alone without more context repeats the same wall.

TCG prefix metric (same-task rollouts; call = name + canonical args): fraction of tool steps whose trajectory prefix appears in ≥2 of 5 rollouts → **15/149 = 10%**. Details: `tcg_prefix_reuse.json`.

---

## Ops notes (launch only)

| Issue | Fix |
| --- | --- |
| Missing `OPENAI_BASE_URL` | set in `run_harbor_wave.sh` (`http://127.0.0.1:18081/v1`) |
| Cursor reaps Harbor | Terminal.app / `screen` |
| Mac dies, NERSC still up | `SYSML_ATTACH_JOB` + `SYSML_ATTACH_NODE` |
| Five Slurm IDs | recycle every **2 tasks** (ops); still 10×pass@5 Harbor work |

---

## Next cells

- **`A1` (completed):** [`workload_characterization_report_A1.md`](workload_characterization_report_A1.md) — 256 K / turns=100 / TP=4; reward 0; turn ceiling binding.
- **`A2` pilots (completed):** [`workload_characterization_report_A2.md`](workload_characterization_report_A2.md) — longer tokens/turns, thinking=high, TP=2; still reward 0; prefer TP=2 for later 9B waves.

---

## Artifacts

`parallel_summary.json` · `tcg_prefix_reuse.json` · `manifest.json` · `run-batched.log` · `gpu-monitor.log`
