#!/usr/bin/env bash
# load.sh PARTS ROWS: generate PARTS source files in parallel, then load them as Wide
# source parts (WORK=/work/mrt/bench) and as Compact source parts (/work/mrt/benchc) with the base binary.
set -euo pipefail
L=/work/mrt
PARTS=${1:-8}; ROWS=${2:-250000}
mkdir -p $L/bin $L/data
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
rm -rf $L/kitc && cp -a $L/kit $L/kitc
sed -i 's/min_bytes_for_wide_part = 0,/min_bytes_for_wide_part = 50000000000,/' $L/kitc/schema.sql
CPUS=0-7 GEN_DIR=$D WORK=$L/bench bash $L/kit/bench.sh load $L/bin/clickhouse-base $L/bin/clickhouse-base $PARTS $ROWS
CPUS=8-15 GEN_DIR=$D WORK=$L/benchc bash $L/kitc/bench.sh load $L/bin/clickhouse-base $L/bin/clickhouse-base $PARTS $ROWS
du -sh $L/bench/base/data $L/benchc/base/data
echo LOAD_DONE
