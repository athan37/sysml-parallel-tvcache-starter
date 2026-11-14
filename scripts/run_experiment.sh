#!/usr/bin/env bash
# One shared runner for Experiments A/B/C.
#
#   bash scripts/run_experiment.sh none         # Experiment A only
#   bash scripts/run_experiment.sh sequential   # Experiment B (TVCache sequential)
#   bash scripts/run_experiment.sh parallel     # Experiment C — Design A TVCache
#   bash scripts/run_experiment.sh all          # A then B then C
#
# Forced-parallel stress (NOT Exp A characterization) — same wave, MultitoolLoopbackPi:
#   bash scripts/run_experiment.sh none --parallel-test
#
# Mode may also come from SYSML_CACHE_MODE if no mode argument is given.
# Same Harbor/NERSC wave for every mode; only the cache flag / agent differs.
# Wave defaults: SYSML_PASS_K=SYSML_HARBOR_N=SYSML_MAX_NUM_SEQS=5 (concurrent rollouts).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE=""
PARALLEL_TEST=0
for arg in "$@"; do
  case "$arg" in
    --parallel-test|--parallel-stress)
      PARALLEL_TEST=1
      ;;
    -h|--help)
      cat <<EOF
Usage: bash scripts/run_experiment.sh {none|sequential|parallel|all} [--parallel-test]

  none         Experiment A (no TVCache)
  sequential   Experiment B — paper TVCache via tool gateway + TvcacheLoopbackPi
  parallel     Experiment C — Design A (per-call HIT/WAIT/EXECUTE) + TvcacheLoopbackPi
  all          A, then B, then C
  --parallel-test   Forced multi-tool stress (MultitoolLoopbackPi). NOT natural Exp A.
EOF
      exit 0
      ;;
    -*)
      echo "Unknown flag: $arg (try --parallel-test)" >&2
      exit 2
      ;;
    *)
      if [[ -n "$MODE" ]]; then
        echo "Unexpected extra argument: $arg" >&2
        exit 2
      fi
      MODE="$arg"
      ;;
  esac
done
MODE="${MODE:-${SYSML_CACHE_MODE:-none}}"

if [[ "$PARALLEL_TEST" == "1" ]]; then
  export SYSML_PARALLEL_STRESS=1
  echo "parallel-test: SYSML_PARALLEL_STRESS=1 (MultitoolLoopbackPi; not Exp A natural rates)"
fi

run_mode() {
  local m="$1"
  export SYSML_CACHE_MODE="$m"
  case "$m" in
    none|sequential|parallel)
      if [[ "$m" == "parallel" ]]; then
        export SYSML_TVCACHE_DESIGN="${SYSML_TVCACHE_DESIGN:-A}"
        echo "parallel: SYSML_TVCACHE_DESIGN=$SYSML_TVCACHE_DESIGN (Design A)"
      fi
      bash scripts/run_harbor_wave.sh
      ;;
    *)
      echo "Unknown mode: $m (use none|sequential|parallel|all)" >&2
      return 2
      ;;
  esac
}

case "$MODE" in
  all)
    status=0
    for m in none sequential parallel; do
      echo "=== run_experiment mode=$m ==="
      run_mode "$m" || status=$?
    done
    exit "$status"
    ;;
  none|sequential|parallel)
    run_mode "$MODE"
    ;;
  *)
    echo "Usage: bash scripts/run_experiment.sh {none|sequential|parallel|all} [--parallel-test]" >&2
    exit 2
    ;;
esac
