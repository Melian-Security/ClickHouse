#!/usr/bin/env bash
# gen_parts.sh PARTS ROWS: unpack the kit and generate PARTS source files in parallel.
set -euo pipefail
L=/work/sdr
PARTS=${1:-8}; ROWS=${2:-500000}
mkdir -p $L/kit $L/bin $L/data
cp "$(dirname "$0")"/gen.py "$(dirname "$0")"/bench.sh "$(dirname "$0")"/schema.sql $L/kit/
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
