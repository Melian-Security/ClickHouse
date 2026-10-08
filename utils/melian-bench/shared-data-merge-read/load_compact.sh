#!/usr/bin/env bash
# load_compact.sh PARTS ROWS: the same rows loaded as Compact source parts (8 shared data buckets),
# which a merge reads with the Compact reader and writes into one Wide part.
set -euo pipefail
L=/work/sdr
PARTS=${1:-8}; ROWS=${2:-500000}
rm -rf $L/kitc && cp -a $L/kit $L/kitc
sed -i 's/min_bytes_for_wide_part = 0,/min_bytes_for_wide_part = 5000000000,/' $L/kitc/schema.sql
grep -n min_bytes_for_wide_part $L/kitc/schema.sql
CPUS=0-7 GEN_DIR=$L/data WORK=$L/benchc bash $L/kitc/bench.sh load $L/bin/clickhouse-base $L/bin/clickhouse-base $PARTS $ROWS
du -sh $L/benchc/base/data
echo LOADC_DONE
