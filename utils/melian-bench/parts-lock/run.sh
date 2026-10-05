#!/usr/bin/env bash
# One run of the parts-lock benchmark against one binary.
#   run.sh BIN LABEL DATA_DIR RESULTS [CLIENTS] [SECONDS] [PREFILL_SCALE]
#
# 1. Starts a single-node server with embedded Keeper, creates the Replicated database and the
#    ReplicatedReplacingMergeTree table of schema.sql (no merges are assigned).
# 2. Prefill: one INSERT ... SELECT per partition, one row per part, PREFILL_SCALE x
#    [9000 6000 4000 3000 2500 2000 1500 1000 800 600 400 200] parts (about 31k at scale 1).
#    With SNAPSHOT=dir, the prefilled data and Keeper state are copied from dir (made by a previous run with the
#    same SNAPSHOT if dir does not exist yet) instead, which takes the prefill out of the timed runs.
# 3. Load: CLIENTS concurrent HTTP clients insert the files of DATA_DIR (one part each) for SECONDS.
#    DATA_DIR=empty sends inserts without rows: only the checks done at the start of every insert.
#    Every 5 s it samples the replication queue, the fetches pool and the stacks of all threads.
# Appends one result line to RESULTS and leaves the samples in $OUT_DIR (default /home/ssm-user/pl-out/LABEL-<time>):
# queue.tsv (time, queue size, GET_PART entries, entries postponed for "fetches already executing", executing
# entries, BackgroundFetchesPoolTask, system.replicated_fetches rows, active parts), stacks.tsv (all thread stacks)
# and profile.tsv (wall-clock samples of the inserts by the first frame matching the parts lock functions).
set -uo pipefail
BIN=$1; LABEL=$2; DATA=$3; RES=$4; CLIENTS=${5:-48}; SECS=${6:-120}; SCALE=${7:-1}
K=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /home/ssm-user/pl.XXXX)
OUT=${OUT_DIR:-/home/ssm-user/pl-out/$LABEL-$(date +%H%M%S)}
mkdir -p "$WORK/data" "$WORK/log" "$OUT"
PORT=39100; KPORT=39181; RPORT=39234; HTTP_PORT=$((PORT + 23))
sed -e "s#@WORK@#$WORK#g" -e "s#@PORT@#$PORT#g" -e "s#@KEEPER_PORT@#$KPORT#g" -e "s#@RAFT_PORT@#$RPORT#g" -e "s#@IS_PORT@#$((PORT + 9))#g" -e "s#@HTTP_PORT@#$((PORT + 23))#g" "$K/server.xml" > "$WORK/config.xml"
SNAPSHOT=${SNAPSHOT:-}
PID=
start_server() {
  CLICKHOUSE_WATCHDOG_ENABLE=0 "$BIN" server --config-file="$WORK/config.xml" > "$WORK/log/stdout.log" 2>&1 &
  PID=$!
  for _ in $(seq 1200); do c -q 'SELECT 1' >/dev/null 2>&1 && return; sleep 0.5; done
  echo "server did not start" >&2; exit 1
}
cleanup() { kill $PID 2>/dev/null; wait $PID 2>/dev/null; cp "$WORK/log/server.err.log" "$OUT/" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
c() { "$BIN" client --port $PORT "$@"; }
TCK=$(getconf CLK_TCK)
cpu() { awk -v t="$TCK" '{printf "%.2f", ($14+$15)/t}' /proc/$PID/stat; }
events() { c -q "SELECT sumIf(value, event = 'ZooKeeperTransactions'), sumIf(value, event = 'ZooKeeperCreate'), sumIf(value, event = 'ZooKeeperRemove'), sumIf(value, event = 'ZooKeeperExists') FROM system.events FORMAT TSV"; }

PREFILL_WALL=0; PREFILL_CPU=0
if [ -n "$SNAPSHOT" ] && [ -d "$SNAPSHOT" ]; then
  cp -a "$SNAPSHOT/." "$WORK/"
  start_server
  c -q "SYSTEM SYNC REPLICA bench.t" >/dev/null
else
start_server
c --multiquery < "$K/schema.sql" || exit 1

# Prefill.
C0=$(cpu); T0=$(date +%s.%N)
p=0
for n in 9000 6000 4000 3000 2500 2000 1500 1000 800 600 400 200; do
  n=$(( n * SCALE ))
  c -q "INSERT INTO bench.t (ts, id, p, event) SELECT number, number + $p * 1000000000, $p, '{\"action\":\"prefill\",\"severity_id\":1}'
        FROM numbers($n)
        SETTINGS max_block_size = 1, max_insert_block_size = 1, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0,
                 max_insert_threads = 1, deduplicate_insert = 'disable'" || exit 1
  p=$((p + 1))
done
C1=$(cpu); T1=$(date +%s.%N)
PREFILL_WALL=$(echo "$T1 - $T0" | bc); PREFILL_CPU=$(echo "$C1 - $C0" | bc)
if [ -n "$SNAPSHOT" ]; then
  kill $PID; wait $PID
  mkdir -p "$SNAPSHOT"
  for d in data coordination; do cp -a "$WORK/$d" "$SNAPSHOT/"; done
  start_server
fi
fi
PARTS0=$(c -q "SELECT count() FROM system.parts WHERE database = 'bench' AND table = 't' AND active")

# Load.
if [ "$DATA" = empty ]; then : > "$WORK/empty.jsonl"; FILES=("$WORK/empty.jsonl"); else FILES=("$DATA"/*.jsonl); fi
NF=${#FILES[@]}
END=$(( $(date +%s) + SECS ))
client_loop() {
  local i=$1 n=0
  while [ "$(date +%s)" -lt $END ]; do
    local f=${FILES[$(( (i * 7 + n) % NF ))]}
    # Over HTTP, so that the server parses the JSON (as with the production inserts), one block per insert.
    curl -sS --data-binary @"$f" -o /dev/null -w '%{http_code}\n' \
      "http://localhost:$HTTP_PORT/?log_comment=pl-load&query_profiler_real_time_period_ns=10000000&query_profiler_cpu_time_period_ns=0&optimize_on_insert=0&input_format_parallel_parsing=0&max_insert_block_size=10000000&min_insert_block_size_rows=0&min_insert_block_size_bytes=0&deduplicate_insert=disable&query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow" \
      2>> "$OUT/client_errors.log" | grep -v '^200$' >> "$OUT/client_errors.log"
    n=$((n + 1))
  done
}
C2=$(cpu); T2=$(date +%s.%N); E2=$(events)
CLIENT_PIDS=()
for i in $(seq 1 "$CLIENTS"); do client_loop "$i" & CLIENT_PIDS+=($!); done
(
  while [ "$(date +%s)" -lt $END ]; do
    sleep 5
    c -q "SELECT now(), count(), countIf(type = 'GET_PART'), countIf(postpone_reason LIKE '%fetches already executing%'), countIf(is_currently_executing),
                 (SELECT value FROM system.metrics WHERE metric = 'BackgroundFetchesPoolTask'),
                 (SELECT count() FROM system.replicated_fetches),
                 (SELECT count() FROM system.parts WHERE database = 'bench' AND table = 't' AND active)
          FROM system.replication_queue WHERE database = 'bench'" >> "$OUT/queue.tsv" 2>/dev/null
    c -q "SELECT arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), ';') AS s
          FROM system.stack_trace SETTINGS allow_introspection_functions = 1" 2>/dev/null \
      | awk -v t="$(date +%s)" '{print t "\t" $0}' >> "$OUT/stacks.tsv"
  done
) &
SAMPLER=$!
wait "${CLIENT_PIDS[@]}" "$SAMPLER" 2>/dev/null
C3=$(cpu); T3=$(date +%s.%N); E3=$(events)

c -q "SYSTEM FLUSH LOGS"
STATS=$(c -q "
  SELECT count(), sum(written_rows), quantile(0.5)(query_duration_ms), quantile(0.95)(query_duration_ms), quantile(0.99)(query_duration_ms), max(query_duration_ms)
  FROM system.query_log
  WHERE type = 'QueryFinish' AND log_comment = 'pl-load' AND query_kind = 'Insert'
  FORMAT TSV")
ERRS=$(c -q "SELECT count() FROM system.query_log WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing') AND log_comment = 'pl-load'")
QUEUE=$(c -q "SELECT count(), countIf(type = 'GET_PART') FROM system.replication_queue WHERE database = 'bench' FORMAT TSV")
PARTS1=$(c -q "SELECT count() FROM system.parts WHERE database = 'bench' AND table = 't' AND active")
# Wall-clock profile of the inserts: share of samples per top function of interest.
c -q "
  SELECT sym, count() AS samples, round(100 * samples / (SELECT count() FROM system.trace_log WHERE trace_type = 'Real' AND query_id IN (SELECT query_id FROM system.query_log WHERE log_comment = 'pl-load')), 1) AS pct
  FROM
  (
      SELECT arrayFirst(s -> s LIKE '%getMaxPartsCountAndSizeForPartition%' OR s LIKE '%SharedMutex%' OR s LIKE '%lockParts%' OR s LIKE '%readLockParts%'
                          OR s LIKE '%delayInsertOrThrowIfNeeded%' OR s LIKE '%commitPart%', arrayMap(x -> demangle(addressToSymbol(x)), trace)) AS sym
      FROM system.trace_log
      WHERE trace_type = 'Real' AND query_id IN (SELECT query_id FROM system.query_log WHERE log_comment = 'pl-load')
  )
  GROUP BY sym ORDER BY samples DESC LIMIT 15
  SETTINGS allow_introspection_functions = 1" > "$OUT/profile.tsv" 2>&1
read -r N ROWS P50 P95 P99 PMAX <<< "$STATS"
read -r ZT2 ZC2 ZR2 ZE2 <<< "$E2"; read -r ZT3 ZC3 ZR3 ZE3 <<< "$E3"
LOAD_WALL=$(echo "$T3 - $T2" | bc); LOAD_CPU=$(echo "$C3 - $C2" | bc)
echo "$LABEL prefill_wall=$PREFILL_WALL prefill_cpu=$PREFILL_CPU parts_before=$PARTS0 parts_after=$PARTS1 inserts=$N errors=$ERRS rows=$ROWS rows_per_s=$(echo "$ROWS / $LOAD_WALL" | bc) inserts_per_s=$(echo "scale=1; $N / $LOAD_WALL" | bc) p50_ms=$P50 p95_ms=$P95 p99_ms=$P99 max_ms=$PMAX load_cpu=$LOAD_CPU zk_txn=$((ZT3 - ZT2)) zk_create=$((ZC3 - ZC2)) zk_remove=$((ZR3 - ZR2)) zk_exists=$((ZE3 - ZE2)) queue_end=$(echo $QUEUE | tr ' ' '/') out=$OUT" | tee -a "$RES"
