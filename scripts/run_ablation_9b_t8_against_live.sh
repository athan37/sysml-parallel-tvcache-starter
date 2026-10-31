#!/usr/bin/env bash
# Run remaining abl-9b-t8v4 Harbor trials against an already-bridged live serve.
# Expects: tunnel on SYSML_TUNNEL_LOCAL_PORT, SYSML_COMPOSE_OVERLAY set, gateway up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export OPENAI_API_KEY=EMPTY OPENAI_BASE_URL=http://127.0.0.1:18081/v1
export SYSML_MODEL_ID=Qwen/Qwen3.5-9B
export MODEL=openai/Qwen/Qwen3.5-9B
export SYSML_MAX_TURNS=8 SYSML_THINKING=off PI_VERSION=1.4.0
export SYSML_CONTEXT_WINDOW=8192 SYSML_MAX_TOKENS=2048
PREFIX="${SYSML_JOB_PREFIX:-abl-9b-t8v4}"
LOCAL_PORT="${SYSML_TUNNEL_LOCAL_PORT:-18083}"
LOG="results/characterization/ablation-9b-t8/run-batched.log"
COMPOSE="${SYSML_COMPOSE_OVERLAY:?Set SYSML_COMPOSE_OVERLAY}"
mkdir -p results/characterization/ablation-9b-t8

tasks=(
  clack-async-autocomplete-options
  httpx-streaming-json-iteration
  actionlint-action-pinning-lint
)

need=()
for task in "${tasks[@]}"; do
  for a in 1 2 3 4 5; do
    job="${PREFIX}-${task}-a${a}"
    sess=$(find "jobs/$job" -path '*/agent/pi/sessions/*.jsonl' 2>/dev/null | head -1 || true)
    if [[ -z "$sess" ]]; then
      need+=("${task}:${a}")
    fi
  done
done
echo "NEED ${#need[@]}: ${need[*]}" | tee -a "$LOG"
[[ ${#need[@]} -gt 0 ]] || { echo "Nothing to run"; exit 0; }

backend_ok() {
  python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=8)
PY
}

run_one() {
  local task="$1" attempt="$2"
  local job_name="${PREFIX}-${task}-a${attempt}"
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
    --yes | tee -a "$LOG"
  .venv/bin/python scripts/check_trial.py "jobs/$job_name" || true
}

i=0
while [[ $i -lt ${#need[@]} ]]; do
  if ! backend_ok; then
    echo "BACKEND_DEAD at i=$i remaining=${need[*]:$i} $(date -u +%H:%M:%SZ)" | tee -a "$LOG"
    exit 42
  fi
  IFS=: read -r task attempt <<<"${need[$i]}"
  echo "NEXT task=${task} attempt=${attempt}" | tee -a "$LOG"
  run_one "$task" "$attempt" || true
  i=$((i + 1))
  if ! backend_ok; then
    echo "BACKEND_DEAD after trial i=$i $(date -u +%H:%M:%SZ)" | tee -a "$LOG"
    exit 42
  fi
done
echo "DONE_ALL ${#need[@]} $(date -u +%H:%M:%SZ)" | tee -a "$LOG"
