#!/usr/bin/env bash
# ab.sh RUNS VARIANT(bench|benchc) [FIX_BIN]: alternating base/fix merges on cores 0-7 with the byte-identity check.
set -euo pipefail
L=/work/mrt
V=${2:-benchc}
KIT=$L/kit; [ "$V" = benchc ] && KIT=$L/kitc
export WORK=$L/$V CPUS=0-7
[ "$V" = benchc ] && export AFTER_CREATE="ALTER TABLE bench.{t} MODIFY SETTING min_bytes_for_wide_part = 0"
rm -f "$WORK/checksums.txt"
bash $KIT/bench.sh run /work/bin/clickhouse-base "${3:-/work/bin/clickhouse-fix}" "${1:-5}"
cp $WORK/results.tsv $L/results-$V-$(date -u +%H%M).tsv
echo AB_DONE
