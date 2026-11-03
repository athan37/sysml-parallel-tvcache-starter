# Forced-parallel stress — prompt-append multi-tool emission

**STRESS only** (instruction preamble + MultitoolPi). **Do not** mix into Exp A natural-rate tables (`docs/workload_characterization_report.md`).

**Mode:** no TVCache · **Model:** `mlx-community/Qwen3-4B-Instruct-2507-4bit` (local MLX OpenAI server) · **Agent:** `MultitoolPi` (deleted after cleanup; traces kept)  
**Tasks:** stock DeepSWE Harbor corpus (`configs/experiment-tasks-deepswe-all.txt` = **113** tasks).  
**Forced-parallel intervention:** prepend “emit as many independent tool calls as possible in the same assistant turn” (target 5–10+ on explore turns).  
**Status:** full-corpus forced-parallel wave **stopped mid-run** (~41/113 attempted) after OOM / MLX instability cleanup.

Analyze: `bash scripts/analyze_characterization_wave.sh <prefix>`.

---

## Runs (summary)

| Run | Prompt append? | Prefix | Scope | Sess | Rew>0 | Parallel-turn | Max tools/turn | Notes |
| --- | --- | --- | --- | ---: | ---: | --- | ---: | --- |
| **No append (stock)** | none | `verify-mlx-4b-stock-k1` | 5 tasks × n=1 | 5/5 | — | **0.00** (0/27) | 1 | natural MLX 4B baseline |
| **Soft prefer-parallel** | soft “prefer ≥3” | `stress-mlx-parallel-1task` | katex ×1 | 1/1 | 0 | **0.083** (1/12) | 3 | light nudge only |
| **Forced parallel · 1 task** | max-parallel | `stress-mlx-maxparallel-1task` | katex ×1 | 1/1 | 0 | **0.077** (1/13) | **23** | one huge explore turn |
| **Forced parallel · 10 tasks** | max-parallel | `stress-mlx-maxparallel-10t` | 10 DeepSWE ×1 | 10/10 | 0 | **0.170** (15/88) | **23** | katex-style 23-call turn present |
| **Forced parallel · partial 113** | max-parallel | `stress-mlx-maxparallel-all113` | **41/113** attempted | **40**/41 | **0** | **0.370** (71/192) | **16** | **main run** · stopped early; 1 empty session |

Vs Exp A natural (`char-setup-10t-k5` on NERSC 9B): parallel **0/199**. Forced-parallel prompt lifts MLX 4B from **0% → ~17–37%** on this harness — still not natural DeepSWE behavior.

---

## Forced parallel · partial 113 (`stress-mlx-maxparallel-all113`)

| Field | Value |
| --- | --- |
| Attempted / corpus | **41 / 113** job dirs (through `helm-unified-manifest-stream`) |
| Sessions with traces | **40 / 41** (`fastapi-deprecation-response-headers` empty / connection-error) |
| Turns / tool calls | 192 / 588 |
| Parallel-turn fraction | **0.3698** (71/192) |
| Calls/turn mass | 0×45 · 1×76 · multi×71 (peak **16** on `fd-deterministic-multi-key-sorting` first turn) |
| Reward | **0** on graded trials (f2p≈0; 4B capability wall) |
| Budget | `max_turns=12`, Harbor `-n 1`, Docker prune + mem gate between tasks |
| Artifacts | `results/characterization/stress-mlx-maxparallel-all113/` · `jobs/stress-mlx-maxparallel-all113-*/` |

### Per task — tools per turn (same forced-parallel run)

Each row is **one task = one session**. **Tools/turn** is the sequence of tool-call counts for that session’s assistant turns (left → right = first turn → last). Example: `[16,1,1,…,0]` = first turn had 16 tools, then mostly 1, last turn 0.

| Task | Parallel turns | Frac | Max | Tools/turn |
| --- | ---: | ---: | ---: | --- |
| happy-dom-abort-pending-body-reads | 5/6 | 83.3% | 6 | `[6,5,6,5,5,0]` |
| boa-hierarchical-evaluation-cancellation | 3/4 | 75.0% | 11 | `[11,8,5,0]` |
| goreleaser-retry-publish-auditing | 3/4 | 75.0% | 10 | `[10,7,6,0]` |
| go-genai-streamed-function-args | 3/4 | 75.0% | 8 | `[8,6,5,0]` |
| helm-array-merge-strategies | 3/4 | 75.0% | 7 | `[7,5,5,0]` |
| abs-module-cache-flags | 2/3 | 66.7% | 12 | `[12,8,0]` |
| dynamodb-toolbox-conditional-attribute-requirements | 2/3 | 66.7% | 9 | `[9,5,0]` |
| actionlint-action-pinning-lint | 2/3 | 66.7% | 8 | `[8,7,0]` |
| bandit-incremental-cache-control | 2/3 | 66.7% | 8 | `[8,5,0]` |
| adaptix-name-mapping-aliases | 2/3 | 66.7% | 6 | `[6,5,0]` |
| dynamodb-toolbox-lazy-recursive-schemas | 1/2 | 50.0% | 11 | `[11,0]` |
| arcane-drift-detection-baselines | 2/4 | 50.0% | 9 | `[9,7,1,0]` |
| cliffy-config-file-parsing | 2/4 | 50.0% | 9 | `[6,9,1,0]` |
| geo-shapeindex-serialization | 2/4 | 50.0% | 9 | `[9,6,1,0]` |
| go-critic-doc-link-checker | 1/2 | 50.0% | 9 | `[9,0]` |
| anko-default-function-arguments | 2/4 | 50.0% | 8 | `[8,5,1,0]` |
| eicrud-keyset-pagination-cursor | 2/4 | 50.0% | 8 | `[8,7,1,0]` |
| expr-try-catch-errors | 2/4 | 50.0% | 8 | `[8,7,1,0]` |
| happy-dom-deterministic-intersectionobserver | 2/4 | 50.0% | 8 | `[8,6,1,0]` |
| fastapi-implicit-head-options | 2/4 | 50.0% | 7 | `[7,7,1,0]` |
| anko-typed-variable-bindings | 1/2 | 50.0% | 6 | `[6,0]` |
| arktype-json-schema-refs-dependencies | 1/2 | 50.0% | 6 | `[6,0]` |
| dasel-html-document-format | 2/4 | 50.0% | 6 | `[6,5,1,0]` |
| effect-sse-httpapi-streaming | 2/4 | 50.0% | 6 | `[6,4,1,0]` |
| gql-incremental-graphql-delivery | 2/5 | 40.0% | 9 | `[9,5,0,0,0]` |
| drizzle-orm-window-function-builders | 1/3 | 33.3% | 11 | `[11,1,0]` |
| awilix-async-container-initialization | 1/3 | 33.3% | 9 | `[9,1,0]` |
| go-git-worktree-merge-conflicts | 1/3 | 33.3% | 7 | `[7,1,0]` |
| claude-code-by-agents-recursive-delegation | 1/3 | 33.3% | 6 | `[6,1,0]` |
| bandit-interprocedural-taint-checks | 1/4 | 25.0% | 9 | `[9,1,1,0]` |
| abs-stepped-slices | 2/8 | 25.0% | 8 | `[8,6,1,1,1,1,1,0]` |
| cattrs-partial-structuring-recovery | 1/4 | 25.0% | 8 | `[8,1,1,0]` |
| bandit-structured-nosec-directives | 1/5 | 20.0% | 7 | `[7,1,1,1,0]` |
| aiomonitor-task-snapshots-diff | 2/10 | 20.0% | 6 | `[6,5,1,1,1,1,1,1,1,0]` |
| csstree-shorthand-expansion-compression | 2/10 | 20.0% | 6 | `[6,6,1,1,1,1,1,1,1,0]` |
| clack-async-autocomplete-options | 1/7 | 14.3% | 11 | `[11,1,1,1,1,1,0]` |
| etree-xml-diff-patch | 1/7 | 14.3% | 7 | `[7,1,1,0,1,0,0]` |
| fd-deterministic-multi-key-sorting | 1/11 | 9.1% | 16 | `[16,1,1,1,1,1,1,1,1,1,0]` |
| dateutil-rfc5545-timezone-interop | 1/11 | 9.1% | 9 | `[9,1,1,1,1,1,1,1,1,0,0]` |
| helm-unified-manifest-stream | 1/13 | 7.7% | 8 | `[8,1,1,1,1,1,1,1,1,1,1,1,0]` |

**Missing / empty session:** `fastapi-deprecation-response-headers`

**Not yet run:** 72 remaining tasks from `httpx-deterministic-cookie-store` … end of `experiment-tasks-deepswe-all.txt`.

---

## Takeaways

1. **Forced-parallel prompt works for fan-out:** no-append MLX 4B = 0% parallel; forced parallel ≈ **17% (10 tasks) / 37% (partial 113)**.
2. **Fan-out is front-loaded:** largest tool count is almost always the **first** turn (explore); later turns often drop to 1 call.
3. **Still not 100% parallel turns** — and should not be: dependent edits/tests stay sequential; 0-call turns remain in the denominator.
4. **Reward stays 0** on 4B — this measures **emission surface for Exp C**, not DeepSWE solve rate.
5. **Do not cite forced-parallel rates as DeepSWE characterization**; cite Exp A for natural (no-append) rates.
6. Stress runner / `MultitoolPi` / `variants/deep-swe-parallel-stress` were **removed in cleanup**; resume needs restoring those before finishing the 72 leftover tasks.

---

## Ops

| Issue | Fix |
| --- | --- |
| MLX `Connection error` / generation thread died | Hard-restart MLX; probe `/v1/chat/completions` not only `/v1/models` |
| Docker / host OOM mid-wave | Desktop RAM ≥12GB; mem gate free≥4GB; prune between tasks; `n=1` |
| Cursor reaps Harbor | Terminal.app / `screen` |
| Re-analyze only | `bash scripts/analyze_characterization_wave.sh stress-mlx-maxparallel-all113` |

---

## Notes

- Prompt text lived in the stress task `instruction.md` preamble (visible in Pi session user message). Core rule: independent reads/searches **must** share a turn.
- Forced parallel · 10 tasks peaked at **23** tools/turn (katex first explore); partial-113 peak so far is **16** (`fd-…`).
- Snapshot JSON: `results/characterization/stress-mlx-maxparallel-all113/{parallel_summary,per_task,stress_meta}.json`.
