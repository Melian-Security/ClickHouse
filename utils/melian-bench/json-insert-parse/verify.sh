#!/usr/bin/env bash
# Checks that two binaries write byte-identical parts for the same inserts.
#
#   verify.sh WORK_DIR DATA_DIR NUM_FILES BIN_A BIN_B
#
# Inserts the first NUM_FILES files of DATA_DIR over HTTP into the same table on a fresh server per
# binary (one part per insert, merges stopped), then compares the md5 of every file of every part,
# and the md5 of the table contents read back as JSONEachRow.
set -euo pipefail
WORK=$1; DATA=$(realpath "$2"); N=$3; shift 3
BINS=("$@")
CORES=${CORES:-16-23}
PORT0=${PORT0:-19600}
HERE=$(dirname "$(realpath "$0")")

EVENT_TYPE=$(grep -m1 "^EVENT_TYPE=" "$HERE/bench.sh" | sed -e "s/^EVENT_TYPE='//" -e "s/'$//")
TABLE_SETTINGS=$(grep -m1 "^TABLE_SETTINGS=" "$HERE/bench.sh" | sed -e 's/^TABLE_SETTINGS="//' -e 's/"$//')

tcp_port() { echo $((PORT0 + 10 * $1)); }
http_port() { echo $((PORT0 + 10 * $1 + 1)); }
client() { local k=$1; shift; "${BINS[$k]}" client --port "$(tcp_port "$k")" "$@"; }

for k in "${!BINS[@]}"; do
    d="$WORK/verify-$k"
    rm -rf "$d" && mkdir -p "$d/data" "$d/tmp" "$d/user_files"
    (cd "$d" && setsid nohup taskset -c "$CORES" "${BINS[$k]}" server --config-file="$HERE/config.xml" -- \
        --path="$d/data/" --tmp_path="$d/tmp/" --user_files_path="$d/user_files/" \
        --logger.log="$d/server.log" --logger.errorlog="$d/server.err.log" \
        --tcp_port="$(tcp_port "$k")" --http_port="$(http_port "$k")" --mysql_port=0 --postgresql_port=0 \
        --interserver_http_port=0 > /dev/null 2>&1 &)
    for _ in $(seq 120); do client "$k" -q 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done
    client "$k" --multiquery -q "
        CREATE DATABASE bench;
        CREATE TABLE bench.t (event $EVENT_TYPE) ENGINE = MergeTree ORDER BY tuple() SETTINGS $TABLE_SETTINGS;
        SYSTEM STOP MERGES bench.t;"
    for f in $(ls "$DATA"/*.native | head -n "$N"); do
        curl -sS --fail-with-body --data-binary @"$f" \
            "http://127.0.0.1:$(http_port "$k")/?query=INSERT%20INTO%20bench.t%20FORMAT%20Native&async_insert=0&optimize_on_insert=0" > /dev/null
    done
    table_path=$(client "$k" -q "SELECT data_paths[1] FROM system.tables WHERE database = 'bench' AND name = 't'")
    (cd "$table_path" && find . -path ./detached -prune -o -type f -print | sort | xargs md5sum) > "$WORK/verify-$k.md5"
    client "$k" -q "SELECT (SELECT count() FROM bench.t), (SELECT uniqExact(arrayJoin(JSONAllPaths(event))) FROM bench.t)" > "$WORK/verify-$k.count"
    client "$k" -q "SELECT event FROM bench.t ORDER BY _part, _part_offset FORMAT JSONEachRow" | md5sum > "$WORK/verify-$k.content"
    client "$k" -q 'SYSTEM SHUTDOWN' > /dev/null 2>&1 || true
done

echo "parts: $(grep -c checksums.txt "$WORK/verify-0.md5") ; files: $(wc -l < "$WORK/verify-0.md5")"
echo "rows, distinct paths: $(cat "$WORK/verify-0.count")"
if cmp -s "$WORK/verify-0.md5" "$WORK/verify-1.md5" && cmp -s "$WORK/verify-0.content" "$WORK/verify-1.content"; then
    echo "IDENTICAL: every part file and the table contents match"
else
    echo "DIFFERENT"
    diff "$WORK/verify-0.md5" "$WORK/verify-1.md5" | head -20 || true
    cat "$WORK/verify-0.content" "$WORK/verify-1.content"
fi
