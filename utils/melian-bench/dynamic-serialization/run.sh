#!/usr/bin/env bash
# Insert and merge CPU of a wide JSON column whose dynamic paths overflow into shared data.
#
# usage: [CONC=4] run.sh <clickhouse-binary> <label> <data-dir> <results-file> [perf-prefix]
#
# Starts a fresh single-node server, creates bench.t (production `event` type, `advanced`
# shared data, `map_with_buckets` for zero-level parts) and stops merges. Inserts every *.jsonl
# file of <data-dir> as one `INSERT ... FORMAT JSONEachRow` over HTTP, so the JSON text is
# parsed by the server, with CONC inserts running concurrently (optimize_on_insert = 0).
# Then starts merges and runs OPTIMIZE ... FINAL. Appends one line to <results-file>:
#   label insert_cpu_s merge_cpu_s insert_wall_s merge_wall_s rows parts hash paths_hash
# CPU is server process utime+stime from /proc (watchdog disabled, so $! is the server).
# With [perf-prefix], records `perf record -g` of the server during the inserts
# (<prefix>.insert.data) and during the merge (<prefix>.merge.data).
set -euo pipefail
BIN=$1; LABEL=$2; DATA=$3; RES=$4; PERF=${5:-}
CONC=${CONC:-4}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /home/ssm-user/dynser.XXXX); PORT=${PORT:-39100}; HTTP=${HTTP:-38123}
mkdir -p "$WORK/data" "$WORK/log"
sed -e "s#@WORK@#$WORK#g" -e "s#@PORT@#$PORT#g" -e "s#@HTTP@#$HTTP#g" "$HERE/server.xml" > "$WORK/config.xml"
CLICKHOUSE_WATCHDOG_ENABLE=0 "$BIN" server --config-file="$WORK/config.xml" > "$WORK/log/stdout.log" 2>&1 &
PID=$!
PERF_PID=
trap '[ -n "$PERF_PID" ] && sudo kill -INT $PERF_PID 2>/dev/null; kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
c() { "$BIN" client --port $PORT "$@"; }
for _ in $(seq 120); do c -q 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done
c --multiquery < "$HERE/schema.sql"
c -q 'SYSTEM STOP MERGES bench.t'
TCK=$(getconf CLK_TCK)
cpu() { awk -v t=$TCK '{printf "%.2f", ($14+$15)/t}' /proc/$PID/stat; }
perf_start() { [ -z "$PERF" ] && return 0; sudo perf record -F 499 -g -p $PID -o "$PERF.$1.data" >/dev/null 2>&1 & PERF_PID=$!; sleep 1; }
perf_stop() { [ -z "$PERF" ] && return 0; sudo kill -INT $PERF_PID; wait $PERF_PID 2>/dev/null || true; PERF_PID=; }
Q='INSERT INTO bench.t SETTINGS optimize_on_insert = 0, insert_deduplicate = 0 FORMAT JSONEachRow'
URL="http://127.0.0.1:$HTTP/?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$Q")"
export URL
sleep 2
perf_start insert
C0=$(cpu); T0=$(date +%s.%N)
ls "$DATA"/*.jsonl | xargs -P "$CONC" -I{} sh -c 'curl -sS --fail --data-binary @"{}" "$URL" > /dev/null'
C1=$(cpu); T1=$(date +%s.%N)
perf_stop
c -q 'SYSTEM START MERGES bench.t'
perf_start merge
C2=$(cpu); T2=$(date +%s.%N)
c -q 'OPTIMIZE TABLE bench.t FINAL'
C3=$(cpu); T3=$(date +%s.%N)
perf_stop
PARTS=$(c -q "SELECT count() FROM system.parts WHERE database='bench' AND table='t' AND active")
ROWS=$(c -q 'SELECT count() FROM bench.t')
H=$(c -q 'SELECT ts, id, event FROM bench.t ORDER BY ts, id FORMAT JSONEachRow' | md5sum | cut -c1-16)
HS=$(c -q 'SELECT ts, id, JSONAllPathsWithTypes(event) FROM bench.t ORDER BY ts, id FORMAT JSONEachRow' | md5sum | cut -c1-16)
echo "$LABEL $(echo "$C1 - $C0" | bc) $(echo "$C3 - $C2" | bc) $(echo "$T1 - $T0" | bc) $(echo "$T3 - $T2" | bc) $ROWS $PARTS $H $HS" | tee -a "$RES"
