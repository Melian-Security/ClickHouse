#!/usr/bin/env bash
# A/B benchmark: JSON text -> production `event` JSON column.
#   bench.sh DATA.jsonl RUNS BIN_A BIN_B ...
# Runs alternate between binaries. Prints one line per run: binary query seconds.
#   parse : JSONEachRow parse into the JSON column only (1 thread, no parallel parsing)
#   insert: INSERT into a MergeTree table (compact part, default JSON serialization settings)
set -euo pipefail
DATA=$(realpath "$1"); RUNS=$2; shift 2

EVENT_TYPE='JSON(max_dynamic_paths=64, action String, action_id Int64, activity_id Int64, activity_name String, `actor.process.file.name` String, `actor.process.file.path` String, `actor.process.name` String, `actor.user.name` String, `actor.user.type` String, `actor.user.uid` String, auth_protocol String, category_name String, category_uid Int64, class_name String, class_uid Int64, `cloud.account.uid` String, `cloud.provider` String, `cloud.region` String, `connection_info.direction_id` Int64, `connection_info.protocol_name` String, `device.hostname` String, `device.os.type` String, `device.type` String, disposition String, disposition_id Int64, `dst_endpoint.hostname` String, `dst_endpoint.ip` Nullable(String), `dst_endpoint.port` Int64, `file.name` String, `file.path` String, `finding.title` String, `finding.uid` String, `http_request.http_method` String, `http_request.url.hostname` String, logon_type_id Int64, message String, `metadata.event_code` String, `metadata.product.name` String, `metadata.product.vendor_name` String, `metadata.tenant_uid` String, `metadata.uid` UUID, `process.cmd_line` String, `process.file.name` String, `process.file.path` String, `process.name` String, `process.pid` Int64, `query.hostname` String, `query.type` String, `service.name` String, severity String, severity_id Int64, `src_endpoint.hostname` String, `src_endpoint.ip` Nullable(String), `src_endpoint.port` Int64, status String, status_id Int64, type_name String, type_uid Int64, `user.name` String, `user.uid` String)'

SETTINGS="SETTINGS max_threads=1, input_format_parallel_parsing=0, max_insert_block_size=10500, min_insert_block_size_rows=0, min_insert_block_size_bytes=0, optimize_on_insert=0"

q_parse="SELECT * FROM file('$DATA', JSONEachRow, 'event $EVENT_TYPE') FORMAT Null $SETTINGS"
q_insert="CREATE TABLE t (event $EVENT_TYPE) ENGINE=MergeTree ORDER BY tuple() SETTINGS min_bytes_for_wide_part='512Mi', min_rows_for_wide_part=1000000000;
INSERT INTO t SELECT * FROM file('$DATA', JSONEachRow, 'event $EVENT_TYPE') $SETTINGS;"

run() { # bin name query
    local tmp; tmp=$(mktemp -d)
    local s e
    s=$(date +%s.%N)
    "$1" local --path "$tmp" --multiquery "$3" >/dev/null
    e=$(date +%s.%N)
    rm -rf "$tmp"
    echo "$1 $2 $(echo "$e - $s" | bc)"
}

for bin in "$@"; do run "$bin" parse "$q_parse" >/dev/null; done  # warm-up
for i in $(seq "$RUNS"); do
    for q in parse insert; do
        for bin in "$@"; do
            if [ $q = parse ]; then run "$bin" parse "$q_parse"; else run "$bin" insert "$q_insert"; fi
        done
    done
done
