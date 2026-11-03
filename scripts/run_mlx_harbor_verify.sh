#!/usr/bin/env bash
# Local parallel-turn check: Harbor Pi + stock DeepSWE → MLX OpenAI server.
# Matches PDF knobs: 1 trial × 8 turns, Qwen3-4B-Instruct (4bit MLX).
#
# Prerequisite (separate terminal / already running):
#   source .venv/bin/activate
#   python -m mlx_lm server --model mlx-community/Qwen3-4B-Instruct-2507-4bit \
#     --host 0.0.0.0 --port 18088
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

MLX_PORT="${SYSML_MLX_PORT:-18088}"
MLX_MODEL_ID="${SYSML_MODEL_ID:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
PREFIX="${SYSML_JOB_PREFIX:-verify-mlx-4b-stock-k1}"
TASK_ROOT="${SYSML_TASK_ROOT:-$ROOT/variants/deep-swe-stock/tasks}"
TASK_LIST="${SYSML_TASK_LIST:-$ROOT/configs/experiment-tasks-parallel-verify.txt}"
MAX_TURNS="${SYSML_MAX_TURNS:-8}"
PI_VERSION="${PI_VERSION:-1.4.0}"
# From inside Docker Desktop, host loopback is host.docker.internal.
BASE_URL="${HARBOR_MODEL_BASE_URL:-http://host.docker.internal:${MLX_PORT}/v1}"

curl -sf "http://127.0.0.1:${MLX_PORT}/v1/models" >/dev/null || {
  echo "MLX server not reachable on 127.0.0.1:${MLX_PORT}. Start mlx_lm.server first." >&2
  exit 2
}

tasks=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo "$line" | tr -d '[:space:]')"
  [[ -z "$line" ]] && continue
  tasks+=("$line")
done < "$TASK_LIST"
[[ ${#tasks[@]} -gt 0 ]] || { echo "Empty task list: $TASK_LIST" >&2; exit 2; }

export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
export OPENAI_BASE_URL="$BASE_URL"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0

mkdir -p "results/characterization/${PREFIX}" jobs
echo "PREFIX=$PREFIX MODEL=$MLX_MODEL_ID BASE_URL=$BASE_URL TURNS=$MAX_TURNS tasks=${#tasks[@]}"

for task in "${tasks[@]}"; do
  task_path="$TASK_ROOT/$task"
  [[ -f "$task_path/task.toml" ]] || { echo "Missing $task_path/task.toml" >&2; exit 2; }
  job_name="${PREFIX}-${task}"
  echo "=== harbor run $task → jobs/$job_name ==="
  harbor run \
    -p "$task_path" \
    -a pi \
    -m "openai/${MLX_MODEL_ID}" \
    -k 1 -n 1 \
    --env docker \
    --jobs-dir jobs \
    --job-name "$job_name" \
    --yes \
    --base-url "$BASE_URL" \
    --allow-agent-host host.docker.internal \
    --allow-agent-host "127.0.0.1" \
    --ak "version=${PI_VERSION}" \
    --ak "model_api=openai-completions" \
    --ak "max_turns=${MAX_TURNS}" \
    --ak "thinking=off" \
    | tee -a "results/characterization/${PREFIX}/run.log"
done

echo "=== analyze ==="
bash scripts/analyze_characterization_wave.sh "$PREFIX"
echo "Wrote results/characterization/${PREFIX}/parallel_summary.json"
