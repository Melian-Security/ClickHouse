#!/usr/bin/env bash
# A/B benchmark of INSERT parsing JSON text into the production `event` JSON column, done the way
# ingestion does it: one HTTP INSERT ... FORMAT JSONEachRow per file of ~10.5k rows, async_insert=0.
# Insert CPU per row comes from system.query_log (UserTimeMicroseconds + SystemTimeMicroseconds).
#
#   bench.sh WORK_DIR DATA_DIR RUNS BIN_A BIN_B
#
# WORK_DIR gets one server directory per binary. DATA_DIR holds the insert files (see gen.py).
# Both servers are pinned to $CORES (default 16-23); a run inserts every file into one server, and
# runs alternate between the binaries. Background merges are stopped so only inserts use the cores.
# Prints one TSV line per run: binary, run, rows, inserts, CPU us/row, user us/row, wall ms/insert.
set -euo pipefail
WORK=$1; DATA=$(realpath "$2"); RUNS=$3; shift 3
BINS=("$@")
CORES=${CORES:-16-23}
PORT0=${PORT0:-19600}
HERE=$(dirname "$(realpath "$0")")

EVENT_TYPE='JSON(max_dynamic_paths=64, action String, action_id Int64, activity_id Int64, activity_name String, `actor.process.file.name` String, `actor.process.file.path` String, `actor.process.name` String, `actor.user.name` String, `actor.user.type` String, `actor.user.uid` String, auth_protocol String, category_name String, category_uid Int64, class_name String, class_uid Int64, `cloud.account.uid` String, `cloud.provider` String, `cloud.region` String, `connection_info.direction_id` Int64, `connection_info.protocol_name` String, `device.hostname` String, `device.os.type` String, `device.type` String, disposition String, disposition_id Int64, `dst_endpoint.hostname` String, `dst_endpoint.ip` Nullable(String), `dst_endpoint.port` Int64, `file.name` String, `file.path` String, `finding.title` String, `finding.uid` String, `http_request.http_method` String, `http_request.url.hostname` String, logon_type_id Int64, message String, `metadata.event_code` String, `metadata.product.name` String, `metadata.product.vendor_name` String, `metadata.tenant_uid` String, `metadata.uid` UUID, `process.cmd_line` String, `process.file.name` String, `process.file.path` String, `process.name` String, `process.pid` Int64, `query.hostname` String, `query.type` String, `service.name` String, severity String, severity_id Int64, `src_endpoint.hostname` String, `src_endpoint.ip` Nullable(String), `src_endpoint.port` Int64, status String, status_id Int64, type_name String, type_uid Int64, `user.name` String, `user.uid` String)'

TABLE_SETTINGS="min_bytes_for_wide_part = '512Mi', object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced', object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets'"

tcp_port() { echo $((PORT0 + 10 * $1)); }
http_port() { echo $((PORT0 + 10 * $1 + 1)); }
client() { local k=$1; shift; "${BINS[$k]}" client --port "$(tcp_port "$k")" "$@"; }

start_server() { # index
    local k=$1 d="$WORK/srv-$1"
    rm -rf "$d" && mkdir -p "$d/data" "$d/tmp" "$d/user_files"
    (cd "$d" && setsid nohup taskset -c "$CORES" "${BINS[$k]}" server --config-file="$HERE/config.xml" -- \
        --path="$d/data/" --tmp_path="$d/tmp/" --user_files_path="$d/user_files/" \
        --logger.log="$d/server.log" --logger.errorlog="$d/server.err.log" --logger.level=information \
        --tcp_port="$(tcp_port "$k")" --http_port="$(http_port "$k")" --mysql_port=0 --postgresql_port=0 \
        --interserver_http_port=0 > /dev/null 2>&1 &)
    for _ in $(seq 120); do client "$k" -q 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done
    client "$k" --multiquery -q "
        CREATE DATABASE bench;
        CREATE TABLE bench.t (event $EVENT_TYPE) ENGINE = MergeTree ORDER BY tuple() SETTINGS $TABLE_SETTINGS;
        SYSTEM STOP MERGES bench.t;"
}

stop_servers() {
    for k in "${!BINS[@]}"; do client "$k" -q 'SYSTEM SHUTDOWN' > /dev/null 2>&1 || true; done
    sleep 3
}
trap stop_servers EXIT

insert_all() { # index tag
    local k=$1 tag=$2 f
    for f in "$DATA"/*.jsonl; do
        curl -sS --fail-with-body --data-binary @"$f" \
            "http://127.0.0.1:$(http_port "$k")/?query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow&async_insert=0&optimize_on_insert=0&log_comment=$tag" > /dev/null
    done
    client "$k" -q 'TRUNCATE TABLE bench.t'
}

for k in "${!BINS[@]}"; do start_server "$k"; done
for k in "${!BINS[@]}"; do insert_all "$k" warmup; done

for r in $(seq "$RUNS"); do
    # Alternate which binary goes first.
    if (( r % 2 )); then order=("${!BINS[@]}"); else order=($(printf '%s\n' "${!BINS[@]}" | sort -rn)); fi
    for k in "${order[@]}"; do insert_all "$k" "run$r"; done
done

for k in "${!BINS[@]}"; do
    client "$k" -q 'SYSTEM FLUSH LOGS'
    client "$k" --format TSV -q "
        SELECT '${BINS[$k]}', log_comment, sum(written_rows) AS rows, count() AS inserts,
            round((sum(ProfileEvents['UserTimeMicroseconds']) + sum(ProfileEvents['SystemTimeMicroseconds'])) / rows, 3) AS cpu_us_per_row,
            round(sum(ProfileEvents['UserTimeMicroseconds']) / rows, 3) AS user_us_per_row,
            round(avg(query_duration_ms), 1) AS wall_ms_per_insert
        FROM system.query_log
        WHERE type = 'QueryFinish' AND query_kind = 'Insert' AND log_comment LIKE 'run%'
        GROUP BY log_comment ORDER BY toUInt32(substring(log_comment, 4))"
done
