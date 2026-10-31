#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export OPENAI_API_KEY=EMPTY OPENAI_BASE_URL=http://127.0.0.1:18081/v1
export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3-4B-Instruct-2507}"
export MODEL="openai/${SYSML_MODEL_ID}"
export SYSML_MAX_TURNS="${SYSML_MAX_TURNS:-50}"
export SYSML_THINKING=off PI_VERSION=1.4.0
export SYSML_CONTEXT_WINDOW=8192 SYSML_MAX_TOKENS=2048
PREFIX="${SYSML_JOB_PREFIX:?}"
LOCAL_PORT="${SYSML_TUNNEL_LOCAL_PORT:?}"
COMPOSE="${SYSML_COMPOSE_OVERLAY:?}"
LOG="results/characterization/${SYSML_WAVE_DIR:-ablation-4b-t50}/run-batched.log"
mkdir -p "$(dirname "$LOG")"
tasks=(clack-async-autocomplete-options httpx-streaming-json-iteration actionlint-action-pinning-lint)
need=()
for task in "${tasks[@]}"; do
  for a in 1 2 3 4 5; do
    job="${PREFIX}-${task}-a${a}"
    sess=$(find "jobs/$job" -path '*/agent/pi/sessions/*.jsonl' 2>/dev/null | head -1 || true)
    [[ -z "$sess" ]] && need+=("${task}:${a}")
  done
done
echo "NEED ${#need[@]}: ${need[@]-}" | tee -a "$LOG"
[[ ${#need[@]} -gt 0 ]] || { echo Nothing; exit 0; }
backend_ok() {
  python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=8)
PY
}
i=0
while [[ $i -lt ${#need[@]} ]]; do
  if ! backend_ok; then echo "BACKEND_DEAD at i=$i"; exit 42; fi
  IFS=: read -r task attempt <<<"${need[$i]}"
  job_name="${PREFIX}-${task}-a${attempt}"
  echo "=== ${job_name} $(date -u +%H:%M:%SZ) ===" | tee -a "$LOG"
  PYTHONPATH="$ROOT" harbor run \
    -p "$ROOT/vendor/deep-swe/tasks/$task" \
    -a parallel_tvcache.evaluation.loopback_pi:LoopbackPi \
    -m "$MODEL" \
    --ak "version=${PI_VERSION}" \
    --ak model_api=openai-completions \
    --ak thinking=off \
    --ak "max_turns=${SYSML_MAX_TURNS}" \
    -k 1 -n 1 \
    --env parallel_tvcache.evaluation.docker_disconnect:DockerDisconnectEnvironment \
    --extra-docker-compose "$COMPOSE" \
    --jobs-dir "$ROOT/jobs" \
    --job-name "$job_name" \
    --yes | tee -a "$LOG" || true
  .venv/bin/python scripts/check_trial.py "jobs/$job_name" || true
  i=$((i+1))
done
echo "DONE_ALL ${#need[@]}" | tee -a "$LOG"
