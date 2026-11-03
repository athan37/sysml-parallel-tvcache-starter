# CS5470 SYSML — Team 39: Parallel Tool-Value Cache

Evaluate DeepSWE agents with Harbor + Pi against vLLM, then add TVCache (sequential → parallel-aware) on the tool-execute path.

## System diagram

**Agent** = **Pi** (tool-calling harness inside the agent sandbox; can emit several tool calls in one turn) **+** the LLM on NERSC (`Qwen/Qwen3.5-9B` over **OpenAI Chat Completions**).

**Harbor** (Mac host process) builds/starts the Docker sandboxes below and feeds each trial `instruction.md`. The SSH tunnel is also a Mac host process. **TVCache** (`tvcache-rust` + `tvclient` on the Mac) caches tool results by trajectory prefix; Experiment A leaves it off (`none`).

Defaults: **pass@k = Harbor concurrency = vLLM `max-num-seqs` = 5**, so five rollouts of one task share one gateway and one vLLM (continuous batching). Monitor NERSC GPU memory; on OOM lower `SYSML_HARBOR_N` / `SYSML_MAX_NUM_SEQS` or use a 4B model. `gpu_memory_utilization` defaults to **0.80** to leave KV headroom for those five sequences.

| Sandbox | Image | How many live at once |
| --- | --- | --- |
| Model gateway | `sysml-model-gateway:refactor-check` (built once) | **1** per live NERSC serve / wave (shared) |
| Agent | task `environment/Dockerfile` (Pi runs **inside** here) | **× `SYSML_HARBOR_N`** (default **5**) |
| Verifier | task `tests/Dockerfile` | **per finished trial** (same image; new container each time) |
| — | NERSC vLLM (not a Mac sandbox) | **1** serve; up to **`SYSML_MAX_NUM_SEQS`** (default **5**) sequences |

Task **count** (3 vs 10) changes how many Harbor jobs you schedule over time; gateway/vLLM stay one shared pair. Concurrent rollouts + one TVCache server (Exps B/C) is the cross-rollout reuse setting.

```mermaid
flowchart LR
  subgraph mac ["Mac"]
    H[Harbor]
    SSH[SSH tunnel]
    TV["TVCache<br/>Exps B/C"]
    subgraph sandboxes ["Docker sandboxes"]
      G["gateway ×1 shared"]
      A["agent ×n (default 5)<br/>Pi + /app"]
      V["verifier per trial"]
    end
    H --> A
    H --> V
    A -->|Chat Completions| G
    A -.->|tool results| TV
    G --> SSH
  end
  subgraph nersc ["NERSC"]
    L["vLLM ×1<br/>max-num-seqs=5"]
  end
  SSH --> L
```

## How a run works (`bash scripts/run_experiment.sh none`)

```text
run_experiment.sh none
  └─ run_harbor_wave.sh
       ├─ serve_up()     → NERSC: 1× GPU + vLLM (max-num-seqs=5)
       ├─ bridge_up()    → Mac: SSH tunnel + Chat Completions gateway container
       └─ run_task() × each needed task
            └─ harbor run -p variants/.../<task> -k 5 -n 5
                 ├─ agent image  (environment/Dockerfile) — Pi + LoopbackPi inside
                 └─ verifier image (tests/Dockerfile) — after each trial
```

| Step | Code | What it does |
| --- | --- | --- |
| Mode | `scripts/run_experiment.sh` | `none` → wave; `sequential` / `parallel` stub until TVCache is wired |
| Serve | `serve_up()` in `scripts/run_harbor_wave.sh` → `scripts/nersc_serve_model.sbatch` | `salloc --gpus-per-node=$SYSML_GPUS`, then `vllm serve --tensor-parallel-size $SYSML_TENSOR_PARALLEL_SIZE` |
| Bridge | `bridge_up()` in `scripts/run_harbor_wave.sh` | SSH forward + `sysml-model-gateway` (OpenAI Chat Completions proxy: `model.sock` → tunnel → vLLM) |
| Harbor | `run_task()` → `harbor run … -a …LoopbackPi` | Builds agent/verifier containers from the task folder; spawns up to **n** Pi agents |
| Pi | `parallel_tvcache/evaluation/loopback_pi.py` | Official Harbor Pi + in-sandbox model relay; tools stay in the agent container |
| TVCache | — | **Not started** for `none`. Exp B/C will share one Mac-side `tvcache-rust` across the concurrent rollouts |

**GPUs vs concurrency:** Five rollouts are five Chat Completions clients to one vLLM (`--max-num-seqs 5`). At **8K** context, **1×A100** is enough (cell A0). At **256K×5**, KV needs **tensor parallel** across multiple GPUs (cell A1: 4×A100, `--tensor-parallel-size 4`) — not a second replica.

**`bridge_up` in one line:** yes — it is our Mac-side Chat Completions gateway (plus the SSH tunnel). Agents never talk to NERSC directly; they hit the Unix socket → gateway → tunnel → vLLM `/v1/chat/completions`.

Key files in order: `run_experiment.sh` → `run_harbor_wave.sh` → `nersc_serve_model.sbatch` → `loopback_pi.py` → `inference/model_transport.py` → `variants/deep-swe-setup/tasks/<id>/`.

## Layout

```text
README.md                 teammate entrypoint
artifacts/
  expA-traces-A0-A2.zip   curated Pi sessions + summaries (~5 MB; not full jobs/)
docs/
  project_assignment.pdf
  workload_characterization_report.md      Exp A cells A0–A2 (one table; extend by row)
  parallel_prompt_stress_report.md         MLX forced-parallel prompt stress (not natural Exp A)
parallel_tvcache/         Harbor/Pi adapters, model transport, measurement, cache prototype
variants/                 Harbor task dirs (instruction + thin image); see below
configs/                  example.env · experiment-tasks.txt · model-gateway.Dockerfile · models/ (A0–A2 env examples)
scripts/
  setup_repositories.sh       clone vendor deps
  prepare_task.py             rebuild a task variant under variants/
  run_experiment.sh           only runner you need: mode = none|sequential|parallel|all
  run_harbor_wave.sh          NERSC + Harbor pass@k with n=k=seqs (default 5)
  nersc_serve_model.sbatch    vLLM on NERSC (reads SYSML_MAX_NUM_SEQS, etc.)
  monitor_nersc_gpu.sh        poll nvidia-smi on the live alloc (GPU memory)
  monitor_vllm_metrics.sh     poll vLLM /metrics (KV% / Running / Waiting) via tunnel
  download_qwen3_5_9b.py      optional: pull weights onto NERSC
  analyze_characterization_wave.sh   parallel-turn fraction for a job prefix
  check_trial.py              post-trial check used by the wave
  run_one.sh                  optional local smoke only (k=1 n=1; not the experiment path)
  demo_cache.py               unwired in-memory cache demo
vendor/                   deep-swe, tvcache-rust, tvclient (gitignored)
jobs/, results/           local run evidence (gitignored)
```

### What a Harbor task is

A DeepSWE task is a folder Harbor loads, mainly:

| Path | Role |
| --- | --- |
| `instruction.md` | User message Pi shows the model |
| `environment/Dockerfile` | Builds the agent sandbox image |
| `tests/` | Separate verifier image + grader (agent never sees this while solving) |
| `solution/` | Reference fix (not shown to the agent) |

At run time the agent only gets **`instruction.md` + a live container**. Harbor builds that container from the Dockerfile; it does not paste the Dockerfile, tests, or solution into the chat.

**Stock DeepSWE:** the Dockerfile already clones and installs, so `/app` is ready when the agent starts and setup never shows up as tool calls.

**Our variants** (`variants/deep-swe-setup/tasks/<id>/`): copy the official task, keep `tests/` the same, then (1) clear `/app` in the agent image and (2) prepend clone/install steps to `instruction.md`. Build more with `scripts/prepare_task.py <task_id> --setup-as-agent-actions`.

## Install

Shared by every experiment:

```bash
uv venv && source .venv/bin/activate          # create + enter Python venv
uv pip install -e '.[dev]'                    # install this package + test deps
uv tool install harbor                        # install Harbor CLI
bash scripts/setup_repositories.sh            # clone vendor/deep-swe, tvcache-rust, tvclient
cp configs/example.env .env                   # local MODEL knobs (gitignored)
python -m pytest -q                           # sanity-check unit tests

# Open the Docker Desktop app, then build the Mac-side model gateway once:
docker build -f configs/model-gateway.Dockerfile -t sysml-model-gateway:refactor-check .
```

## Project status — 2026-11-03

| Experiment | Mode flag | What we measure | Status |
| --- | --- | --- | --- |
| **A** | `none` | Reward; parallel-turn fraction; cross-rollout TCG prefix | **Done** on 9B — `docs/workload_characterization_report.md` (A0–A2). Reward 0 (tasks hard for 9B); parallel≈0; TCG overlap non-zero |
| **B** | `sequential` | Sequential TVCache hit rate / tool-wait (shared TCG across concurrent pass@k) | **Start in parallel** — stub until `tvclient` on tool path |
| **C** | `parallel` | Parallel-aware TVCache (within-turn N>1) | Wait (parallel-turn still ≈0) |

One runner; pick the mode you want (A-only, B-only, C-only, or `all`). It does **not** re-run other modes unless you pass `all`.

```bash
bash scripts/run_experiment.sh none         # Experiment A only
bash scripts/run_experiment.sh sequential   # Experiment B only (stub today)
bash scripts/run_experiment.sh parallel     # Experiment C only (stub today)
bash scripts/run_experiment.sh all          # A, then B, then C
```

### Experiment A — primary completed cell (2026-11-01)

| Item | Value |
| --- | --- |
| Tasks | **10** setup variants (`configs/experiment-tasks.txt` → `variants/deep-swe-setup/tasks/`) |
| Model / harness | `Qwen/Qwen3.5-9B` · Harbor Pi 1.4 · `LoopbackPi` |
| Budget | `max_turns=8`, thinking off, mode `none`, pass@5 |
| Concurrency | Harbor **`-k 5 -n 5`**, vLLM **`--max-num-seqs 5`**, `gpu_memory_utilization=0.80` |
| Job prefix | `char-setup-10t-k5` |
| GPU | A100-80GB · steady ~65 GiB used · **no OOM** at seqs=5 |
| Result | **0 / 199 = 0.00%** parallel · **50/50** sessions · reward **0** all trials · bash-dominated sequential turns |
| Write-up | **`docs/workload_characterization_report.md`** (all cells in one table) |
| Artifacts | `results/characterization/char-setup-10t-k5/` · `jobs/char-setup-10t-k5-*/` |

Later cells (A1 256K/TP4, A2 thinking/TP2 pilots): same report table — **reward 0**, parallel ~0, **prefer TP=2** for 9B; next capability ≈27B. Env examples under `configs/models/`.

```bash
# TP2 / thinking pilot (or pick another configs/models/*.env.example). Use YOUR pscratch root — see Reproduce.
export SYSML_NERSC_USER=<user>
export SYSML_REMOTE_ROOT=/pscratch/sd/<letter>/<user>/sysml_parallel_tvcache
export SYSML_SSH_HOST=perlmutter SYSML_SLURM_ACCOUNT=m4999
set -a && source configs/models/qwen3.5-9b-kvpack-tp2-think-high.env.example && set +a
export SYSML_TASK_PARALLEL=1   # Mac Docker: avoid 2×n=5 bind/subnet races
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
bash scripts/run_experiment.sh none   # prefer Terminal.app / screen
```

### Team status / parallel work

| Owner track | Status |
| --- | --- |
| Exp A (`none`) | Cells **A0–A2** in the report — reward 0 on 9B; Gary retries with a **stronger ~27B** tonight |
| Exp B sequential TVCache | **Start anytime** — wire `tvclient` on Pi tool-execute; use `none` A0/A1 as no-cache baseline |
| Exp C | Wait until parallel-turn > 0 on **natural** Exp A; stress surface already >0 — see `docs/parallel_prompt_stress_report.md` |

### Experiment A — historical 3-task cell (2026-10-30)

Earlier baseline **before** concurrent defaults: prefix `char-setup-9b-t8v2`, 3 tasks, Harbor `-n 1` / `max-num-seqs 1`, **0 / 55 = 0.00%** parallel. Same qualitative shape; do not conflate with `char-setup-10t-k5`.

**A0 re-run knobs:** `harbor -k 5 -n 5`, vLLM `--max-num-seqs 5`, 1 GPU, 8K (see `qwen3.5-9b-pilot.env.example`). Host **must** have `OPENAI_BASE_URL=http://127.0.0.1:18081/v1` + `OPENAI_API_KEY=EMPTY` (set inside `run_harbor_wave.sh`).

## Reproduce experiments

**Two different goals:**

| Goal | What to do |
| --- | --- |
| Re-analyze published Exp A numbers | Unzip `artifacts/expA-traces-A0-A2.zip` into this repo root → `bash scripts/analyze_characterization_wave.sh <prefix>` (see report for prefixes) |
| Re-run the same *kind* of Exp A wave | Mac **Install** above + **your own** NERSC `SYSML_REMOTE_ROOT` below (traces will not match bit-for-bit) |

**`SYSML_REMOTE_ROOT` is per teammate** — use `/pscratch/sd/<first-letter-of-user>/<user>/sysml_parallel_tvcache` (or any writable pscratch dir). Do **not** hard-code someone else’s path. Harbor/Pi stay on the Mac; only vLLM + weights live under that root.

One-time on NERSC (after MFA), from a login node with that root exported:

```bash
# on perlmutter — create YOUR root once
export SYSML_REMOTE_ROOT=/pscratch/sd/<letter>/<user>/sysml_parallel_tvcache
mkdir -p "$SYSML_REMOTE_ROOT"/{hf-cache,secrets,logs}
# venv with vLLM (name must be env-model — sbatch expects it):
#   cd "$SYSML_REMOTE_ROOT" && python -m venv env-model && source env-model/bin/activate && pip install 'vllm>=0.10' ...
# weights into $SYSML_REMOTE_ROOT/hf-cache (or run scripts/download_qwen3_5_9b.py with REMOTE_ROOT set, on a node that can reach HF)
# API key file the serve reads:
#   openssl rand -hex 24 > "$SYSML_REMOTE_ROOT/secrets/model-api-key" && chmod 600 "$SYSML_REMOTE_ROOT/secrets/model-api-key"
```

Wave will `scp` `nersc_serve_model.sbatch` into that root each run. Setup-task variants are already under `variants/deep-swe-setup/tasks/` in git.

Placeholders below are **shell env vars** — replace angle brackets, then `export`.

| Variable | Set to |
| --- | --- |
| `SYSML_NERSC_USER` | **your** NERSC username |
| `SYSML_REMOTE_ROOT` | **your** pscratch project dir (pattern above) |
| `SYSML_SSH_HOST` | usually `perlmutter` |
| `SYSML_SLURM_ACCOUNT` | `m4999` |
| `SYSML_JOB_PREFIX` | unique wave name, e.g. `char-setup-10t-k5-rerun` |
| `SYSML_TUNNEL_LOCAL_PORT` | free local port, e.g. `18086` |
| `SYSML_PASS_K` / `SYSML_HARBOR_N` / `SYSML_MAX_NUM_SEQS` | usually all **5** |
| `SYSML_MAX_MODEL_LEN` / `SYSML_CONTEXT_WINDOW` | A0 **8192**; A1/A2 **262144** |
| `SYSML_MAX_TURNS` | A0 **8**; A1 **100**; A2 pilots **250–500** |
| `SYSML_GPUS` / `SYSML_TENSOR_PARALLEL_SIZE` | A0 **1**; A1 **4**; preferred A2+ **2** |
| `SYSML_SLURM_QOS` | `shared_interactive` (1 GPU) or `interactive` (multi-GPU) |
| `SYSML_GPU_MEMORY_UTILIZATION` | A0 **0.80**; multi-GPU examples **0.90** |
| `SYSML_ATTACH_JOB` / `SYSML_ATTACH_NODE` | optional: reuse a live READY serve after a Mac runner death |

Or source a cell env: `set -a && source configs/models/<cell>.env.example && set +a`, then still export **your** `SYSML_NERSC_USER` + `SYSML_REMOTE_ROOT`.

`run_harbor_wave.sh` sets `OPENAI_API_KEY=EMPTY` and `OPENAI_BASE_URL=http://127.0.0.1:18081/v1` for Harbor Pi. **Do not omit** if you wrap `harbor run` yourself.

### 1. Connect to NERSC (MFA)

```bash
sshproxy -u <user> -f    # browser Iris / federated login + OTP
ssh perlmutter           # optional check, then exit
```

### 2. Export env + run (Mac)

```bash
export SYSML_NERSC_USER=<user>
export SYSML_REMOTE_ROOT=/pscratch/sd/<letter>/<user>/sysml_parallel_tvcache   # YOUR root
export SYSML_SSH_HOST=perlmutter
export SYSML_SLURM_ACCOUNT=m4999
# A0 baseline (or: source configs/models/qwen3.5-9b-kvpack-tp2-think-high.env.example for TP2/thinking)
export SYSML_JOB_PREFIX=char-setup-10t-k5-rerun
export SYSML_TUNNEL_LOCAL_PORT=18086
export SYSML_PASS_K=5 SYSML_HARBOR_N=5 SYSML_MAX_NUM_SEQS=5
export SYSML_GPU_MEMORY_UTILIZATION=0.80
export SYSML_TASKS_PER_ALLOC=2
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0

# Prefer Terminal.app / screen (Cursor-shell nohup can reap Harbor):
screen -dmS char10 bash scripts/run_experiment.sh none
```

When finished: `ssh perlmutter scancel -u <user> -n sysml-char-9b`

### 3. Analyze

```bash
bash scripts/analyze_characterization_wave.sh "$SYSML_JOB_PREFIX"
# → results/characterization/<prefix>/parallel_summary.json (+ gpu-monitor.log if present)
```

## References

- Handout PDF: `docs/project_assignment.pdf`
- Exp A report: `docs/workload_characterization_report.md`
- https://github.com/abhivijay96/tvcache-rust · https://github.com/abhivijay96/tvclient
- https://github.com/harbor-framework/harbor · https://github.com/earendil-works/pi · https://github.com/datacurve-ai/deep-swe
