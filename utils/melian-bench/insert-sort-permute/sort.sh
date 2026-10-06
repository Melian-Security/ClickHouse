#!/usr/bin/env bash
# Writes a copy of every insert file with its lines sorted by the table's ORDER BY
# (org_id, event_time, id), using ClickHouse's own UUID order. The lines themselves are unchanged.
#
#   sort.sh CLICKHOUSE_BINARY SRC_DIR DST_DIR
set -euo pipefail
BIN=$1; SRC=$(realpath "$2"); DST=$3
mkdir -p "$DST"
for f in "$SRC"/*.jsonl; do
    "$BIN" local -q "
        SELECT line FROM file('$f', LineAsString)
        ORDER BY JSONExtractString(line, 'org_id'),
                 toDateTime(JSONExtractString(line, 'event_time'), 'UTC'),
                 toUUID(JSONExtractString(line, 'id'))
        FORMAT TSVRaw" > "$DST/$(basename "$f")"
done
