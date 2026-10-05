#!/usr/bin/env bash
# Alternating A/B of run.sh: ab.sh BASE FIX DATA_DIR RESULTS RUNS [CLIENTS] [SECONDS] [PREFILL_SCALE]
# Labels are $LA and $LB (default base and fix). Prints the median, min and max of the main metrics per binary (summarize.py).
set -uo pipefail
BASE=$1; FIX=$2; DATA=$3; RES=$4; RUNS=$5; shift 5
K=$(cd "$(dirname "$0")" && pwd)
for i in $(seq "$RUNS"); do
  "$K/run.sh" "$BASE" "${LA:-base}" "$DATA" "$RES" "$@"
  "$K/run.sh" "$FIX" "${LB:-fix}" "$DATA" "$RES" "$@"
done
python3 "$K/summarize.py" "$RES"
