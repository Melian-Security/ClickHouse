#!/usr/bin/env bash
# Insert-time collapse benchmark for ReplacingMergeTree with a wide JSON column.
#
# usage: bench.sh <clickhouse-binary> <data-dir> <optimize_on_insert 0|1> <label> [results-file]
#
# Starts a fresh single-node server from <clickhouse-binary>, creates the table with
# the production `event` column type, inserts every *.jsonl file of <data-dir> as one
# INSERT (one block) over the native protocol, and appends to [results-file] a line:
#   label ooi inserts total_cpu_ms total_collapse_ms total_wall_ms result_hash dynamic_paths_hash
# where result_hash is the md5 of the table content in sorting key order (no FINAL, so
# the in-part collapse is visible) and of the FINAL content after OPTIMIZE ... FINAL.
set -euo pipefail

BIN=$1
DATA=$2
OOI=$3
LABEL=$4
RESULTS=${5:-/dev/stdout}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/ic-bench.XXXXXX)
PORT=${PORT:-19000}

mkdir -p "$WORK/data" "$WORK/log"
sed -e "s#@WORK@#$WORK#g" -e "s#@PORT@#$PORT#g" "$HERE/server.xml" > "$WORK/config.xml"
"$BIN" server --config-file="$WORK/config.xml" > "$WORK/log/stdout.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

client() { "$BIN" client --port "$PORT" "$@"; }
for _ in $(seq 1 120); do client -q 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done

client --multiquery < "$HERE/schema.sql"
client -q 'SYSTEM STOP MERGES bench.t'

for f in "$DATA"/*.jsonl; do
    client --query "INSERT INTO bench.t SETTINGS optimize_on_insert = $OOI, log_comment = 'ic_bench',
        max_insert_block_size = 10000000, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0,
        input_format_parallel_parsing = 0, insert_deduplicate = 0 FORMAT JSONEachRow" < "$f"
done

client -q 'SYSTEM FLUSH LOGS'
STATS=$(client -q "
    SELECT count(),
        round(sum(ProfileEvents['UserTimeMicroseconds'] + ProfileEvents['SystemTimeMicroseconds']) / 1e3),
        round(sum(ProfileEvents['MergeTreeDataWriterMergingBlocksMicroseconds']) / 1e3),
        sum(query_duration_ms)
    FROM system.query_log
    WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND log_comment = 'ic_bench'
    FORMAT TSV" | tr '\t' ' ')

RAW_HASH=$(client -q 'SELECT ts, id, event FROM bench.t ORDER BY ts, id FORMAT JSONEachRow' | md5sum | cut -c1-12)
PATHS_HASH=$(client -q 'SELECT _part, arraySort(groupUniqArrayArray(JSONDynamicPaths(event))) FROM bench.t GROUP BY _part ORDER BY _part FORMAT TSV' | md5sum | cut -c1-12)
client -q 'SYSTEM START MERGES bench.t'
client -q 'OPTIMIZE TABLE bench.t FINAL'
FINAL_HASH=$(client -q 'SELECT ts, id, event FROM bench.t ORDER BY ts, id FORMAT JSONEachRow' | md5sum | cut -c1-12)

echo "$LABEL ooi=$OOI $STATS raw=$RAW_HASH final=$FINAL_HASH paths=$PATHS_HASH" >> "$RESULTS"
