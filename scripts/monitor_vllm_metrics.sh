#!/usr/bin/env bash
# Poll vLLM Prometheus /metrics via the local SSH tunnel for KV / scheduler util.
# Usage:
#   SYSML_JOB_PREFIX=... SYSML_TUNNEL_LOCAL_PORT=18091 bash scripts/monitor_vllm_metrics.sh [--background]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${SYSML_TUNNEL_LOCAL_PORT:-18086}"
PREFIX="${SYSML_JOB_PREFIX:-char-setup-10t-k5}"
INTERVAL="${SYSML_VLLM_MONITOR_INTERVAL:-20}"
OUT_DIR="results/characterization/${PREFIX}"
LOG="${OUT_DIR}/vllm-metrics.log"
KEY_FILE="${SYSML_MODEL_API_KEY_FILE:-.local-smoke/model-api-key}"
mkdir -p "$OUT_DIR"

emit() {
  echo "$*" >>"$LOG"
  if [[ -t 1 ]]; then
    echo "$*"
  fi
}

poll_once() {
  local key sample
  if [[ ! -f "$KEY_FILE" ]]; then
    emit "$(date -u +%Y-%m-%dT%H:%M:%SZ) NO_KEY"
    return 0
  fi
  key="$(tr -d '[:space:]' <"$KEY_FILE")"
  sample="$(
    python3 - "$PORT" "$key" <<'PY' 2>/dev/null || true
import sys, urllib.request
port, key = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/metrics",
    headers={"Authorization": f"Bearer {key}"},
)
try:
    raw = urllib.request.urlopen(req, timeout=8).read().decode()
except Exception as e:
    print(f"ERR {type(e).__name__}:{e}")
    raise SystemExit(0)
# Newer vLLM uses kv_cache_usage_perc; older used gpu_cache_usage_perc.
want = {
    "vllm:kv_cache_usage_perc": None,
    "vllm:gpu_cache_usage_perc": None,
    "vllm:num_requests_running": None,
    "vllm:num_requests_waiting": None,
    "vllm:num_requests_swapped": None,
}
for line in raw.splitlines():
    if line.startswith("#"):
        continue
    for name in list(want):
        if line.startswith(name + " ") or line.startswith(name + "{"):
            # last token is the value
            want[name] = line.rsplit(None, 1)[-1]
parts = []
kv = want["vllm:kv_cache_usage_perc"] or want["vllm:gpu_cache_usage_perc"]
if kv is not None:
    parts.append(f"kv_cache_usage_perc={kv}")
for name in ("vllm:num_requests_running", "vllm:num_requests_waiting", "vllm:num_requests_swapped"):
    if want[name] is not None:
        parts.append(f"{name.split(':',1)[1]}={want[name]}")
print(" ".join(parts) or "NO_MATCH")
PY
  )"
  emit "$(date -u +%Y-%m-%dT%H:%M:%SZ) port=${PORT} ${sample:-NO_SAMPLE}"
}

loop() {
  emit "vllm-metrics interval=${INTERVAL}s port=${PORT} log=$LOG"
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
