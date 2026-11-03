#!/bin/bash
#SBATCH --constraint=gpu
#SBATCH --qos=shared_interactive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --gpus-per-node=1
#SBATCH --mem=56G
#SBATCH --time=00:20:00
#SBATCH --job-name=sysml-inference
# Prefer launching via run_harbor_wave.sh salloc (overrides gpus/cpus/mem/qos/time).
# Env knobs:
#   SYSML_REMOTE_ROOT (required)
#   SYSML_MODEL_ID, SYSML_MAX_MODEL_LEN, SYSML_MAX_NUM_SEQS, SYSML_GPU_MEMORY_UTILIZATION
#   SYSML_TENSOR_PARALLEL_SIZE (default 1; set 4 for A1 256K×5)
#   SYSML_ENABLE_THINKING (true|false; default false)
#   SYSML_TOOL_CALL_PARSER, SYSML_VLLM_EXTRA_ARGS
set -euo pipefail
umask 077
: "${SYSML_REMOTE_ROOT:?Set SYSML_REMOTE_ROOT to your NERSC project directory}"
cd "$SYSML_REMOTE_ROOT"
export HF_HOME="$PWD/hf-cache" HF_HUB_OFFLINE=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1
export VLLM_API_KEY="$(cat secrets/model-api-key)"
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export OMP_NUM_THREADS=8
# FlashInfer flock fails on the shared home filesystem. Keep generated kernels
# node-local and use the installed vLLM torch sampler for this smoke test.
cache_root="${TMPDIR:-/tmp}/sysml-inference-${SLURM_JOB_ID}"
mkdir -p "$cache_root"
export FLASHINFER_WORKSPACE_BASE="$cache_root/flashinfer"
export TRITON_CACHE_DIR="$cache_root/triton"
export TORCHINDUCTOR_CACHE_DIR="$cache_root/torchinductor"
export VLLM_USE_FLASHINFER_SAMPLER=0
mkdir -p "logs/inference-$SLURM_JOB_ID/diagnostics"
run_dir="$PWD/logs/inference-$SLURM_JOB_ID"
export SYSML_INFERENCE_RUN="$run_dir"
MODEL="${SYSML_MODEL_ID:-Qwen/Qwen3.5-9B}"
MAX_MODEL_LEN="${SYSML_MAX_MODEL_LEN:-8192}"
GPU_MEM_UTIL="${SYSML_GPU_MEMORY_UTILIZATION:-0.80}"
MAX_NUM_SEQS="${SYSML_MAX_NUM_SEQS:-5}"
TP_SIZE="${SYSML_TENSOR_PARALLEL_SIZE:-1}"
TOOL_PARSER="${SYSML_TOOL_CALL_PARSER:-qwen3_coder}"
ENABLE_THINKING="${SYSML_ENABLE_THINKING:-false}"
case "$ENABLE_THINKING" in
  true|false) ;;
  *) echo "SYSML_ENABLE_THINKING must be true|false (got: $ENABLE_THINKING)" >&2; exit 2 ;;
esac
# Optional extra vLLM CLI tokens, space-separated, e.g. "--reasoning-parser qwen3"
# shellcheck disable=SC2206
EXTRA_ARGS=( ${SYSML_VLLM_EXTRA_ARGS:-} )
if ! [[ "$TP_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYSML_TENSOR_PARALLEL_SIZE must be a positive integer (got: $TP_SIZE)" >&2
  exit 2
fi
# Enable faulthandler dumps on fatal signals only. Avoid dump_traceback_later:
# periodic Timeout dumps have coincided with EngineCore deaths on Qwen3.5-9B.
cat > "$run_dir/diagnostics/sitecustomize.py" <<'PY'
import faulthandler
faulthandler.enable()
PY
export PYTHONPATH="$run_dir/diagnostics"
ngpu="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
printf '%s\n' "JOB=$SLURM_JOB_ID HOST=$(hostname) PORT=18080 MODEL=$MODEL TP=$TP_SIZE NGPU=$ngpu PARSER=$TOOL_PARSER MAX_LEN=$MAX_MODEL_LEN SEQS=$MAX_NUM_SEQS THINKING=$ENABLE_THINKING EXTRA=${EXTRA_ARGS[*]:-}"
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv
if [[ -n "$ngpu" && "$ngpu" -lt "$TP_SIZE" ]]; then
  echo "Need $TP_SIZE GPUs for tensor parallel; nvidia-smi sees $ngpu" >&2
  exit 2
fi
# Prove CUDA computation before attempting model serving.
timeout 90 env-model/bin/python -u - <<'PY'
import torch
print('torch',torch.__version__,'cuda',torch.version.cuda,'device_count',torch.cuda.device_count(),flush=True)
x=torch.ones((32,32),device='cuda')
print('cuda_matmul_sum',float((x@x).sum().item()),flush=True)
PY
env-model/bin/vllm serve "$MODEL" \
  --host 0.0.0.0 --port 18080 --served-model-name "$MODEL" \
  --tensor-parallel-size "$TP_SIZE" \
  --max-model-len "$MAX_MODEL_LEN" --max-num-seqs "$MAX_NUM_SEQS" \
  --gpu-memory-utilization "$GPU_MEM_UTIL" \
  --enforce-eager --enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER" \
  --default-chat-template-kwargs "{\"enable_thinking\":${ENABLE_THINKING}}" \
  "${EXTRA_ARGS[@]}" \
  > "$run_dir/vllm.log" 2>&1 &
model_pid=$!
trap 'kill "$model_pid" 2>/dev/null || true' EXIT
# 256K TP cold-start can take a long time; allow ~40 minutes.
for attempt in $(seq 1 600); do
  if MODEL="$MODEL" env-model/bin/python - <<'PY'
import json,os,urllib.request
req=urllib.request.Request('http://127.0.0.1:18080/v1/models',headers={'Authorization':'Bearer '+os.environ['VLLM_API_KEY']})
try:
 with urllib.request.urlopen(req,timeout=2) as r: models=json.load(r)
except OSError: raise SystemExit(1)
from pathlib import Path
Path(os.environ['SYSML_INFERENCE_RUN'],'models.json').write_text(json.dumps(models))
assert any(m.get('id')==os.environ['MODEL'] for m in models.get('data',[])), models
PY
  then
    MODEL="$MODEL" TP_SIZE="$TP_SIZE" env-model/bin/python - <<'PY'
import json,os,socket,urllib.request
from pathlib import Path
model=os.environ['MODEL']
body={'model':model,'messages':[{'role':'user','content':'Reply with the single word ready.'}],'max_tokens':32,'temperature':0.7,'top_p':0.9}
req=urllib.request.Request('http://127.0.0.1:18080/v1/chat/completions',data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+os.environ['VLLM_API_KEY'],'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=300) as r: response=json.load(r)
root=Path(os.environ['SYSML_INFERENCE_RUN'])
(root/'chat-request.json').write_text(json.dumps(body))
(root/'chat-response.json').write_text(json.dumps(response))
assert response['choices'],response
(root/'ready.json').write_text(json.dumps({
  'job_id': os.environ['SLURM_JOB_ID'],
  'host': socket.gethostname(),
  'port': 18080,
  'model': model,
  'tensor_parallel_size': int(os.environ.get('TP_SIZE', '1')),
}))
print('MODEL_CHAT_READY',flush=True)
PY
    wait "$model_pid"
    exit $?
  fi
  kill -0 "$model_pid" 2>/dev/null || { tail -80 "$run_dir/vllm.log"; exit 3; }
  sleep 4
done
echo 'MODEL_STARTUP_TIMEOUT'
tail -80 "$run_dir/vllm.log"
exit 4
