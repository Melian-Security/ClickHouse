#!/usr/bin/env bash
# prof.sh NAME BIN: one merge under perf, then the self/inclusive reports of the merge thread.
set -euo pipefail
L=/work/sdr
NAME=${1:-base}; BIN=${2:-$L/bin/clickhouse-$NAME}
PERF=$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | head -1)
export WORK=$L/bench CPUS=0-7 PERF
bash $L/kit/bench.sh prof "$BIN" "$NAME"
head -45 $WORK/prof-$NAME-self.txt
echo ===
grep -E 'SharedData|insertGathered|gather|deserializeBinary|serializeBinary|collect|Dynamic' $WORK/prof-$NAME-incl.txt | head -50
echo PROF_DONE
