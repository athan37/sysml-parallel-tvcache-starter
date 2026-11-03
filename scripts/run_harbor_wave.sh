#!/usr/bin/env bash
# Shared Harbor + NERSC wave (setup variants × pass@k with concurrency n).
# Called by run_experiment.sh. Reads SYSML_CACHE_MODE (only "none" wired today).
#
# Defaults = proven A0 cell (1 GPU, 8K, max_turns=8, k=n=seqs=5).
# A1 (4 GPU TP, 256K, max_turns=100): source configs/models/qwen3.5-9b-a1-tp4-256k.env.example
# Task ids: configs/experiment-tasks.txt (override with SYSML_TASK_LIST).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export OPENAI_API_KEY=EMPTY OPENAI_BASE_URL=http://127.0.0.1:18081/v1
export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3.5-9B}"
export MODEL="${MODEL:-openai/${SYSML_MODEL_ID}}"
export SYSML_MAX_TURNS="${SYSML_MAX_TURNS:-8}"
export SYSML_THINKING="${SYSML_THINKING:-off}"
export PI_VERSION="${PI_VERSION:-1.4.0}"
export SYSML_MAX_TOKENS="${SYSML_MAX_TOKENS:-2048}"
CACHE_MODE="${SYSML_CACHE_MODE:-none}"
PREFIX="${SYSML_JOB_PREFIX:-char-setup-10t-k5}"
LOCAL_PORT="${SYSML_TUNNEL_LOCAL_PORT:-18086}"
K="${SYSML_PASS_K:-5}"
N="${SYSML_HARBOR_N:-$K}"
MAX_NUM_SEQS="${SYSML_MAX_NUM_SEQS:-$K}"
GPU_MEM="${SYSML_GPU_MEMORY_UTILIZATION:-0.80}"
MAX_LEN="${SYSML_MAX_MODEL_LEN:-8192}"
# Pi contextWindow should track vLLM max-model-len (override SYSML_CONTEXT_WINDOW if needed).
export SYSML_CONTEXT_WINDOW="${SYSML_CONTEXT_WINDOW:-$MAX_LEN}"
GPUS="${SYSML_GPUS:-${SYSML_TENSOR_PARALLEL_SIZE:-1}}"
TP_SIZE="${SYSML_TENSOR_PARALLEL_SIZE:-$GPUS}"
if [[ "$TP_SIZE" -gt "$GPUS" ]]; then
  echo "SYSML_TENSOR_PARALLEL_SIZE ($TP_SIZE) cannot exceed SYSML_GPUS ($GPUS)" >&2
  exit 2
fi
CPUS_PER_TASK="${SYSML_CPUS_PER_TASK:-$((GPUS * 32))}"
if [[ -n "${SYSML_MEM:-}" ]]; then
  MEM="$SYSML_MEM"
elif [[ "$GPUS" -le 1 ]]; then
  MEM="56G"
else
  MEM="220G"
fi
SLURM_QOS="${SYSML_SLURM_QOS:-shared_interactive}"
# QOS MaxWall is often 4h; recycle before expiry via TASKS_PER_ALLOC.
ALLOC_TIME="${SYSML_ALLOC_TIME:-04:00:00}"
TASKS_PER_ALLOC="${SYSML_TASKS_PER_ALLOC:-2}"
# How many Harbor task jobs to run at once against one vLLM (TP is one replica).
TASK_PARALLEL="${SYSML_TASK_PARALLEL:-1}"
if ! [[ "$TASK_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYSML_TASK_PARALLEL must be a positive integer (got: $TASK_PARALLEL)" >&2
  exit 2
fi
SERVE_WAIT_ITERS="${SYSML_SERVE_WAIT_ITERS:-360}"
# Harbor Pi accepts: off|minimal|low|medium|high|xhigh|max (not bare "on").
# Alias on -> high for convenience.
case "${SYSML_THINKING}" in
  on) SYSML_THINKING=high ;;
esac
case "${SYSML_THINKING}" in
  off|minimal|low|medium|high|xhigh|max) ;;
  *)
    echo "SYSML_THINKING must be off|minimal|low|medium|high|xhigh|max (or on→high); got: $SYSML_THINKING" >&2
    exit 2
    ;;
esac
export SYSML_THINKING
if [[ "$SYSML_THINKING" == "off" ]]; then
  ENABLE_THINKING=false
else
  ENABLE_THINKING=true
fi
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
echo "PREFIX=$PREFIX K=$K N=$N MAX_NUM_SEQS=$MAX_NUM_SEQS MAX_LEN=$MAX_LEN CTX=$SYSML_CONTEXT_WINDOW TURNS=$SYSML_MAX_TURNS THINKING=$SYSML_THINKING GPU_MEM=$GPU_MEM GPUS=$GPUS TP=$TP_SIZE MEM=$MEM CPUS=$CPUS_PER_TASK QOS=$SLURM_QOS MODE=$CACHE_MODE tasks=${#tasks[@]} per_alloc=$TASKS_PER_ALLOC task_parallel=$TASK_PARALLEL" | tee -a "$LOG"
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

python3 - "$WAVE_DIR/manifest.json" "$CACHE_MODE" "$SYSML_MODEL_ID" "$SYSML_MAX_TURNS" "$SYSML_THINKING" "$K" "$N" "$MAX_NUM_SEQS" "$TASK_ROOT" "$PREFIX" "$MAX_LEN" "$SYSML_CONTEXT_WINDOW" "$GPUS" "$TP_SIZE" "$GPU_MEM" "$SLURM_QOS" "$TASK_PARALLEL" "${tasks[@]}" <<'PY'
import json, sys
from pathlib import Path
(path, cache, model, turns, thinking, k, n, seqs, task_root, prefix,
 max_len, ctx, gpus, tp, gpu_mem, qos, task_parallel) = sys.argv[1:18]
tasks = sys.argv[18:]
Path(path).write_text(json.dumps({
    "purpose": "deep-swe-setup-variants-10task",
    "cache_mode": cache,
    "model": model,
    "max_turns": int(turns),
    "thinking": thinking,
    "k": int(k),
    "n": int(n),
    "max_num_seqs": int(seqs),
    "max_model_len": int(max_len),
    "context_window": int(ctx),
    "gpus": int(gpus),
    "tensor_parallel_size": int(tp),
    "gpu_memory_utilization": float(gpu_mem),
    "slurm_qos": qos,
    "task_parallel": int(task_parallel),
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
  local vllm_extra tool_parser
  vllm_extra="${SYSML_VLLM_EXTRA_ARGS-}"
  if [[ -z "$vllm_extra" ]]; then
    vllm_extra='--reasoning-parser qwen3 --language-model-only'
  fi
  tool_parser="${SYSML_TOOL_CALL_PARSER:-qwen3_coder}"
  scp -o BatchMode=yes scripts/nersc_serve_model.sbatch \
    "${SSH_HOST}:${REMOTE_ROOT}/nersc_serve_model.sbatch"
  ssh -o BatchMode=yes "$SSH_HOST" "scancel -u ${NERSC_USER} -n sysml-abl-9b 2>/dev/null || true; scancel -u ${NERSC_USER} -n sysml-char-9b 2>/dev/null || true; scancel -u ${NERSC_USER} -n sysml-inf-9b 2>/dev/null || true"
  sleep 3
  # Quote carefully: remote export must keep spaces in SYSML_VLLM_EXTRA_ARGS.
  ssh -o BatchMode=yes "$SSH_HOST" \
    "cd $(printf %q "$REMOTE_ROOT") && \
     export SYSML_REMOTE_ROOT=$(printf %q "$REMOTE_ROOT") \
       SYSML_MODEL_ID=$(printf %q "$SYSML_MODEL_ID") \
       SYSML_TOOL_CALL_PARSER=$(printf %q "$tool_parser") \
       SYSML_GPU_MEMORY_UTILIZATION=$(printf %q "$GPU_MEM") \
       SYSML_MAX_MODEL_LEN=$(printf %q "$MAX_LEN") \
       SYSML_MAX_NUM_SEQS=$(printf %q "$MAX_NUM_SEQS") \
       SYSML_TENSOR_PARALLEL_SIZE=$(printf %q "$TP_SIZE") \
       SYSML_ENABLE_THINKING=$(printf %q "$ENABLE_THINKING") \
       SYSML_VLLM_EXTRA_ARGS=$(printf %q "$vllm_extra") && \
     salloc --account=$(printf %q "$SLURM_ACCOUNT") --constraint=gpu --qos=$(printf %q "$SLURM_QOS") \
       --nodes=1 --ntasks=1 --cpus-per-task=$(printf %q "$CPUS_PER_TASK") --gpus-per-node=$(printf %q "$GPUS") \
       --mem=$(printf %q "$MEM") --time=$(printf %q "$ALLOC_TIME") --job-name=sysml-char-9b \
       srun --cpu-bind=none bash nersc_serve_model.sbatch" &
  SERVE_PID=$!
  echo "serve_up waiting (gpus=$GPUS tp=$TP_SIZE max_len=$MAX_LEN seqs=$MAX_NUM_SEQS qos=$SLURM_QOS iters=$SERVE_WAIT_ITERS)" | tee -a "$LOG"
  for i in $(seq 1 "$SERVE_WAIT_ITERS"); do
    JID=$(ssh -o BatchMode=yes "$SSH_HOST" "squeue -u ${NERSC_USER} -n sysml-char-9b -h -o %i | head -1" 2>/dev/null || true)
    if [[ -n "$JID" ]]; then
      READY_PATH="${REMOTE_ROOT}/logs/inference-${JID}/ready.json"
      if ssh -o BatchMode=yes "$SSH_HOST" "test -f '${READY_PATH}'" 2>/dev/null; then
        READY=$(ssh -o BatchMode=yes "$SSH_HOST" "cat '${READY_PATH}'")
        JOB=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['job_id'])" "$READY")
        NODE=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['host'])" "$READY")
        echo "READY job=$JOB node=$NODE gpus=$GPUS tp=$TP_SIZE max_len=$MAX_LEN max_num_seqs=$MAX_NUM_SEQS path=$READY_PATH" | tee -a "$LOG"
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
    --ak "thinking=${SYSML_THINKING}" \
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
idx=0
while [[ "$idx" -lt "${#need[@]}" ]]; do
  if [[ "$tasks_on_alloc" -ge "$TASKS_PER_ALLOC" ]]; then
    echo "recycling alloc after $TASKS_PER_ALLOC tasks" | tee -a "$LOG"
    teardown_serve
    tasks_on_alloc=0
  fi
  ensure_serve
  batch=()
  while [[ "${#batch[@]}" -lt "$TASK_PARALLEL" && "$idx" -lt "${#need[@]}" ]]; do
    # Stay within remaining alloc budget when TASKS_PER_ALLOC is small.
    if [[ "$tasks_on_alloc" -ge "$TASKS_PER_ALLOC" ]]; then
      break
    fi
    batch+=("${need[$idx]}")
    idx=$((idx + 1))
    tasks_on_alloc=$((tasks_on_alloc + 1))
  done
  if [[ "${#batch[@]}" -eq 0 ]]; then
    # Alloc budget full before starting a parallel batch — recycle and retry.
    continue
  fi
  echo "parallel_batch size=${#batch[@]} tasks=${batch[*]}" | tee -a "$LOG"
  # Stagger Harbor job starts so Docker does not race 2×N compose networks/binds
  # at once (subnet exhaustion / missing verifier bind). 0 = simultaneous.
  STAGGER_SEC="${SYSML_TASK_STAGGER_SEC:-0}"
  pids=()
  for task in "${batch[@]}"; do
    if [[ "${#pids[@]}" -gt 0 && "$STAGGER_SEC" =~ ^[1-9][0-9]*$ ]]; then
      echo "stagger ${STAGGER_SEC}s before next Harbor task" | tee -a "$LOG"
      sleep "$STAGGER_SEC"
    fi
    run_task "$task" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  if ! backend_ok; then
    echo "backend dead after batch ${batch[*]}" | tee -a "$LOG"
    teardown_serve
    tasks_on_alloc=0
  fi
done

teardown_serve
trap - EXIT
echo "DONE wave under prefix $PREFIX (k=$K n=$N max_num_seqs=$MAX_NUM_SEQS max_len=$MAX_LEN turns=$SYSML_MAX_TURNS thinking=$SYSML_THINKING gpus=$GPUS tp=$TP_SIZE task_parallel=$TASK_PARALLEL tasks=${#need[@]})" | tee -a "$LOG"
echo "Analyze: bash scripts/analyze_characterization_wave.sh $PREFIX" | tee -a "$LOG"
echo "GPU log: $WAVE_DIR/gpu-monitor.log" | tee -a "$LOG"
