#!/usr/bin/env bash
# Start/stop host tool gateway (TCP → tvclient → tvcache-rust).
# Pi agents in Docker reach this via host.docker.internal:SYSML_TVCACHE_GATEWAY_PORT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CACHE_DIR="${SYSML_TVCACHE_DIR:-$ROOT/results/tvcache}"
PID_FILE="$CACHE_DIR/tool-gateway.pid"
LOG_FILE="$CACHE_DIR/tool-gateway.log"
SOCK="${SYSML_TVCACHE_SOCK:-$CACHE_DIR/tvcache.sock}"
LISTEN_HOST="${SYSML_TVCACHE_GATEWAY_HOST:-127.0.0.1}"
LISTEN_PORT="${SYSML_TVCACHE_GATEWAY_PORT:-17878}"
PY="${ROOT}/.venv/bin/python"
[[ -x "$PY" ]] || PY=python3
export PYTHONPATH="${ROOT}/vendor/tvclient:${ROOT}${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$CACHE_DIR"

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

daemonize_gateway() {
  # Detach from Cursor/agent process groups (nohup alone is reaped on shell exit).
  # Linux: setsid(1). macOS: Python double-fork + os.setsid, write final pid.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$PY" -m parallel_tvcache.cache.tool_gateway \
      --sock "$SOCK" \
      --listen-host "$LISTEN_HOST" \
      --listen-port "$LISTEN_PORT" >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    return 0
  fi
  # Stay in $ROOT (writable). chdir("/") breaks tvclient set_rollout_id → ./rollouts
  # on macOS sealed system volume (Errno 30 Read-only file system).
  "$PY" - "$PID_FILE" "$LOG_FILE" "$SOCK" "$LISTEN_HOST" "$LISTEN_PORT" "$ROOT" <<'PY'
import os, sys

pid_file, log_file, sock, host, port, root = sys.argv[1:7]
py = sys.executable
args = [
    py, "-m", "parallel_tvcache.cache.tool_gateway",
    "--sock", sock, "--listen-host", host, "--listen-port", port,
]
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
os.chdir(root)
fd = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.dup2(fd, 1)
os.dup2(fd, 2)
if fd > 2:
    os.close(fd)
with open(pid_file, "w", encoding="utf-8") as f:
    f.write(str(os.getpid()))
os.execv(py, args)
PY
}

case "${1:-}" in
  start)
    if is_running; then
      echo "tool gateway already running pid=$(cat "$PID_FILE")"
      exit 0
    fi
    bash "$ROOT/scripts/tvcache_server.sh" start
    export SYSML_TVCACHE_SOCK="$SOCK"
    export SYSML_TVCACHE_GATEWAY_HOST="$LISTEN_HOST"
    export SYSML_TVCACHE_GATEWAY_PORT="$LISTEN_PORT"
    export SYSML_TVCACHE_WORKDIR="${SYSML_TVCACHE_WORKDIR:-/home/user}"
    # Inherit SYSML_TVCACHE_METRICS from wave if set.
    daemonize_gateway
    ready=0
    # Import + TCP bind can take >5s on a cold Mac; wait up to ~20s.
    for _ in $(seq 1 200); do
      if "$PY" -c "import socket;s=socket.create_connection(('$LISTEN_HOST',$LISTEN_PORT),0.2);s.close()" 2>/dev/null; then
        ready=1
        break
      fi
      if [[ -f "$PID_FILE" ]] && ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "tool gateway exited early — last log lines:" >&2
        tail -40 "$LOG_FILE" >&2 || true
        exit 1
      fi
      sleep 0.1
    done
    [[ "$ready" == 1 ]] || { echo "gateway TCP not ready on $LISTEN_HOST:$LISTEN_PORT (see $LOG_FILE)" >&2; tail -40 "$LOG_FILE" >&2 || true; exit 1; }
    echo "STARTED tool gateway pid=$(cat "$PID_FILE") tcp=$LISTEN_HOST:$LISTEN_PORT sock=$SOCK"
    ;;
  stop)
    if is_running; then
      kill "$(cat "$PID_FILE")" 2>/dev/null || true
      rm -f "$PID_FILE"
      echo "STOPPED tool gateway"
    else
      rm -f "$PID_FILE"
      echo "tool gateway not running"
    fi
    rm -f "$SOCK"
    ;;
  status)
    if is_running; then
      echo "RUNNING pid=$(cat "$PID_FILE") tcp=$LISTEN_HOST:$LISTEN_PORT sock=$SOCK"
      exit 0
    fi
    echo "STOPPED"
    exit 1
    ;;
  *)
    echo "Usage: bash scripts/tvcache_tool_gateway.sh {start|stop|status}" >&2
    exit 2
    ;;
esac
