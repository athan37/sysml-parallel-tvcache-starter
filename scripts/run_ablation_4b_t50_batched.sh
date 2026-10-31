#!/usr/bin/env bash
# Run 4B @ max_turns=50 Harbor/Pi ablation on NERSC m4999 (same harness as 9b@50).
# Must be invoked with bash (not zsh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export OPENAI_API_KEY=EMPTY OPENAI_BASE_URL=http://127.0.0.1:18081/v1
export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3-4B-Instruct-2507}"
export MODEL="openai/${SYSML_MODEL_ID}"
export SYSML_MAX_TURNS=50 SYSML_THINKING=off PI_VERSION=1.4.0
export SYSML_CONTEXT_WINDOW=8192 SYSML_MAX_TOKENS=2048
# Do not inherit a leftover 9B prefix from a prior shell export.
PREFIX="${SYSML_JOB_PREFIX:-abl-4b-t50v1}"
if [[ "$PREFIX" == *9b* ]]; then
  echo "Refusing inherited 9B PREFIX=$PREFIX; export SYSML_JOB_PREFIX=abl-4b-t50v1" >&2
  exit 2
fi
LOCAL_PORT="${SYSML_TUNNEL_LOCAL_PORT:-18085}"
BATCH="${SYSML_BATCH_SIZE:-2}"
LOG="results/characterization/ablation-4b-t50/run-batched.log"
REMOTE_ROOT=/pscratch/sd/g/gc558/sysml_parallel_tvcache
mkdir -p results/characterization/ablation-4b-t50 .local-smoke

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
echo "NEED ${#need[@]} trials: ${need[@]-}" | tee -a "$LOG"
[[ ${#need[@]} -gt 0 ]] || { echo "Nothing to run"; exit 0; }

serve_up() {
  scp -o BatchMode=yes scripts/nersc_serve_model.sbatch \
    "perlmutter:${REMOTE_ROOT}/nersc_serve_model.sbatch"
  ssh -o BatchMode=yes perlmutter 'scancel -u gc558 -n sysml-abl-4b 2>/dev/null || true'
  sleep 2
  ssh -o BatchMode=yes perlmutter "cd ${REMOTE_ROOT} && export SYSML_REMOTE_ROOT=${REMOTE_ROOT} SYSML_MODEL_ID=${SYSML_MODEL_ID} SYSML_TOOL_CALL_PARSER=hermes SYSML_GPU_MEMORY_UTILIZATION=0.85 SYSML_MAX_MODEL_LEN=8192 SYSML_MAX_NUM_SEQS=1 SYSML_VLLM_EXTRA_ARGS='' && salloc --account=m4999 --constraint=gpu --qos=shared_interactive --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-node=1 --mem=56G --time=02:00:00 --job-name=sysml-abl-4b srun --cpu-bind=none bash nersc_serve_model.sbatch" &
  SERVE_PID=$!
  for _ in $(seq 1 180); do
    # Accept only a ready.json whose job_id is currently RUNNING (ignore stale prior serves).
    READY_JSON=$(ssh -o BatchMode=yes perlmutter "jid=\$(squeue -u gc558 -n sysml-abl-4b -h -o %i | head -1); [[ -n \$jid ]] || exit 1; f=${REMOTE_ROOT}/logs/inference-\$jid/ready.json; test -f \$f && cat \$f" 2>/dev/null || true)
    if [[ -n "${READY_JSON}" ]] && echo "$READY_JSON" | grep -q "$SYSML_MODEL_ID"; then
      JOB=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['job_id'])" "$READY_JSON")
      NODE=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['host'])" "$READY_JSON")
      echo "READY job=$JOB node=$NODE model=$SYSML_MODEL_ID" | tee -a "$LOG"
      return 0
    fi
    kill -0 "$SERVE_PID" 2>/dev/null || { echo "serve ssh died"; return 1; }
    sleep 5
  done
  echo "serve timeout"; return 1
}

bridge_up() {
  local job="$1" node="$2"
  ssh -o BatchMode=yes perlmutter "cat ${REMOTE_ROOT}/secrets/model-api-key" > .local-smoke/model-api-key
  chmod 600 .local-smoke/model-api-key
  { printf 'SYSML_UPSTREAM_MODEL_API_KEY='; cat .local-smoke/model-api-key; printf '\n'; } > .local-smoke/gateway.env
  chmod 600 .local-smoke/gateway.env
  local vol="sysml-model-m4999-${job}"
  local compose=".local-smoke/m4999-${job}-compose.json"
  python3 - "$compose" "$vol" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"services":{"main":{"volumes":[{"type":"volume","source":"model-bridge","target":"/run/sysml-model","read_only":True}]}},"volumes":{"model-bridge":{"external":True,"name":sys.argv[2]}}})+"\n")
PY
  mkdir -p "results/m4999-${job}-model-records"
  docker rm -f "sysml-gateway-m4999-${job}" 2>/dev/null || true
  docker volume create "$vol" >/dev/null
  docker run --rm -v "${vol}:/bridge" alpine rm -f /bridge/model.sock
  pkill -f "ssh .* -L 127.0.0.1:${LOCAL_PORT}:" 2>/dev/null || true
  sleep 1
  ssh -f -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -N \
    -L "127.0.0.1:${LOCAL_PORT}:${node}:18080" perlmutter
  sleep 2
  python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=20)
print('TUNNEL_OK')
PY
  docker run --detach --name "sysml-gateway-m4999-${job}" \
    --add-host=host.docker.internal:host-gateway \
    --mount "type=volume,src=${vol},dst=/bridge" \
    --mount "type=bind,src=$PWD/results/m4999-${job}-model-records,dst=/records" \
    --env-file .local-smoke/gateway.env \
    sysml-model-gateway:refactor-check \
    --backend-port "$LOCAL_PORT" --model "$SYSML_MODEL_ID"
  sleep 2
  export SYSML_COMPOSE_OVERLAY="$PWD/$compose"
  echo "COMPOSE=$SYSML_COMPOSE_OVERLAY" | tee -a "$LOG"
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
    --extra-docker-compose "$SYSML_COMPOSE_OVERLAY" \
    --jobs-dir "$ROOT/jobs" \
    --job-name "$job_name" \
    --yes | tee -a "$LOG"
  .venv/bin/python scripts/check_trial.py "jobs/$job_name" || true
}

backend_ok() {
  python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=8)
PY
}

idx=0
while [[ $idx -lt ${#need[@]} ]]; do
  serve_up
  bridge_up "$JOB" "$NODE"
  batch_end=$((idx + BATCH))
  [[ $batch_end -gt ${#need[@]} ]] && batch_end=${#need[@]}
  i=$idx
  while [[ $i -lt $batch_end ]]; do
    IFS=: read -r task attempt <<<"${need[$i]}"
    echo "NEXT task=${task} attempt=${attempt}" | tee -a "$LOG"
    run_one "$task" "$attempt" || true
    i=$((i + 1))
    if ! backend_ok; then
      echo "backend dead; ending batch early at i=$i" | tee -a "$LOG"
      break
    fi
  done
  idx=$i
  ssh -o BatchMode=yes perlmutter "scancel $JOB" || true
  docker rm -f "sysml-gateway-m4999-${JOB}" 2>/dev/null || true
  pkill -f "ssh .* -L 127.0.0.1:${LOCAL_PORT}:" 2>/dev/null || true
  wait "$SERVE_PID" 2>/dev/null || true
  sleep 5
done

echo "DONE batched 4b-t50 under prefix $PREFIX" | tee -a "$LOG"
