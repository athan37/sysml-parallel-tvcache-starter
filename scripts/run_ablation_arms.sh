#!/usr/bin/env bash
# Run Harbor/Pi ablation arms (model × max_turns). Requires live OpenAI-compatible
# backend already reachable via the Mac gateway (tunnel+gateway for NERSC, or
# local MLX bound to SYSML_GATEWAY_BACKEND_PORT).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARM="${1:?Usage: $0 <9b-t8|4b-t8|4b-t50>}"
case "$ARM" in
  9b-t8)
    export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3.5-9B}"
    export SYSML_MAX_TURNS="${SYSML_MAX_TURNS:-8}"
    export SYSML_WAVE_ID="${SYSML_WAVE_ID:-ablation-9b-t8}"
    export SYSML_JOB_PREFIX="${SYSML_JOB_PREFIX:-abl-9b-t8}"
    ;;
  4b-t8)
    # Canonical HF id for "Qwen3-4B-Instruct" (teammate shorthand). Confirm with teammate.
    export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3-4B-Instruct-2507}"
    export SYSML_MAX_TURNS="${SYSML_MAX_TURNS:-8}"
    export SYSML_WAVE_ID="${SYSML_WAVE_ID:-ablation-4b-t8}"
    export SYSML_JOB_PREFIX="${SYSML_JOB_PREFIX:-abl-4b-t8}"
    ;;
  4b-t50)
    export SYSML_MODEL_ID="${SYSML_MODEL_ID:-Qwen/Qwen3-4B-Instruct-2507}"
    export SYSML_MAX_TURNS="${SYSML_MAX_TURNS:-50}"
    export SYSML_WAVE_ID="${SYSML_WAVE_ID:-ablation-4b-t50}"
    export SYSML_JOB_PREFIX="${SYSML_JOB_PREFIX:-abl-4b-t50}"
    ;;
  *)
    echo "Unknown arm: $ARM" >&2
    exit 2
    ;;
esac

export MODEL="openai/${SYSML_MODEL_ID}"
export SYSML_THINKING="${SYSML_THINKING:-off}"
export SYSML_ATTEMPTS="${SYSML_ATTEMPTS:-5}"
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0
: "${SYSML_COMPOSE_OVERLAY:?Set SYSML_COMPOSE_OVERLAY to the live compose JSON}"

echo "ARM=$ARM MODEL=$SYSML_MODEL_ID MAX_TURNS=$SYSML_MAX_TURNS PREFIX=$SYSML_JOB_PREFIX"
exec bash scripts/run_pilot_v1_harbor.sh
