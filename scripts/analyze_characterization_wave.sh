#!/usr/bin/env bash
# Thin wrapper: bash scripts/analyze_characterization_wave.sh [JOB_PREFIX]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${ROOT}/.venv/bin/python"
[[ -x "$PY" ]] || PY=python3
exec "$PY" scripts/analyze_characterization_wave.py "$@"
