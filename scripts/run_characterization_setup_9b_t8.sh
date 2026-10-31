#!/usr/bin/env bash
# Handout-faithful characterization: setup-as-agent-actions variants × pass@5,
# Qwen3.5-9B @ max_turns=8, cache_mode=none.
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
PREFIX="${SYSML_JOB_PREFIX:-char-setup-9b-t8v2}"
LOCAL_PORT="${SYSML_TUNNEL_LOCAL_PORT:-18086}"
BATCH="${SYSML_BATCH_SIZE:-2}"
TASK_ROOT="${SYSML_TASK_ROOT:-$ROOT/variants/deep-swe-setup/tasks}"
WAVE_DIR="results/characterization/setup-pilot-9b-t8"
LOG="$WAVE_DIR/run-batched.log"
# Setup variants need clone/install egress; LoopbackPi still serves the model via socket.
export SYSML_ALLOW_AGENT_EGRESS=1
mkdir -p "$WAVE_DIR" .local-smoke

tasks=(
  clack-async-autocomplete-options
  httpx-streaming-json-iteration
  actionlint-action-pinning-lint
)

for task in "${tasks[@]}"; do
  [[ -f "$TASK_ROOT/$task/task.toml" ]] || {
    echo "Missing setup variant: $TASK_ROOT/$task (run scripts/prepare_task.py --setup-as-agent-actions)" >&2
    exit 2
  }
done

need=()
for task in "${tasks[@]}"; do
  for a in 1 2 3 4 5; do
    job="${PREFIX}-${task}-a${a}"
    sess=$(find "jobs/$job" -path '*/agent/pi/sessions/*.jsonl' 2>/dev/null | head -1 || true)
    if [[ -z "$sess" ]]; then
      need+=("$task:$a")
    fi
  done
done
echo "NEED ${#need[@]} trials: ${need[*]}" | tee -a "$LOG"
[[ ${#need[@]} -gt 0 ]] || { echo "Nothing to run"; exit 0; }

cat > "$WAVE_DIR/manifest.json" <<EOF
{
  "purpose": "characterization-setup-as-agent-actions-pilot-v1",
  "cache_mode": "none",
  "model": "Qwen/Qwen3.5-9B",
  "max_turns": 8,
  "thinking": "off",
  "k": 5,
  "task_root": "$TASK_ROOT",
  "job_prefix": "$PREFIX",
  "tasks": ["clack-async-autocomplete-options","httpx-streaming-json-iteration","actionlint-action-pinning-lint"],
  "note": "Handout DeepSWE cell: agent performs clone/build. Prior abl-9b-t8 on stock images is not this cell."
}
EOF

serve_up() {
  scp -o BatchMode=yes scripts/nersc_serve_model.sbatch \
    perlmutter:/pscratch/sd/g/gc558/sysml_parallel_tvcache/nersc_serve_model.sbatch
  ssh -o BatchMode=yes perlmutter 'scancel -u gc558 -n sysml-abl-9b 2>/dev/null || true; scancel -u gc558 -n sysml-char-9b 2>/dev/null || true; scancel -u gc558 -n sysml-inf-9b 2>/dev/null || true'
  sleep 3
  # Record existing inference log dirs so we only accept a *new* ready.json.
  OLD_LOGS=$(ssh -o BatchMode=yes perlmutter 'ls -dt /pscratch/sd/g/gc558/sysml_parallel_tvcache/logs/inference-* 2>/dev/null | head -5' || true)
  ssh -o BatchMode=yes perlmutter 'cd /pscratch/sd/g/gc558/sysml_parallel_tvcache && export SYSML_REMOTE_ROOT=/pscratch/sd/g/gc558/sysml_parallel_tvcache SYSML_MODEL_ID=Qwen/Qwen3.5-9B SYSML_TOOL_CALL_PARSER=qwen3_coder SYSML_GPU_MEMORY_UTILIZATION=0.85 SYSML_MAX_MODEL_LEN=8192 SYSML_MAX_NUM_SEQS=1 SYSML_VLLM_EXTRA_ARGS="--reasoning-parser qwen3 --language-model-only" && salloc --account=m4999 --constraint=gpu --qos=shared_interactive --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-node=1 --mem=56G --time=00:45:00 --job-name=sysml-char-9b srun --cpu-bind=none bash nersc_serve_model.sbatch' &
  SERVE_PID=$!
  for i in $(seq 1 180); do
    # Prefer the Slurm job named sysml-char-9b once it exists.
    JID=$(ssh -o BatchMode=yes perlmutter 'squeue -u gc558 -n sysml-char-9b -h -o %i | head -1' 2>/dev/null || true)
    if [[ -n "$JID" ]]; then
      READY_PATH="/pscratch/sd/g/gc558/sysml_parallel_tvcache/logs/inference-${JID}/ready.json"
      if ssh -o BatchMode=yes perlmutter "test -f $READY_PATH" 2>/dev/null; then
        READY=$(ssh -o BatchMode=yes perlmutter "cat $READY_PATH")
        JOB=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['job_id'])" "$READY")
        NODE=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['host'])" "$READY")
        echo "READY job=$JOB node=$NODE path=$READY_PATH" | tee -a "$LOG"
        return 0
      fi
    fi
    kill -0 "$SERVE_PID" 2>/dev/null || { echo "serve ssh died"; return 1; }
    sleep 5
  done
  echo "serve timeout"; return 1
}

bridge_up() {
  local job="$1" node="$2"
  ssh -o BatchMode=yes perlmutter 'cat /pscratch/sd/g/gc558/sysml_parallel_tvcache/secrets/model-api-key' > .local-smoke/model-api-key
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
    --backend-port "$LOCAL_PORT" --model Qwen/Qwen3.5-9B
  sleep 2
  export SYSML_COMPOSE_OVERLAY="$PWD/$compose"
  echo "COMPOSE=$SYSML_COMPOSE_OVERLAY" | tee -a "$LOG"
}

run_one() {
  local task="$1" attempt="$2"
  local job_name="${PREFIX}-${task}-a${attempt}"
  echo "=== $job_name ===" | tee -a "$LOG"
  PYTHONPATH="$ROOT" harbor run \
    -p "$TASK_ROOT/$task" \
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

idx=0
while [[ $idx -lt ${#need[@]} ]]; do
  serve_up
  bridge_up "$JOB" "$NODE"
  batch_end=$((idx + BATCH))
  [[ $batch_end -gt ${#need[@]} ]] && batch_end=${#need[@]}
  i=$idx
  while [[ $i -lt $batch_end ]]; do
    IFS=: read -r task attempt <<<"${need[$i]}"
    run_one "$task" "$attempt" || true
    i=$((i + 1))
    if ! python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=8)
PY
    then
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

echo "DONE setup-char 9b-t8 under prefix $PREFIX" | tee -a "$LOG"
