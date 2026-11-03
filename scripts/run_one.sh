#!/usr/bin/env bash
# Optional local smoke: one DeepSWE task, k=1 n=1, no NERSC gateway path.
# Experiment waves use scripts/run_experiment.sh (k=n=seqs=5 by default).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi
TASK_ID="${TASK_ID:-clack-async-autocomplete-options}"
MODEL="${MODEL:-}"
TASK_PATH="${TASK_PATH:-vendor/deep-swe/tasks/$TASK_ID}"
: "${MODEL:?Set MODEL=provider/model-name (see configs/example.env)}"
[[ -f "$TASK_PATH/task.toml" ]] || { echo "Missing $TASK_PATH/task.toml" >&2; exit 2; }
mkdir -p jobs results
cmd=(harbor run -p "$TASK_PATH" -a pi -m "$MODEL" -k 1 -n 1 --env docker --jobs-dir jobs --yes)
if [[ -n "${PI_VERSION:-}" ]]; then
  cmd+=(--ak "version=$PI_VERSION")
fi
if [[ -n "${SYSML_MAX_TURNS:-}" ]]; then
  cmd+=(--ak "max_turns=${SYSML_MAX_TURNS}")
fi
if [[ -n "${SYSML_THINKING:-}" ]]; then
  cmd+=(--ak "thinking=${SYSML_THINKING}")
fi
if [[ -n "${HARBOR_MODEL_BASE_URL:-}" ]]; then
  : "${HARBOR_MODEL_API_KEY_NAME:?Set HARBOR_MODEL_API_KEY_NAME for custom endpoints}"
  : "${HARBOR_PI_MODEL_API:?Set HARBOR_PI_MODEL_API=openai-completions for vLLM/MLX}"
  # Harbor 0.24 resolves connection settings from provider environment variables;
  # it has no --model-base-url / --model-api-key-name CLI options.
  [[ "$MODEL" == openai/* ]] || { echo 'Custom endpoints currently require MODEL=openai/<model-id>' >&2; exit 2; }
  [[ "$HARBOR_MODEL_API_KEY_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { echo 'Invalid credential variable name' >&2; exit 2; }
  [[ -n "${!HARBOR_MODEL_API_KEY_NAME:-}" ]] || { echo "Export $HARBOR_MODEL_API_KEY_NAME before running" >&2; exit 2; }
  export OPENAI_BASE_URL="$HARBOR_MODEL_BASE_URL"
  export OPENAI_API_KEY="${!HARBOR_MODEL_API_KEY_NAME}"
  cmd+=(--ak "model_api=$HARBOR_PI_MODEL_API")
fi
printf 'Running:'; printf ' %q' "${cmd[@]}"; echo
"${cmd[@]}"
