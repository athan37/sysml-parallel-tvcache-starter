#!/usr/bin/env bash
# Shared Harbor + NERSC wave (setup variants × pass@k with concurrency n).
# Called by run_experiment.sh. Reads SYSML_CACHE_MODE (only "none" wired today).
#
# Defaults match pass@k with concurrent rollouts (TVCache-friendly):
#   SYSML_PASS_K=5  SYSML_HARBOR_N=5  SYSML_MAX_NUM_SEQS=5
# Task ids: configs/experiment-tasks.txt (override with SYSML_TASK_LIST).
# Override downward if GPU OOM or Docker Desktop bind races.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export OPENAI_API_KEY=EMPTY OPENAI_BASE_URL=http://127.0.0.1:18081/v1
export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3.5-9B}"
export MODEL="${MODEL:-openai/${SYSML_MODEL_ID}}"
export SYSML_MAX_TURNS="${SYSML_MAX_TURNS:-8}" SYSML_THINKING=off PI_VERSION="${PI_VERSION:-1.4.0}"
export SYSML_CONTEXT_WINDOW="${SYSML_CONTEXT_WINDOW:-8192}" SYSML_MAX_TOKENS="${SYSML_MAX_TOKENS:-2048}"
CACHE_MODE="${SYSML_CACHE_MODE:-none}"
PREFIX="${SYSML_JOB_PREFIX:-char-setup-10t-k5}"
LOCAL_PORT="${SYSML_TUNNEL_LOCAL_PORT:-18086}"
K="${SYSML_PASS_K:-5}"
N="${SYSML_HARBOR_N:-$K}"
MAX_NUM_SEQS="${SYSML_MAX_NUM_SEQS:-$K}"
GPU_MEM="${SYSML_GPU_MEMORY_UTILIZATION:-0.80}"
MAX_LEN="${SYSML_MAX_MODEL_LEN:-8192}"
# QOS MaxWall is 4h on shared_interactive; recycle before expiry via TASKS_PER_ALLOC.
ALLOC_TIME="${SYSML_ALLOC_TIME:-04:00:00}"
TASKS_PER_ALLOC="${SYSML_TASKS_PER_ALLOC:-2}"
TASK_ROOT="${SYSML_TASK_ROOT:-$ROOT/variants/deep-swe-setup/tasks}"
TASK_LIST="${SYSML_TASK_LIST:-$ROOT/configs/experiment-tasks.txt}"
WAVE_DIR="results/characterization/${PREFIX}"
LOG="$WAVE_DIR/run-batched.log"
REMOTE_ROOT="${SYSML_REMOTE_ROOT:?Set SYSML_REMOTE_ROOT (e.g. /pscratch/sd/<letter>/<user>/sysml_parallel_tvcache)}"
NERSC_USER="${SYSML_NERSC_USER:?Set SYSML_NERSC_USER}"
SSH_HOST="${SYSML_SSH_HOST:-perlmutter}"
SLURM_ACCOUNT="${SYSML_SLURM_ACCOUNT:-m4999}"
export SYSML_ALLOW_AGENT_EGRESS=1
mkdir -p "$WAVE_DIR" .local-smoke

load_tasks() {
  local line
  tasks=()
  [[ -f "$TASK_LIST" ]] || { echo "Missing task list: $TASK_LIST" >&2; exit 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue
    tasks+=("$line")
  done < "$TASK_LIST"
  [[ ${#tasks[@]} -gt 0 ]] || { echo "Empty task list: $TASK_LIST" >&2; exit 2; }
}

load_tasks
echo "PREFIX=$PREFIX K=$K N=$N MAX_NUM_SEQS=$MAX_NUM_SEQS GPU_MEM=$GPU_MEM MODE=$CACHE_MODE tasks=${#tasks[@]} per_alloc=$TASKS_PER_ALLOC" | tee -a "$LOG"
echo "REMOTE_ROOT=$REMOTE_ROOT NERSC_USER=$NERSC_USER SSH_HOST=$SSH_HOST ACCOUNT=$SLURM_ACCOUNT TASK_LIST=$TASK_LIST" | tee -a "$LOG"

for task in "${tasks[@]}"; do
  [[ -f "$TASK_ROOT/$task/task.toml" ]] || {
    echo "Missing setup variant: $TASK_ROOT/$task (run scripts/prepare_task.py --setup-as-agent-actions)" >&2
    exit 2
  }
done

session_count() {
  local job="$1"
  # Missing job dir must not trip set -o pipefail (find exits 1).
  if [[ ! -d "jobs/$job" ]]; then
    echo 0
    return 0
  fi
  find "jobs/$job" -path '*/agent/pi/sessions/*.jsonl' 2>/dev/null | wc -l | tr -d ' ' || echo 0
}

need=()
for task in "${tasks[@]}"; do
  job="${PREFIX}-${task}"
  have=$(session_count "$job")
  if [[ "$have" -eq 0 ]]; then
    have=0
    for a in $(seq 1 "$K"); do
      c=$(session_count "${PREFIX}-${task}-a${a}")
      have=$((have + c))
    done
  fi
  if [[ "$have" -lt "$K" ]]; then
    need+=("$task")
  fi
done
echo "NEED ${#need[@]} tasks (want ${K} sessions each): ${need[*]:-}" | tee -a "$LOG"
[[ ${#need[@]} -gt 0 ]] || { echo "Nothing to run"; exit 0; }

python3 - "$WAVE_DIR/manifest.json" "$CACHE_MODE" "$SYSML_MODEL_ID" "$SYSML_MAX_TURNS" "$K" "$N" "$MAX_NUM_SEQS" "$TASK_ROOT" "$PREFIX" "${tasks[@]}" <<'PY'
import json, sys
from pathlib import Path
path, cache, model, turns, k, n, seqs, task_root, prefix = sys.argv[1:10]
tasks = sys.argv[10:]
Path(path).write_text(json.dumps({
    "purpose": "deep-swe-setup-variants-10task",
    "cache_mode": cache,
    "model": model,
    "max_turns": int(turns),
    "thinking": "off",
    "k": int(k),
    "n": int(n),
    "max_num_seqs": int(seqs),
    "task_root": task_root,
    "job_prefix": prefix,
    "tasks": tasks,
}, indent=2) + "\n")
PY

GPU_MON_PID=""
stop_gpu_mon() {
  if [[ -n "${GPU_MON_PID:-}" ]] && kill -0 "$GPU_MON_PID" 2>/dev/null; then
    kill "$GPU_MON_PID" 2>/dev/null || true
    wait "$GPU_MON_PID" 2>/dev/null || true
  fi
  GPU_MON_PID=""
}

serve_up() {
  scp -o BatchMode=yes scripts/nersc_serve_model.sbatch \
    "${SSH_HOST}:${REMOTE_ROOT}/nersc_serve_model.sbatch"
  ssh -o BatchMode=yes "$SSH_HOST" "scancel -u ${NERSC_USER} -n sysml-abl-9b 2>/dev/null || true; scancel -u ${NERSC_USER} -n sysml-char-9b 2>/dev/null || true; scancel -u ${NERSC_USER} -n sysml-inf-9b 2>/dev/null || true"
  sleep 3
  ssh -o BatchMode=yes "$SSH_HOST" "cd '${REMOTE_ROOT}' && export SYSML_REMOTE_ROOT='${REMOTE_ROOT}' SYSML_MODEL_ID='${SYSML_MODEL_ID}' SYSML_TOOL_CALL_PARSER=qwen3_coder SYSML_GPU_MEMORY_UTILIZATION='${GPU_MEM}' SYSML_MAX_MODEL_LEN='${MAX_LEN}' SYSML_MAX_NUM_SEQS='${MAX_NUM_SEQS}' SYSML_VLLM_EXTRA_ARGS='--reasoning-parser qwen3 --language-model-only' && salloc --account=${SLURM_ACCOUNT} --constraint=gpu --qos=shared_interactive --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-node=1 --mem=56G --time=${ALLOC_TIME} --job-name=sysml-char-9b srun --cpu-bind=none bash nersc_serve_model.sbatch" &
  SERVE_PID=$!
  for i in $(seq 1 180); do
    JID=$(ssh -o BatchMode=yes "$SSH_HOST" "squeue -u ${NERSC_USER} -n sysml-char-9b -h -o %i | head -1" 2>/dev/null || true)
    if [[ -n "$JID" ]]; then
      READY_PATH="${REMOTE_ROOT}/logs/inference-${JID}/ready.json"
      if ssh -o BatchMode=yes "$SSH_HOST" "test -f '${READY_PATH}'" 2>/dev/null; then
        READY=$(ssh -o BatchMode=yes "$SSH_HOST" "cat '${READY_PATH}'")
        JOB=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['job_id'])" "$READY")
        NODE=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['host'])" "$READY")
        echo "READY job=$JOB node=$NODE max_num_seqs=$MAX_NUM_SEQS path=$READY_PATH" | tee -a "$LOG"
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
  ssh -o BatchMode=yes "$SSH_HOST" "cat '${REMOTE_ROOT}/secrets/model-api-key'" > .local-smoke/model-api-key
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
    -L "127.0.0.1:${LOCAL_PORT}:${node}:18080" "$SSH_HOST"
  sleep 2
  python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=20)
print('TUNNEL_OK')
PY
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx 'sysml-model-gateway:refactor-check' || {
    echo "Missing image sysml-model-gateway:refactor-check — build it first (see README Install)." >&2
    exit 2
  }
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

teardown_serve() {
  stop_gpu_mon
  ssh -o BatchMode=yes "$SSH_HOST" "scancel ${JOB:-}" 2>/dev/null || true
  docker rm -f "sysml-gateway-m4999-${JOB:-}" 2>/dev/null || true
  pkill -f "ssh .* -L 127.0.0.1:${LOCAL_PORT}:" 2>/dev/null || true
  wait "${SERVE_PID:-}" 2>/dev/null || true
}

backend_ok() {
  python3 - <<PY
import urllib.request
from pathlib import Path
k=Path('.local-smoke/model-api-key').read_text().strip()
urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:${LOCAL_PORT}/v1/models',headers={'Authorization':'Bearer '+k}),timeout=8)
PY
}

run_task() {
  local task="$1"
  local job_name="${PREFIX}-${task}"
  echo "=== $job_name  (k=$K n=$N) ===" | tee -a "$LOG"
  PYTHONPATH="$ROOT" harbor run \
    -p "$TASK_ROOT/$task" \
    -a parallel_tvcache.evaluation.loopback_pi:LoopbackPi \
    -m "$MODEL" \
    --ak "version=${PI_VERSION}" \
    --ak model_api=openai-completions \
    --ak thinking=off \
    --ak "max_turns=${SYSML_MAX_TURNS}" \
    -k "$K" -n "$N" \
    --env parallel_tvcache.evaluation.docker_disconnect:DockerDisconnectEnvironment \
    --extra-docker-compose "$SYSML_COMPOSE_OVERLAY" \
    --jobs-dir "$ROOT/jobs" \
    --job-name "$job_name" \
    --yes | tee -a "$LOG"
  .venv/bin/python scripts/check_trial.py "jobs/$job_name" || true
}

ensure_serve() {
  if [[ -n "${JOB:-}" ]] && backend_ok; then
    return 0
  fi
  echo "starting/restarting serve" | tee -a "$LOG"
  teardown_serve || true
  serve_up
  bridge_up "$JOB" "$NODE"
  stop_gpu_mon
  # --background writes only to gpu-monitor.log (no double-tee / redirect dup).
  GPU_MON_PID=$(
    SYSML_JOB_PREFIX="$PREFIX" SYSML_SSH_HOST="$SSH_HOST" SYSML_NERSC_USER="$NERSC_USER" \
      bash scripts/monitor_nersc_gpu.sh --background \
      | sed -n 's/^started pid=\([0-9][0-9]*\).*/\1/p' | head -1
  )
  if [[ -z "${GPU_MON_PID:-}" ]]; then
    GPU_MON_PID=$(pgrep -n -f 'scripts/monitor_nersc_gpu.sh' || true)
  fi
  echo "gpu-monitor pid=${GPU_MON_PID:-unknown}" | tee -a "$LOG"
}

# Attach to a live NERSC serve (must run after bridge_up/backend_ok exist).
# Example: SYSML_ATTACH_JOB=60652823 SYSML_ATTACH_NODE=nid200265 bash scripts/run_harbor_wave.sh
# On attach failure, do not scancel the live job.
if [[ -n "${SYSML_ATTACH_JOB:-}" ]]; then
  JOB="${SYSML_ATTACH_JOB}"
  NODE="${SYSML_ATTACH_NODE:?Set SYSML_ATTACH_NODE with SYSML_ATTACH_JOB}"
  echo "ATTACH job=$JOB node=$NODE (reuse live serve)" | tee -a "$LOG"
  if ! bridge_up "$JOB" "$NODE"; then
    echo "ATTACH bridge_up failed; leaving NERSC job $JOB running" | tee -a "$LOG"
    exit 2
  fi
  stop_gpu_mon
  GPU_MON_PID=$(
    SYSML_JOB_PREFIX="$PREFIX" SYSML_SSH_HOST="$SSH_HOST" SYSML_NERSC_USER="$NERSC_USER" \
      bash scripts/monitor_nersc_gpu.sh --background \
      | sed -n 's/^started pid=\([0-9][0-9]*\).*/\1/p' | head -1
  )
  if [[ -z "${GPU_MON_PID:-}" ]]; then
    GPU_MON_PID=$(pgrep -n -f 'scripts/monitor_nersc_gpu.sh' || true)
  fi
  echo "gpu-monitor pid=${GPU_MON_PID:-unknown}" | tee -a "$LOG"
  if ! backend_ok; then
    echo "ATTACH backend not reachable on :${LOCAL_PORT}; leaving NERSC job $JOB running" | tee -a "$LOG"
    exit 2
  fi
fi

trap 'teardown_serve; echo TRAPPED_EXIT | tee -a "$LOG"' EXIT

tasks_on_alloc=0
for task in "${need[@]}"; do
  if [[ "$tasks_on_alloc" -ge "$TASKS_PER_ALLOC" ]]; then
    echo "recycling alloc after $TASKS_PER_ALLOC tasks" | tee -a "$LOG"
    teardown_serve
    tasks_on_alloc=0
  fi
  ensure_serve
  run_task "$task" || true
  tasks_on_alloc=$((tasks_on_alloc + 1))
  if ! backend_ok; then
    echo "backend dead after $task" | tee -a "$LOG"
    teardown_serve
    tasks_on_alloc=0
  fi
done

teardown_serve
trap - EXIT
echo "DONE wave under prefix $PREFIX (k=$K n=$N max_num_seqs=$MAX_NUM_SEQS tasks=${#need[@]})" | tee -a "$LOG"
echo "Analyze: bash scripts/analyze_characterization_wave.sh $PREFIX" | tee -a "$LOG"
echo "GPU log: $WAVE_DIR/gpu-monitor.log" | tee -a "$LOG"
