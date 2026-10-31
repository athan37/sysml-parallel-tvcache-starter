# Ablation: model × max_turns (Harbor/Pi held fixed)

Goal: isolate whether low parallel % is **model**, **step budget**, or **stack** (vs teammate TVCache/MLX PDF).

## Shared constants (all arms)

| Knob | Value |
| --- | --- |
| Dataset | official DeepSWE under `vendor/deep-swe` @ `0b9fabbb63b9104d678fe965e1632f2dd9eaa2ea` (113 tasks) |
| Tasks | `clack-async-autocomplete-options`, `httpx-streaming-json-iteration`, `actionlint-action-pinning-lint` |
| Harbor | 0.24.0 |
| Pi | 1.4.0 |
| Cache | **none** |
| thinking | off |
| temperature / top_p | 0.7 / 0.9 |
| Attempts | 5 per task (`k=1` × 5) |

## Arms

| Arm id | Model | `max_turns` | Serve | Job prefix |
| --- | --- | --- | --- | --- |
| `9b-t8` | `Qwen/Qwen3.5-9B` | 8 | NERSC m4999 vLLM | `abl-9b-t8` |
| `4b-t8` | `Qwen/Qwen3-4B-Instruct` (exact id must match teammate) | 8 | local OpenAI-compatible (MLX) or NERSC | `abl-4b-t8` |
| `4b-t50` | same 4B id | 50 | same as `4b-t8` | `abl-4b-t50` |

Prior baseline (already done): `m4999-9b-v3` = 9B @ turns=50 → parallel **1.67%** (1/60).

## DeepSWE identity vs teammate PDF

Same **task id set** (113 names overlap on sampled PDF ranks including the three pilot tasks). Confirm teammate’s `git rev-parse HEAD` in their deep-swe / TA clone; if hashes differ, still same public task names but images/timeouts may differ.

Teammate PDF used **TVCache local sandbox + MLX + 1 trial × 8 steps** — not Harbor/Pi. These arms make the Harbor/Pi side of the comparison.

## Launch (after NERSC sshproxy + model serve are up)

```bash
# Example: 9B @ 8
export SYSML_COMPOSE_OVERLAY=$PWD/.local-smoke/m4999-<JOB>-compose.json
export SYSML_MODEL_ID=Qwen/Qwen3.5-9B
export MODEL=openai/Qwen/Qwen3.5-9B
export SYSML_MAX_TURNS=8
export SYSML_WAVE_ID=ablation-9b-t8
export SYSML_JOB_PREFIX=abl-9b-t8
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
bash scripts/run_pilot_v1_harbor.sh
```

Repeat with 4B model id / wave / job prefix for `abl-4b-t8` and `abl-4b-t50`.

## Placeholders (human)

- Fresh NERSC `sshproxy` cert
- `SYSML_ALLOC_NODE`, tunnel port, gateway volume, compose overlay for 9B
- Exact 4B HuggingFace / MLX model id string matching teammate
- Local MLX OpenAI listen port (if not NERSC)
- Gateway `--model` + `SYSML_MODEL_ID` + Harbor `-m` kept in sync
