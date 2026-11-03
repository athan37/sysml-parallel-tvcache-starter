# Experiment A — post-A1 pilots (turns / thinking / TP)

**Cell id:** `A2` (pilot series, not a second 10-task sweep) · **date:** 2026-11-02 → 03 · **mode:** `none` (no TVCache)  
**Role:** size knobs after `A1` (turn ceiling + short `max_tokens`) and decide TP for later waves. Sibling of `docs/workload_characterization_report.md` (`A0`) and `docs/workload_characterization_report_A1.md` (`A1`).

Reproduce / ops: root `README.md`. Evidence under `results/characterization/<prefix>/` and `jobs/<prefix>-*/` (gitignored locally).

---

## What we ran

| Pilot | Prefix | Thinking | Turns | `max_tokens` | TP / GPUs | Harbor | Sessions | Reward>0 |
| --- | --- | --- | ---: | ---: | --- | --- | ---: | ---: |
| A2 pilot-1 | `char-pilot1-clack-t500` | off | 500 | 16384 | 4 / 4 | clack × n=5 | 5/5 | **0** |
| Think1b | `char-think1b-clack-t250` | **high** | 250 | 32768 | 4 / 4 | clack × n=5 | 5/5 | **0** |
| TP2 pack | `char-kvpack-tp2-think-high-n10` | **high** | 250 | 32768 | **2 / 2** | intended 2 tasks × n=5; **clack n=5 only** (httpx Docker-failed) | 5/5 | **0** |

Common knobs: `Qwen/Qwen3.5-9B`, `max_model_len=262144`, tool parser `qwen3_coder`, `--reasoning-parser qwen3 --language-model-only`, m4999 GPU nodes.

Env examples: `configs/models/qwen3.5-9b-a2-pilot1-t500.env.example`, `…-think-pilot1-clack.env.example`, `…-kvpack-tp2-think-high.env.example`.

---

## Headline comparison (clack-async-autocomplete-options)

| Metric | A1 (10-task, turns=100, tok=2K, think off) | pilot-1 (think off) | think1b (think high) | **TP2** (think high) |
| --- | --- | --- | --- | --- |
| Reward | 0 / 50 | 0 / 5 | 0 / 5 | **0 / 5** |
| F2P passed (avg / 82) | ~0 | ~0.2 | **~5.6** | **~7.0** |
| P2P passed (avg / 643) | (task-mixed) | ~527 | ~601 | **~603** |
| Turns (min–max) | mostly 101 | 66–194 | 106–187 | **82–121** |
| Max prompt | ~99 K | ~147 K | ~144 K | **~131 K** |
| Parallel-turn frac | 0.0008 | 0.0 | ~0 | **~0.002** |
| How trials ended | turn ceiling / stub `error` | mostly `stop` | mostly `stop` | **`stop` ×5** |

**Read:** raising turns + `max_tokens` removes the A1 turn/`max_tokens` wall on this task. **thinking=high** improves F2P but **still no reward=1**. Parallel tool emission remains ~0 → Exp C surface still tiny. Exact cross-rollout TCG reuse was already thin in A1; pilots do not revive it.

---

## Hardware / TP decision

| | TP=4 (think1b) | **TP=2 (this pilot)** |
| --- | --- | --- |
| Serve at 256 K | OK | **OK** (even on **A100-40GB ×2**, util 0.90) |
| Sampled KV use | ~3–11% of reserved pool at n=5 | **peak ~27%**, mean ~10%; Running max **6**; Waiting **0** |
| Steady GPU mem | ~74 GiB / 80 GB or ~37 GiB / 40 GB | **~37 GiB / 40 GB** on both workers |
| Decode util | often high SM% | often **100%** on one worker while decoding |

**Decision for later 9B waves:** prefer **`SYSML_GPUS=2` / `SYSML_TENSOR_PARALLEL_SIZE=2`** at 256 K — half the GPUs, higher observed KV occupancy, no serve OOM in pilot. Keep TP=4 only if you need a much larger reserved pool (e.g. true 10-way packing toward 256 K).

Mac Docker note: **2 Harbor jobs × n=5** hit bind/subnet races on this host. Safe shapes: `TASK_PARALLEL=1` + `n=5`, or `TASK_PARALLEL=2` with **n≤3** after Docker Desktop restart (address pools in `~/.docker/daemon.json`). Wave supports `SYSML_TASK_STAGGER_SEC`.

Summaries: `results/characterization/char-think1b-clack-t250/think1b_summary.json`, `…/char-kvpack-tp2-think-high-n10/tp2_pilot_summary.json`.

---

## Status (2026-11-03)

| Track | Status |
| --- | --- |
| Exp A characterization (9B) | **A0 + A1 complete**; A2 **pilots** complete — **no reward>0** on DeepSWE setup variants with Qwen3.5-9B |
| Next model (capability) | **Stronger model later** (planned: ~27 B class / Qwen3.x 27B — exact Hub id TBD when wiring) |
| Exp B sequential TVCache | **Ready for teammates to start in parallel** — wave mode `sequential` is still a stub until `tvclient` is on the Pi tool path; baseline harness/`none` replication is documented in README |
| Exp C parallel-aware TVCache | Deferred; within-turn N>1 still ~0 |

---

## Artifacts

| Prefix | Key files |
| --- | --- |
| `char-pilot1-clack-t500` | `run-batched.log`, `gpu-monitor.log`, `jobs/…` |
| `char-think1b-clack-t250` | + `think1b_summary.json` |
| `char-kvpack-tp2-think-high-n10` | + `vllm-metrics.log`, `tp2_pilot_summary.json` |

Analyze a prefix: `bash scripts/analyze_characterization_wave.sh <prefix>`.
