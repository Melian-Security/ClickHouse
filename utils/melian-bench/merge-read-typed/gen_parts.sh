#!/usr/bin/env bash
# gen_parts.sh PARTS ROWS: generate PARTS source files in parallel into /work/mrt/data.
set -euo pipefail
L=/work/mrt
PARTS=${1:-8}; ROWS=${2:-250000}
mkdir -p $L/data
D=$L/data
pids=()
for p in $(seq 0 $((PARTS - 1))); do
  if [ ! -s $D/part_$p.jsonl ]; then
    python3 $L/kit/gen.py $p $ROWS > $D/part_$p.jsonl.tmp && mv $D/part_$p.jsonl.tmp $D/part_$p.jsonl &
    pids+=($!)
  fi
done
for x in "${pids[@]}"; do wait $x; done
du -sh $D
echo GEN_DONE
