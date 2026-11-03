# Experiment A — workload characterization

**Mode:** `none` (no TVCache) · **Models:** `Qwen/Qwen3.5-9B` (A0–A2) · `Qwen/Qwen3.8-27B` (A3) · **Reproduce:** root `README.md`  
**Tasks:** DeepSWE setup variants under `variants/deep-swe-setup/` (`configs/experiment-tasks.txt` = 10-task list; A3 uses 1-task pilot list).  
**How to extend:** add one row to **Cells** (+ optional one-line note under **Notes**). Published pack: `artifacts/expA-traces-A0-A2.zip` (unzip at repo root). Local full runs stay in gitignored `jobs/` / `results/`.

---

## Cells (summary)

| Cell | Prefix | Ctx / turns / tok | Think | TP×GPU | Scope | Sess | Rew>0 | Parallel-turn | Binding limit | Peak prompt | Notes |
| --- | --- | --- | --- | ---: | --- | ---: | ---: | --- | --- | --- | --- |
| **A0** | `char-setup-10t-k5` | 8K / 8 / 2K | off | 1×80GB | 10 tasks × n=5 | 50/50 | **0** | **0.00** (0/199) | **8K context** | ~8K | final `length`×38 `error`×12; TCG prefix overlap ~10% |
| **A1** | `char-setup-10t-ctx256k-t100` | 256K / 100 / 2K | off | 4 | 10×n=5 | 50/50 | **0** | **0.0008** (4/4989) | **turn ceiling** (+ mid-turn tok=2K trunc) | ~99K | mostly 101 turns; TCG overlap ~0.6%; f2p≈0 |
| **A2a** | `char-pilot1-clack-t500` | 256K / 500 / 16K | off | 4 | clack ×5 | 5/5 | **0** | ~0 | capability (clean `stop`) | ~147K | f2p≈0.2/82 |
| **A2b** | `char-think1b-clack-t250` | 256K / 250 / 32K | **high** | 4 | clack ×5 | 5/5 | **0** | ~0 | capability | ~144K | f2p≈5.6/82; KV~3–11% |
| **A2c** | `char-kvpack-tp2-think-high-n10` | 256K / 250 / 32K | **high** | **2** | clack ×5 (httpx Docker-fail) | 5/5 | **0** | ~0.002 | capability | ~131K | f2p≈7.0/82; KV peak **~27%**; prefer **TP=2** |
| **A3** | `char-qwen38-27b-clack-t250-xh` | 256K / 250 / 32K | **xhigh** | **4** | clack ×5 · **27B** | 5/5 | **0** | **0.048** (19/397) | capability | ~179K | f2p≈**48.4/82**; tools=412; 1 stream-end error (12-turn trial); invalid prior `thinking=high` wave quarantined |

Env examples: `configs/models/qwen3.5-9b-pilot.env.example` (A0) · `…-a1-tp4-256k.env.example` (A1) · `…-a2-pilot1-t500` / `…-think-pilot1-clack` / `…-kvpack-tp2-think-high` (A2*) · `…/qwen3.8-27b-pilot1-clack.env.example` (A3).

Analyze: `bash scripts/analyze_characterization_wave.sh <prefix>`.

---

## Takeaways

1. **Within-turn parallel tools** stay low on 9B (≈0); **A3 27B** shows a small but real parallel-turn fraction (~4.8%).
2. **Walls moved:** A0 = context → A1 = turns/`max_tokens` → A2* = **9B hardness** → A3 = **27B still reward=0** but much stronger partial credit.
3. **thinking=high** lifts F2P on 9B clack but **never reward=1**; on **Qwen3.8-27B** use **`xhigh`** (not `high` — vLLM 400).
4. **Serve:** 9B 256K×n=5 fits **TP=2**; **27B** pilot used **TP=4** / 256K / n=5 successfully.
5. **TCG exact-prefix reuse** drops as traces lengthen (A0 ~10% → A1 ~0.6%) → Exp B may need softer / early-turn keys.
6. **A3 capability:** avg f2p **~48/82** (vs ~7/82 on best 9B) but **reward still 0** on clack pass@5. Exp B can proceed in parallel (see README).

---

## Ops (shared)

| Issue | Fix |
| --- | --- |
| Harbor Pi base URL | `OPENAI_BASE_URL=http://127.0.0.1:18081/v1` + `OPENAI_API_KEY=EMPTY` (set in `run_harbor_wave.sh`) |
| Cursor reaps Harbor | Terminal.app / `screen`; optional `.local-smoke/*.command` |
| Mac dies, NERSC up | `SYSML_ATTACH_JOB` + `SYSML_ATTACH_NODE` |
| Mac Docker 2×n=5 | bind/subnet races → `TASK_PARALLEL=1` or n≤3; `SYSML_TASK_STAGGER_SEC` |
| Knobs | `MAX_MODEL_LEN`/`CONTEXT_WINDOW` = capacity; `MAX_TOKENS` = per completion; `MAX_TURNS` = turn ceiling |

---

## Notes (optional detail)

- **A0:** large setup `bash` → HTTP 400 / `length` at ≥8192; turns=8 not binding. Artifacts: `results/characterization/char-setup-10t-k5/`.
- **A1:** ~6 h wall; 5 Slurm recycles; 49/50 sessions hit turns=100 then stub `error`; 153× mid-turn `length` at output=2048. Artifacts: `…/char-setup-10t-ctx256k-t100/`.
- **A2c:** intended 2 Harbor tasks; only clack graded. Summary JSON: `…/char-kvpack-tp2-think-high-n10/tp2_pilot_summary.json`.
- **A3:** `Qwen/Qwen3.8-27B`, thinking=`xhigh`, ~4h wall (job `60724155`). Summary: `…/char-qwen38-27b-clack-t250-xh/pilot_summary.json`. Do not use quarantined `char-qwen38-27b-clack-t250` (`thinking=high` → turn-1 400s).
