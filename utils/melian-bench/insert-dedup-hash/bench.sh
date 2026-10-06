#!/usr/bin/env bash
# Insert-deduplication hash benchmark: synchronous JSONEachRow inserts into a ReplicatedReplacingMergeTree
# with a local embedded Keeper.
#
# usage: bench.sh <clickhouse-binary> <data-dir> <mode> <label> [results-file]
#   mode: dedup   deduplicate_insert=enable (the default), block id from the data hash
#         nodedup deduplicate_insert=disable, no block id (insert_deduplicate=0 alone does not disable it:
#                 deduplicate_insert=enable, the default, supersedes it)
#         token   deduplicate_insert=enable, insert_deduplication_token=<file name>, no data hash
#
# Starts a fresh server pinned to $CORES, creates the table, sends every *.jsonl file of <data-dir> as one
# INSERT over HTTP (parsed by the server), with the CPU query profiler at 1 ms. Appends one line:
#   label mode inserts cpu_ms hash_ms total_samples wall_ms hash_computations blocks=<n>:<md5> data=<md5> retry=<rows>
# cpu_ms is User+System time of the inserts from query_log; hash_ms counts 1 ms per CPU sample under
# DeduplicationInfo::calculateDataHashes. blocks is the md5 of the sorted block id names in Keeper
# (equal between binaries means the hash value is unchanged). retry is the row count added by
# re-sending the first three files at the end (0 when retries are deduplicated). With PERF=<perf binary>,
# the server is sampled with perf during the inserts and the inclusive/self shares of the hash functions
# are appended.
set -euo pipefail

BIN=$1
DATA=$2
MODE=$3
LABEL=$4
RESULTS=${5:-/dev/stdout}
HERE=$(cd "$(dirname "$0")" && pwd)
CORES=${CORES:-32-39}
PORT=${PORT:-19500}
HTTP_PORT=${HTTP_PORT:-18500}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/idh-bench.XXXXXX")
RUN=$(basename "$WORK" | tr -c 'a-zA-Z0-9\n' '_')

mkdir -p "$WORK/data" "$WORK/log" "$WORK/tmp" "$WORK/user_files"
sed -e "s#@WORK@#$WORK#g" -e "s#@PORT@#$PORT#g" -e "s#@HTTP_PORT@#$HTTP_PORT#g" \
    -e "s#@IS_PORT@#$((PORT + 9))#g" -e "s#@KEEPER_PORT@#$((PORT + 81))#g" -e "s#@RAFT_PORT@#$((PORT + 82))#g" \
    "$HERE/server.xml" > "$WORK/config.xml"
CLICKHOUSE_WATCHDOG_ENABLE=0 taskset -c "$CORES" "$BIN" server --config-file="$WORK/config.xml" > "$WORK/log/stdout.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

client() { "$BIN" client --port "$PORT" "$@"; }
for _ in $(seq 1 240); do client -q 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done
for _ in $(seq 1 120); do client -q "SELECT count() FROM system.zookeeper WHERE path = '/'" >/dev/null 2>&1 && break; sleep 0.5; done

sed -e "s#{run}#$RUN#" "$HERE/schema.sql" | client --multiquery
client -q 'SYSTEM STOP MERGES bench.t'

case "$MODE" in
    dedup) DEDUP="deduplicate_insert=enable" ;;
    nodedup) DEDUP="deduplicate_insert=disable" ;;
    token) DEDUP="deduplicate_insert=enable" ;;
    *) echo "unknown mode $MODE" >&2; exit 1 ;;
esac

insert() {
    local f=$1 comment=$2 token=""
    [ "$MODE" = token ] && token="&insert_deduplication_token=$(basename "$f" .jsonl)"
    curl -sS --fail-with-body "http://127.0.0.1:$HTTP_PORT/?$DEDUP$token&async_insert=0&log_comment=$comment&query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow" \
        --data-binary "@$f" -H 'Content-Type: application/octet-stream' > /dev/null
}

PERF_PID=
if [ -n "${PERF:-}" ]; then
    "$PERF" record -F 1999 -g -o "$WORK/perf.data" -p "$SERVER_PID" > "$WORK/log/perf.log" 2>&1 &
    PERF_PID=$!
    sleep 2
fi
for f in "$DATA"/*.jsonl; do insert "$f" idh_bench; done
PERF_SHARES=
if [ -n "$PERF_PID" ]; then
    kill -INT "$PERF_PID"; wait "$PERF_PID" || true
    REPORT=$("$PERF" report -i "$WORK/perf.data" --children --stdio --sort symbol --percent-limit 0.05 2>/dev/null | grep -E '^ +[0-9]' || true)
    share() { printf '%s\n' "$REPORT" | grep -F "$1" | head -1 | awk '{print $1 "/" $2}' || true; }
    PERF_SHARES="perf_incl/self:calculateDataHashes=$(share 'DeduplicationInfo::calculateDataHashes'),String=$(share 'ColumnString::updateHashWithValueRange'),Variant=$(share 'ColumnVariant::updateHashWithValueRange'),Array=$(share 'ColumnArray::updateHashWithValueRange')"
    [ -n "${PERF_KEEP:-}" ] && printf '%s\n' "$REPORT" > "$PERF_KEEP"
fi
ROWS_BEFORE=$(client -q 'SELECT count() FROM bench.t')
for f in $(ls "$DATA"/*.jsonl | head -3); do insert "$f" idh_retry; done
RETRY=$(( $(client -q 'SELECT count() FROM bench.t') - ROWS_BEFORE ))

client -q 'SYSTEM FLUSH LOGS'
STATS=$(client -q "
    SELECT count(),
        round(sum(ProfileEvents['UserTimeMicroseconds'] + ProfileEvents['SystemTimeMicroseconds']) / 1e3),
        sum(query_duration_ms),
        sum(ProfileEvents['DuplicationDataHashComputations'])
    FROM system.query_log
    WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND log_comment = 'idh_bench'
    FORMAT TSV")
read -r N CPU_MS WALL_MS HASHES <<< "$STATS"
SAMPLES=$(client --allow_introspection_functions=1 -q "
    WITH (SELECT groupArray(query_id) FROM system.query_log WHERE type = 'QueryFinish' AND log_comment = 'idh_bench') AS ids
    SELECT countIf(arrayExists(a -> demangle(addressToSymbol(a)) LIKE '%DeduplicationInfo::calculateDataHashes%', trace)), count()
    FROM system.trace_log WHERE trace_type = 'CPU' AND has(ids, query_id)
    FORMAT TSV")
read -r HASH_SAMPLES TOTAL_SAMPLES <<< "$SAMPLES"
BLOCKS=$(client -q "SELECT name FROM system.zookeeper WHERE path = '/clickhouse/tables/bench_t_$RUN/deduplication_hashes' ORDER BY name FORMAT TSV")
NBLOCKS=$(printf '%s' "$BLOCKS" | grep -c . || true)
BLOCKS_MD5=$(printf '%s' "$BLOCKS" | md5sum | cut -c1-12)
DATA_MD5=$(client -q 'SELECT * EXCEPT insertion_time FROM bench.t ORDER BY id FORMAT JSONEachRow' | md5sum | cut -c1-12)

echo "$LABEL $MODE $N $CPU_MS $HASH_SAMPLES $TOTAL_SAMPLES $WALL_MS $HASHES blocks=$NBLOCKS:$BLOCKS_MD5 data=$DATA_MD5 retry=$RETRY $PERF_SHARES" >> "$RESULTS"
