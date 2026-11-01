#!/usr/bin/env bash
# Poll GPU memory on the live sysml-char-9b allocation.
# Usage:
#   bash scripts/monitor_nersc_gpu.sh              # foreground (also prints to tty)
#   bash scripts/monitor_nersc_gpu.sh --background  # daemon; log only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SSH_HOST="${SYSML_SSH_HOST:-perlmutter}"
NERSC_USER="${SYSML_NERSC_USER:?Set SYSML_NERSC_USER}"
INTERVAL="${SYSML_GPU_MONITOR_INTERVAL:-30}"
PREFIX="${SYSML_JOB_PREFIX:-char-setup-10t-k5}"
OUT_DIR="results/characterization/${PREFIX}"
LOG="${OUT_DIR}/gpu-monitor.log"
mkdir -p "$OUT_DIR"

emit() {
  # Single write to LOG. Echo to stdout only when interactive (avoids dup when
  # callers redirect stdout to the same file).
  echo "$*" >>"$LOG"
  if [[ -t 1 ]]; then
    echo "$*"
  fi
}

poll_once() {
  local jid node sample
  jid=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" \
    "squeue -u ${NERSC_USER} -n sysml-char-9b -h -o '%i %N' | head -1" 2>/dev/null || true)
  if [[ -z "$jid" ]]; then
    emit "$(date -u +%Y-%m-%dT%H:%M:%SZ) NO_JOB"
    return 0
  fi
  node=$(awk '{print $2}' <<<"$jid")
  jid=$(awk '{print $1}' <<<"$jid")
  # Prefer ssh-to-node: srun --overlap often hangs while vLLM holds ports.
  sample=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${node} nvidia-smi --query-gpu=timestamp,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null || true" 2>/dev/null || true)
  if [[ -z "$sample" ]]; then
    sample=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
      "srun --jobid=${jid} --overlap --ntasks=1 nvidia-smi --query-gpu=timestamp,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null || true" 2>/dev/null || true)
  fi
  emit "$(date -u +%Y-%m-%dT%H:%M:%SZ) job=${jid} node=${node} ${sample:-NO_SMI}"
}

loop() {
  emit "gpu-monitor interval=${INTERVAL}s log=$LOG"
  while true; do
    poll_once
    sleep "$INTERVAL"
  done
}

if [[ "${1:-}" == "--background" ]]; then
  nohup bash "$0" >>"$LOG" 2>&1 &
  echo "started pid=$! log=$LOG"
  exit 0
fi
loop
