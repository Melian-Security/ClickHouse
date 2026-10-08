#!/usr/bin/env bash
# ab.sh RUNS [FIX_BIN]: alternating base/fix merges on cores 0-7 with the byte-identity check.
set -euo pipefail
L=/work/sdr
export WORK=$L/bench CPUS=0-7
rm -f "$WORK/checksums.txt"
bash $L/kit/bench.sh run $L/bin/clickhouse-base "${2:-$L/bin/clickhouse-fix}" "${1:-5}"
cp $WORK/results.tsv $L/results-$(date -u +%H%M).tsv
echo AB_DONE
