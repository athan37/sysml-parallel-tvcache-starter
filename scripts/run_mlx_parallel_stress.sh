#!/usr/bin/env bash
# Forced-parallel stress: MultitoolPi + instruction preamble.
# NOT Exp A characterization — see docs/parallel_prompt_stress_report.md
#
# Prerequisite: mlx_lm.server on :18088, e.g.
#   python -m mlx_lm server --model mlx-community/Qwen3-4B-Instruct-2507-4bit \
#     --host 0.0.0.0 --port 18088
#
# Setup variants must exist (default source for prepare):
#   .venv/bin/python scripts/prepare_task.py <id> --setup-as-agent-actions --force
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

MLX_PORT="${SYSML_MLX_PORT:-18088}"
MLX_MODEL_ID="${SYSML_MODEL_ID:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
PREFIX="${SYSML_JOB_PREFIX:-stress-mlx-parallel}"
TASK_ROOT="${SYSML_TASK_ROOT:-$ROOT/variants/deep-swe-parallel-stress/tasks}"
TASK_LIST="${SYSML_TASK_LIST:-$ROOT/configs/experiment-tasks-parallel-stress.txt}"
SOURCE="${SYSML_PREPARE_SOURCE:-$ROOT/variants/deep-swe-setup/tasks}"
MAX_TURNS="${SYSML_MAX_TURNS:-12}"
PI_VERSION="${PI_VERSION:-1.4.0}"
BASE_URL="${HARBOR_MODEL_BASE_URL:-http://host.docker.internal:${MLX_PORT}/v1}"
AGENT="${SYSML_AGENT:-parallel_tvcache.evaluation.multitool_pi:MultitoolPi}"
PREPARE="${SYSML_PREPARE:-1}"

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

if [[ "$PREPARE" == "1" ]]; then
  echo "=== prepare parallel-stress variants ==="
  python3 "$ROOT/scripts/prepare_parallel_stress.py" \
    --source "$SOURCE" \
    --task-list "$TASK_LIST" \
    --destination "$TASK_ROOT" \
    --force
fi

export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
export OPENAI_BASE_URL="$BASE_URL"
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

mkdir -p "results/characterization/${PREFIX}" jobs
printf '%s\n' "{" \
  "  \"purpose\": \"parallel-tool-stress-not-characterization\"," \
  "  \"agent\": \"$AGENT\"," \
  "  \"task_root\": \"$TASK_ROOT\"," \
  "  \"model\": \"$MLX_MODEL_ID\"" \
  "}" > "results/characterization/${PREFIX}/stress_meta.json"

echo "PREFIX=$PREFIX AGENT=$AGENT MODEL=$MLX_MODEL_ID TURNS=$MAX_TURNS tasks=${#tasks[@]} (STRESS)"

for task in "${tasks[@]}"; do
  task_path="$TASK_ROOT/$task"
  [[ -f "$task_path/PARALLEL_STRESS_MANIFEST.json" ]] || {
    echo "Missing stress manifest for $task (SYSML_PREPARE=1?)" >&2
    exit 2
  }
  job_name="${PREFIX}-${task}"
  echo "=== harbor run STRESS $task → jobs/$job_name ==="
  harbor run \
    -p "$task_path" \
    -a "$AGENT" \
    -m "openai/${MLX_MODEL_ID}" \
    -k 1 -n 1 \
    --env docker \
    --jobs-dir jobs \
    --job-name "$job_name" \
    --yes \
    --base-url "$BASE_URL" \
    --allow-agent-host host.docker.internal \
    --ak "version=${PI_VERSION}" \
    --ak "model_api=openai-completions" \
    --ak "max_turns=${MAX_TURNS}" \
    --ak "thinking=off" \
    | tee -a "results/characterization/${PREFIX}/run.log"
done

echo "=== analyze ==="
bash scripts/analyze_characterization_wave.sh "$PREFIX"
echo "Wrote results/characterization/${PREFIX}/parallel_summary.json (STRESS, not Exp A)"
