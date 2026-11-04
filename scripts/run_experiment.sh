#!/usr/bin/env bash
# One shared runner for Experiments A/B/C.
#
#   bash scripts/run_experiment.sh none         # Experiment A only
#   bash scripts/run_experiment.sh sequential   # Experiment B only
#   bash scripts/run_experiment.sh parallel     # Experiment C only
#   bash scripts/run_experiment.sh all          # A then B then C
#
# Forced-parallel stress (NOT Exp A characterization) — same wave, MultitoolLoopbackPi:
#   bash scripts/run_experiment.sh none --parallel-test
#
# Mode may also come from SYSML_CACHE_MODE if no mode argument is given.
# Same Harbor/NERSC wave for every mode; only the cache flag differs.
# Wave defaults: SYSML_PASS_K=SYSML_HARBOR_N=SYSML_MAX_NUM_SEQS=5 (concurrent rollouts).
# Today only "none" is wired (no tvclient on the tool path yet).
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

  none|sequential|parallel|all   Exp A/B/C cache mode (only none wired today)
  --parallel-test                Forced multi-tool stress (MultitoolLoopbackPi +
                                 stress task list). NOT natural characterization.
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
    none)
      bash scripts/run_harbor_wave.sh
      ;;
    sequential|parallel)
      cat >&2 <<EOF
SYSML_CACHE_MODE=$m is not wired yet (need tvclient on Pi tool-execute).
Re-run with: bash scripts/run_experiment.sh none
Or wait until Experiment $([[ $m == sequential ]] && echo B || echo C) lands — then this same command will run that mode only (it does not re-run other modes).
EOF
      return 3
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
