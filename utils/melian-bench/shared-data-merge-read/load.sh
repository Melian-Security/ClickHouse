#!/usr/bin/env bash
# load.sh PARTS ROWS: unpack the shared-data-gather kit, generate PARTS source files in
# parallel, then load them as PARTS wide parts with the base binary.
set -euo pipefail
L=/work/sdr
PARTS=${1:-8}; ROWS=${2:-500000}
mkdir -p $L/kit $L/bin $L/data
cp "$(dirname "$0")"/gen.py "$(dirname "$0")"/bench.sh "$(dirname "$0")"/schema.sql $L/kit/
cp -n /work/bin/clickhouse-base $L/bin/clickhouse-base
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
CPUS=0-7 GEN_DIR=$D WORK=$L/bench bash $L/kit/bench.sh load $L/bin/clickhouse-base $L/bin/clickhouse-base $PARTS $ROWS
du -sh $L/bench/base/data $L/bench/fix/data
echo LOAD_DONE
