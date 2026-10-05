#!/usr/bin/env bash
# Alternating A/B of two clickhouse binaries over the unique-key and duplicate-key datasets,
# with optimize_on_insert 0 and 1.
# usage: run_all.sh <base-binary> <fix-binary> <out-dir> [runs]
set -euo pipefail
BASE=$1
FIX=$2
OUT=$3
RUNS=${4:-5}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

[ -d "$OUT/data_uniq" ] || python3 "$HERE/gen.py" --out "$OUT/data_uniq" --files 10 --rows 10500 --dup-ratio 0
[ -d "$OUT/data_dup" ] || python3 "$HERE/gen.py" --out "$OUT/data_dup" --files 10 --rows 10500 --dup-ratio 0.1 --seed 7

for run in $(seq 1 "$RUNS"); do
    for ds in uniq dup; do
        for ooi in 1 0; do
            "$HERE/bench.sh" "$BASE" "$OUT/data_$ds" "$ooi" "base/$ds/run$run" "$OUT/results.txt"
            "$HERE/bench.sh" "$FIX" "$OUT/data_$ds" "$ooi" "fix/$ds/run$run" "$OUT/results.txt"
        done
    done
done

python3 "$HERE/summarize.py" "$OUT/results.txt"
