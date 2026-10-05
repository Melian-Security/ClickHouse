#!/usr/bin/env bash
# Profile one JSON merge with perf for each binary. Run after run.sh with the same WORK dir
# (reuses its bench.src tables, so the servers must be restartable from $WORK/<name>/config.xml).
#
#   profile.sh BIN_BASE BIN_FIX [SECONDS]
set -euo pipefail
WORK=${WORK:-/home/ssm-user/jm-work}
SECS=${3:-60}
declare -A BIN=([base]=$1 [fix]=$2)
declare -A PORT=([base]=19000 [fix]=29000)
q() { local name=$1; shift; "${BIN[$name]}" client --port "${PORT[$name]}" -q "$@"; }

for n in base fix; do
    "${BIN[$n]}" server --config-file="$WORK/$n/config.xml" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 60); do q "$n" "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
    q "$n" "DROP TABLE IF EXISTS bench.prof SYNC"
    q "$n" "CREATE TABLE bench.prof AS bench.src"
    q "$n" "SYSTEM STOP MERGES bench.prof"
    q "$n" "ALTER TABLE bench.prof ATTACH PARTITION tuple() FROM bench.src"
    q "$n" "SYSTEM START MERGES bench.prof"
    sudo perf record -F 999 -g -a -o "$WORK/perf-$n.data" -- sleep "$SECS" >/dev/null 2>&1 &
    perf_pid=$!
    q "$n" "OPTIMIZE TABLE bench.prof FINAL"
    sudo kill -INT "$perf_pid" 2>/dev/null || true
    wait "$perf_pid" || true
    sudo perf report -i "$WORK/perf-$n.data" --no-children --sort symbol -g none --percent-limit 0.5 --stdio 2>/dev/null | grep -v '^#' | grep '%' | head -25 > "$WORK/perf-$n.txt" || true
    echo "== $n top self symbols"; cat "$WORK/perf-$n.txt"
    kill "$pid"; wait "$pid" 2>/dev/null || true
done
