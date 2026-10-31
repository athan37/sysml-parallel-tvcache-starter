#!/usr/bin/env bash
# Run characterization pilot v1: 3 DeepSWE tasks × 5 Harbor attempts.
# Preserves standard Harbor jobs/ layout (primary traces).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3.5-9B}"
HARBOR_MODEL="${MODEL:-openai/${MODEL_ID}}"
PI_VERSION="${PI_VERSION:-1.4.0}"
MAX_TURNS="${SYSML_MAX_TURNS:-50}"
THINKING="${SYSML_THINKING:-off}"
JOBS_DIR="${SYSML_JOBS_DIR:-$ROOT/jobs}"
COMPOSE="${SYSML_COMPOSE_OVERLAY:?Set SYSML_COMPOSE_OVERLAY to the per-allocation compose JSON}"
WAVE="${SYSML_WAVE_ID:-pilot-v1-qwen35-9b}"
export SYSML_MODEL_ID="$MODEL_ID"
export SYSML_CONTEXT_WINDOW="${SYSML_CONTEXT_WINDOW:-8192}"
export SYSML_MAX_TOKENS="${SYSML_MAX_TOKENS:-2048}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://127.0.0.1:18081/v1}"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
# Docker Desktop buildx under this agent environment can fail verifier
# builds with "operation not permitted" on ~/.docker/buildx/refs tmp files.
# Classic builder is enough for DeepSWE verifier Dockerfiles.
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"
export COMPOSE_DOCKER_CLI_BUILD="${COMPOSE_DOCKER_CLI_BUILD:-0}"

tasks=(
  clack-async-autocomplete-options
  httpx-streaming-json-iteration
  actionlint-action-pinning-lint
)

mkdir -p "$JOBS_DIR" "results/characterization/${WAVE}"
manifest="results/characterization/${WAVE}/manifest.json"
.venv/bin/python - "$manifest" "$MODEL_ID" "$PI_VERSION" "$THINKING" "$MAX_TURNS" "$WAVE" "$JOBS_DIR" <<'PY'
import json, sys
from pathlib import Path
manifest, model, pi, thinking, max_turns, wave, jobs_dir = sys.argv[1:]
path = Path(manifest)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
  "benchmark": "DeepSWE",
  "purpose": "model-comparison-pilot-v1",
  "model": model,
  "cache_mode": "none",
  "harness": {"harbor": "0.24.0", "pi": pi},
  "inference": {"thinking": thinking, "max_turns": int(max_turns), "temperature": 0.7, "top_p": 0.9},
  "wave": wave,
  "jobs_dir": jobs_dir,
  "attempts": [],
  "notes": "Harbor-native jobs/ trees are the primary traces. Fill attempts after runs."
}, indent=2) + "\n")
print("WROTE", path)
PY

# Prefer short --job-name prefixes (avoid Docker Desktop bind races with
# very long jobs/<wave>-<task>/<task>__suffix/... mount paths). Use k=1
# five times so each trial directory exists before compose up (matches
# the proven m4999 smoke path).
ATTEMPTS="${SYSML_ATTEMPTS:-5}"
JOB_PREFIX="${SYSML_JOB_PREFIX:-m4999-9b}"

for task in "${tasks[@]}"; do
  task_path="$ROOT/vendor/deep-swe/tasks/$task"
  [[ -d "$task_path" ]] || { echo "Missing task path: $task_path" >&2; exit 1; }
  for attempt in $(seq 1 "$ATTEMPTS"); do
    job_name="${JOB_PREFIX}-${task}-a${attempt}"
    echo "=== Harbor run $job_name (attempt ${attempt}/${ATTEMPTS}) ==="
    PYTHONPATH="$ROOT" harbor run \
      -p "$task_path" \
      -a parallel_tvcache.evaluation.loopback_pi:LoopbackPi \
      -m "$HARBOR_MODEL" \
      --ak "version=${PI_VERSION}" \
      --ak model_api=openai-completions \
      --ak "thinking=${THINKING}" \
      --ak "max_turns=${MAX_TURNS}" \
      -k 1 -n 1 \
      --env parallel_tvcache.evaluation.docker_disconnect:DockerDisconnectEnvironment \
      --extra-docker-compose "$COMPOSE" \
      --jobs-dir "$JOBS_DIR" \
      --job-name "$job_name" \
      --yes
    .venv/bin/python scripts/check_trial.py "$JOBS_DIR/$job_name" || true
  done
done

echo "Harbor trials are under $JOBS_DIR/${JOB_PREFIX}-*/"
echo "Rebuild the campaign manifest pointing at those Harbor paths, then export_characterization.py"
