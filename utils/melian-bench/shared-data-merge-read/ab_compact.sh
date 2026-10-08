#!/usr/bin/env bash
# ab_compact.sh RUNS FIX_BIN: alternating base/fix merges of the Compact source parts, with the byte-identity check.
set -euo pipefail
L=/work/sdr
export WORK=$L/benchc CPUS=0-7
rm -f "$WORK/checksums.txt"
bash $L/kitc/bench.sh run $L/bin/clickhouse-base "$2" "${1:-5}"
cp $WORK/results.tsv $L/resultsc-$(date -u +%H%M).tsv
echo AB_DONE
