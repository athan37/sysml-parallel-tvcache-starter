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
# Pass account at submit time, e.g.:
#   sbatch --account=PLACEHOLDER_ACCOUNT nersc_serve_model.sbatch
# Or: salloc --account=PLACEHOLDER_ACCOUNT ... srun bash nersc_serve_model.sbatch
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
# Defaults match concurrent pass@k (n=k=seqs=5). Wave script exports these explicitly.
GPU_MEM_UTIL="${SYSML_GPU_MEMORY_UTILIZATION:-0.80}"
MAX_NUM_SEQS="${SYSML_MAX_NUM_SEQS:-5}"
TOOL_PARSER="${SYSML_TOOL_CALL_PARSER:-qwen3_coder}"
# Optional extra vLLM CLI tokens, space-separated, e.g. "--reasoning-parser qwen3"
# shellcheck disable=SC2206
EXTRA_ARGS=( ${SYSML_VLLM_EXTRA_ARGS:-} )
# Enable faulthandler dumps on fatal signals only. Avoid dump_traceback_later:
# periodic Timeout dumps have coincided with EngineCore deaths on Qwen3.5-9B.
cat > "$run_dir/diagnostics/sitecustomize.py" <<'PY'
import faulthandler
faulthandler.enable()
PY
export PYTHONPATH="$run_dir/diagnostics"
printf '%s\n' "JOB=$SLURM_JOB_ID HOST=$(hostname) PORT=18080 MODEL=$MODEL PARSER=$TOOL_PARSER EXTRA=${EXTRA_ARGS[*]:-}"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
# Prove CUDA computation before attempting model serving.
timeout 90 env-model/bin/python -u - <<'PY'
import torch
print('torch',torch.__version__,'cuda',torch.version.cuda,flush=True)
x=torch.ones((32,32),device='cuda')
print('cuda_matmul_sum',float((x@x).sum().item()),flush=True)
PY
env-model/bin/vllm serve "$MODEL" \
  --host 0.0.0.0 --port 18080 --served-model-name "$MODEL" \
  --max-model-len "$MAX_MODEL_LEN" --max-num-seqs "$MAX_NUM_SEQS" \
  --gpu-memory-utilization "$GPU_MEM_UTIL" \
  --enforce-eager --enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER" \
  --default-chat-template-kwargs '{"enable_thinking":false}' \
  "${EXTRA_ARGS[@]}" \
  > "$run_dir/vllm.log" 2>&1 &
model_pid=$!
trap 'kill "$model_pid" 2>/dev/null || true' EXIT
for attempt in $(seq 1 300); do
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
    MODEL="$MODEL" env-model/bin/python - <<'PY'
import json,os,socket,urllib.request
from pathlib import Path
model=os.environ['MODEL']
body={'model':model,'messages':[{'role':'user','content':'Reply with the single word ready.'}],'max_tokens':32,'temperature':0.7,'top_p':0.9}
req=urllib.request.Request('http://127.0.0.1:18080/v1/chat/completions',data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+os.environ['VLLM_API_KEY'],'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=120) as r: response=json.load(r)
root=Path(os.environ['SYSML_INFERENCE_RUN'])
(root/'chat-request.json').write_text(json.dumps(body))
(root/'chat-response.json').write_text(json.dumps(response))
assert response['choices'],response
(root/'ready.json').write_text(json.dumps({'job_id':os.environ['SLURM_JOB_ID'],'host':socket.gethostname(),'port':18080,'model':model}))
print('MODEL_CHAT_READY',flush=True)
PY
    wait "$model_pid"
    exit $?
  fi
  kill -0 "$model_pid" 2>/dev/null || { tail -40 "$run_dir/vllm.log"; exit 3; }
  sleep 2
done
echo 'MODEL_STARTUP_TIMEOUT'
tail -60 "$run_dir/vllm.log"
exit 4
