#!/usr/bin/env bash
# Isolates the block sort of an INSERT: the insert files are parsed once into a Memory table (one block of
# FILE_ROWS rows per file), then `INSERT INTO dst SELECT * FROM src` is timed single-threaded into
#   sorted   - the ORDER BY (org_id, event_time, id) table: sort + permute of every column + write,
#   unsorted - the same table with ORDER BY tuple(): write only,
# plus the queries of tests/performance/array_string_permute.xml. Runs alternate between the binaries.
# Prints one TSV line per binary, run and query: CPU ms (user + system) and wall ms from query_log.
#
#   micro.sh WORK_DIR DATA_DIR RUNS BIN_A BIN_B
set -euo pipefail
WORK=$1; DATA=$(realpath "$2"); RUNS=$3; shift 3
BINS=("$@")
CORES=${CORES:-16-23}
PORT0=${PORT0:-19800}
HERE=$(dirname "$(realpath "$0")")
EVENT_TYPE=$(grep -m1 "^EVENT_TYPE=" "$HERE/bench.sh" | sed -e "s/^EVENT_TYPE='//" -e "s/'$//")
TABLE_SETTINGS=$(grep -m1 "^TABLE_SETTINGS=" "$HERE/bench.sh" | sed -e 's/^TABLE_SETTINGS="//' -e 's/"$//')
COLUMNS="org_id String, event_time DateTime('UTC'), id UUID, event $EVENT_TYPE"
ONE_THREAD="max_threads = 1, max_insert_threads = 1, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0, optimize_on_insert = 0"

tcp_port() { echo $((PORT0 + 10 * $1)); }
http_port() { echo $((PORT0 + 10 * $1 + 1)); }
client() { local k=$1; shift; "${BINS[$k]}" client --port "$(tcp_port "$k")" "$@"; }

start_server() {
    local k=$1 d="$WORK/micro-$1"
    rm -rf "$d" && mkdir -p "$d/data" "$d/tmp" "$d/user_files"
    (cd "$d" && setsid nohup taskset -c "$CORES" "${BINS[$k]}" server --config-file="$HERE/config.xml" -- \
        --path="$d/data/" --tmp_path="$d/tmp/" --user_files_path="$d/user_files/" \
        --logger.log="$d/server.log" --logger.errorlog="$d/server.err.log" \
        --tcp_port="$(tcp_port "$k")" --http_port="$(http_port "$k")" --mysql_port=0 --postgresql_port=0 \
        --interserver_http_port=0 > /dev/null 2>&1 &)
    for _ in $(seq 120); do client "$k" -q 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done
    client "$k" --multiquery -q "
        CREATE DATABASE bench;
        CREATE TABLE bench.src ($COLUMNS) ENGINE = Memory;
        CREATE TABLE bench.sorted ($COLUMNS) ENGINE = ReplacingMergeTree
            PARTITION BY (org_id, toStartOfWeek(event_time)) ORDER BY (org_id, event_time, id) SETTINGS $TABLE_SETTINGS;
        CREATE TABLE bench.unsorted ($COLUMNS) ENGINE = ReplacingMergeTree
            PARTITION BY (org_id, toStartOfWeek(event_time)) ORDER BY tuple() SETTINGS $TABLE_SETTINGS;
        SYSTEM STOP MERGES;
        CREATE TABLE bench.arr (key UInt64, s Array(String), t Array(Tuple(String, String)), m Map(String, String)) ENGINE = Memory;
        INSERT INTO bench.arr SELECT cityHash64(number),
            arrayMap(x -> concat('value_', toString(number % 1000 + x)), range(number % 50)),
            arrayMap(x -> (concat('path.', toString(x)), toString(number + x)), range(number % 50)),
            mapFromArrays(arrayMap(x -> concat('key_', toString(x)), range(number % 20)), arrayMap(x -> toString(number * x), range(number % 20)))
        FROM numbers(1000000);
        CREATE TABLE bench.arr_dst AS bench.arr ENGINE = MergeTree ORDER BY key;"
    local f
    for f in "$DATA"/*.jsonl; do
        curl -sS --fail-with-body --data-binary @"$f" \
            "http://127.0.0.1:$(http_port "$k")/?query=INSERT%20INTO%20bench.src%20FORMAT%20JSONEachRow" > /dev/null
    done
}

stop_servers() {
    for k in "${!BINS[@]}"; do client "$k" -q 'SYSTEM SHUTDOWN' > /dev/null 2>&1 || true; done
    sleep 3
}
trap stop_servers EXIT

run_once() { # index run
    local k=$1 r=$2 t
    for t in sorted unsorted; do
        client "$k" -q "INSERT INTO bench.$t SELECT * FROM bench.src SETTINGS $ONE_THREAD, log_comment = '$r:$t'"
        client "$k" -q "TRUNCATE TABLE bench.$t"
    done
    client "$k" -q "SELECT s FROM bench.arr ORDER BY key LIMIT 100000 FORMAT Null SETTINGS max_threads = 1, log_comment = '$r:arr_s'"
    client "$k" -q "SELECT t FROM bench.arr ORDER BY key LIMIT 100000 FORMAT Null SETTINGS max_threads = 1, log_comment = '$r:arr_t'"
    client "$k" -q "INSERT INTO bench.arr_dst SELECT * FROM bench.arr SETTINGS $ONE_THREAD, log_comment = '$r:arr_insert'"
    client "$k" -q "TRUNCATE TABLE bench.arr_dst"
}

for k in "${!BINS[@]}"; do start_server "$k"; done
for k in "${!BINS[@]}"; do run_once "$k" warmup; done
for r in $(seq "$RUNS"); do
    if (( r % 2 )); then order=("${!BINS[@]}"); else order=($(printf '%s\n' "${!BINS[@]}" | sort -rn)); fi
    for k in "${order[@]}"; do run_once "$k" "run$r"; done
done

for k in "${!BINS[@]}"; do
    client "$k" -q 'SYSTEM FLUSH LOGS'
    client "$k" --format TSV -q "
        SELECT '${BINS[$k]}', splitByChar(':', log_comment)[1] AS run, splitByChar(':', log_comment)[2] AS q,
            round((ProfileEvents['UserTimeMicroseconds'] + ProfileEvents['SystemTimeMicroseconds']) / 1000, 1) AS cpu_ms,
            query_duration_ms AS wall_ms
        FROM system.query_log
        WHERE type = 'QueryFinish' AND log_comment LIKE 'run%'
        ORDER BY q, toUInt32(substring(run, 4))"
done
