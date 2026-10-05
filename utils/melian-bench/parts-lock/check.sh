#!/usr/bin/env bash
# Correctness check for one binary; compare the output of two binaries.
#   check.sh BIN DATA_DIR
# Inserts every file of DATA_DIR exactly once (16 concurrent clients) on top of a small prefill, then prints
# the row count, a hash of the table contents, the replication queue, and the insert throttling decisions at
# thresholds just below, at and above the number of parts in the largest partition:
#   - parts_to_throw_insert = max, max + 1 (throws / does not throw, with the message);
#   - parts_to_delay_insert = max - 10 with parts_to_throw_insert = max + 100 (the delay in ms);
#   - inactive_parts_to_throw_insert at the outdated count after a merge.
set -uo pipefail
BIN=$1; DATA=$2
K=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /home/ssm-user/plc.XXXX)
mkdir -p "$WORK/data" "$WORK/log"
PORT=39200; KPORT=39281; RPORT=39334; HTTP_PORT=$((PORT + 23))
sed -e "s#@WORK@#$WORK#g" -e "s#@PORT@#$PORT#g" -e "s#@KEEPER_PORT@#$KPORT#g" -e "s#@RAFT_PORT@#$RPORT#g" -e "s#@IS_PORT@#$((PORT + 9))#g" -e "s#@HTTP_PORT@#$((PORT + 23))#g" "$K/server.xml" > "$WORK/config.xml"
CLICKHOUSE_WATCHDOG_ENABLE=0 "$BIN" server --config-file="$WORK/config.xml" > "$WORK/log/stdout.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$WORK"' EXIT
c() { "$BIN" client --port $PORT "$@"; }
for _ in $(seq 240); do c -q 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done
c --multiquery < "$K/schema.sql" || exit 1

c -q "INSERT INTO bench.t (ts, id, p, event) SELECT number, number + 1000000000 * (number % 3), number % 3, '{\"action\":\"prefill\"}'
      FROM numbers(1500) SETTINGS max_block_size = 1, max_insert_block_size = 1, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0, max_insert_threads = 1, deduplicate_insert = 'disable'"
ls "$DATA"/*.jsonl | xargs -P 16 -I{} curl -sS --data-binary @{} "http://localhost:$HTTP_PORT/?optimize_on_insert=0&input_format_parallel_parsing=0&max_insert_block_size=10000000&min_insert_block_size_rows=0&min_insert_block_size_bytes=0&deduplicate_insert=disable&async_insert=0&query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow"
c -q "SYSTEM SYNC REPLICA bench.t"

echo "rows $(c -q 'SELECT count() FROM bench.t')"
echo "hash $(c -q 'SELECT ts, id, p, event FROM bench.t ORDER BY ts, id FORMAT JSONEachRow' | md5sum | cut -c1-16)"
echo "paths_hash $(c -q 'SELECT ts, id, JSONAllPathsWithTypes(event) FROM bench.t ORDER BY ts, id FORMAT JSONEachRow' | md5sum | cut -c1-16)"
echo "parts_per_partition $(c -q "SELECT groupArray((partition_id, c)) FROM (SELECT partition_id, count() c FROM system.parts WHERE database = 'bench' AND table = 't' AND active GROUP BY partition_id ORDER BY partition_id)")"
echo "queue $(c -q "SELECT count() FROM system.replication_queue WHERE database = 'bench'")"

MAX=$(c -q "SELECT max(c) FROM (SELECT count() c FROM system.parts WHERE database = 'bench' AND table = 't' AND active GROUP BY partition_id)")
# The probes insert into partition 11, which has no parts, so they do not change the maximum.
probe() { c -q "INSERT INTO bench.t (ts, id, p, event) SETTINGS async_insert = 0, deduplicate_insert = 'disable'${1:+, $1} VALUES (1, 1, 11, '{}')" 2>&1 | grep -o 'Too many [a-z ]*parts ([^)]*)' | head -n1; }
echo "throw_at_max: $(probe "parts_to_throw_insert = $MAX")"
echo "throw_at_max_plus_1: $(probe "parts_to_throw_insert = $((MAX + 1))")"
c -q "INSERT INTO bench.t (ts, id, p, event) SETTINGS async_insert = 0, deduplicate_insert = 'disable', log_comment = 'delay-probe', parts_to_delay_insert = $((MAX - 10)), parts_to_throw_insert = $((MAX + 100)) VALUES (2, 2, 11, '{}')"
c -q "SYSTEM FLUSH LOGS"
echo "delay_ms: $(c -q "SELECT ProfileEvents['DelayedInsertsMilliseconds'] FROM system.query_log WHERE type = 'QueryFinish' AND log_comment = 'delay-probe'")"

c -q "ALTER TABLE bench.t MODIFY SETTING max_replicated_merges_in_queue = 16"
c -q "OPTIMIZE TABLE bench.t PARTITION 2 FINAL"
OUTDATED=$(c -q "SELECT max(c) FROM (SELECT count() c FROM system.parts WHERE database = 'bench' AND table = 't' AND _state = 'Outdated' GROUP BY partition_id)")
c -q "ALTER TABLE bench.t MODIFY SETTING inactive_parts_to_throw_insert = $OUTDATED"
echo "inactive_throw_at_max: $(probe)"
c -q "ALTER TABLE bench.t MODIFY SETTING inactive_parts_to_throw_insert = $((OUTDATED + 1))"
echo "inactive_throw_at_max_plus_1: $(probe)"
