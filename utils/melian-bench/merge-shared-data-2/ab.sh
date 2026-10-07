#!/usr/bin/env bash
# A/B of one Vertical merge of 8 Wide parts (4M rows) with the JSON shared-data write and gather paths, using the
# shared-data-gather kit. Byte identity of the merged part is checked by the kit (checksums.txt and every file).
#
#   ab.sh BIN_BASE BIN_FIX [RUNS]
#
# Env: WORK (default /work/msd2/bench), CPUS (default 0-7), GEN_DIR (default /work/msd2/data, part_<i>.jsonl).
set -euo pipefail
KIT=$(cd "$(dirname "$0")/../shared-data-gather" && pwd)
BASE=$1; FIX=$2; RUNS=${3:-5}
export WORK=${WORK:-/work/msd2/bench} CPUS=${CPUS:-0-7} GEN_DIR=${GEN_DIR:-/work/msd2/data}
PARTS=8; ROWS=500000

mkdir -p "$GEN_DIR"
pids=()
for p in $(seq 0 $((PARTS - 1))); do
    if [ ! -s "$GEN_DIR/part_$p.jsonl" ]; then
        python3 "$KIT/gen.py" "$p" "$ROWS" > "$GEN_DIR/part_$p.jsonl.tmp" && mv "$GEN_DIR/part_$p.jsonl.tmp" "$GEN_DIR/part_$p.jsonl" &
        pids+=($!)
    fi
done
for x in "${pids[@]}"; do wait "$x"; done

[ -d "$WORK/base/data" ] || bash "$KIT/bench.sh" load "$BASE" "$FIX" "$PARTS" "$ROWS"
rm -f "$WORK/checksums.txt"
bash "$KIT/bench.sh" run "$BASE" "$FIX" "$RUNS"
