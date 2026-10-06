#!/usr/bin/env bash
# Alternating A/B of the insert-deduplication hash: base and fix binaries with the data hash (dedup),
# plus insert_deduplicate=0 (nodedup) and a client token (token) on the base binary.
# usage: ab.sh <base-binary> <fix-binary> <out-dir> [runs] [files] [rows]
set -euo pipefail
BASE=$1
FIX=$2
OUT=$3
RUNS=${4:-5}
FILES=${5:-30}
ROWS=${6:-10500}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
[ -d "$OUT/data" ] || python3 "$HERE/gen.py" --out "$OUT/data" --files "$FILES" --rows "$ROWS"

for run in $(seq 1 "$RUNS"); do
    if [ $((run % 2)) -eq 1 ]; then
        bash "$HERE/bench.sh" "$BASE" "$OUT/data" dedup "base/run$run" "$OUT/results.txt"
        bash "$HERE/bench.sh" "$FIX" "$OUT/data" dedup "fix/run$run" "$OUT/results.txt"
        bash "$HERE/bench.sh" "$BASE" "$OUT/data" nodedup "base/run$run" "$OUT/results.txt"
        bash "$HERE/bench.sh" "$BASE" "$OUT/data" token "base/run$run" "$OUT/results.txt"
    else
        bash "$HERE/bench.sh" "$BASE" "$OUT/data" token "base/run$run" "$OUT/results.txt"
        bash "$HERE/bench.sh" "$BASE" "$OUT/data" nodedup "base/run$run" "$OUT/results.txt"
        bash "$HERE/bench.sh" "$FIX" "$OUT/data" dedup "fix/run$run" "$OUT/results.txt"
        bash "$HERE/bench.sh" "$BASE" "$OUT/data" dedup "base/run$run" "$OUT/results.txt"
    fi
    tail -4 "$OUT/results.txt"
done
python3 "$HERE/summarize.py" "$OUT/results.txt"
