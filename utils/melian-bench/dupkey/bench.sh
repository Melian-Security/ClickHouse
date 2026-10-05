#!/usr/bin/env bash
# JSON-type insert parsing benchmark for the production `event` column.
# Usage: bench.sh CLICKHOUSE_BINARY DATA_FILE MODE   (MODE: parse | insert | parse1)
#   parse  - parse JSONEachRow into the JSON type and discard (parallel parsing, all cores)
#   parse1 - same, single thread and no parallel parsing (cleanest per-row CPU number)
#   insert - parse and insert into a MergeTree with the production shared-data settings
# Prints: mode wall_seconds cpu_seconds(user+sys)
set -euo pipefail
CH=$1
DATA=$2
MODE=$3
HERE=$(cd "$(dirname "$0")" && pwd)
TYPE=$(cat "$HERE/event_type.txt")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case "$MODE" in
  parse)
    Q="SELECT ignore(event) FROM file('$DATA', 'JSONEachRow', 'event $TYPE') FORMAT Null SETTINGS optimize_count_from_files = 0" ;;
  parse1)
    Q="SELECT ignore(event) FROM file('$DATA', 'JSONEachRow', 'event $TYPE') FORMAT Null SETTINGS optimize_count_from_files = 0, max_threads = 1, input_format_parallel_parsing = 0" ;;
  insert)
    Q="CREATE TABLE t (event $TYPE) ENGINE = MergeTree ORDER BY tuple()
         SETTINGS min_bytes_for_wide_part = '512Mi', object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced', object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets';
       INSERT INTO t SELECT * FROM file('$DATA', 'JSONEachRow', 'event $TYPE') SETTINGS optimize_on_insert = 0, max_insert_block_size = 10500, min_insert_block_size_rows = 10500, min_insert_block_size_bytes = 0;" ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac

/usr/bin/time -f "%e %U %S" -o "$TMP/time" "$CH" local --path "$TMP/db" --multiquery -q "$Q" >/dev/null
read -r WALL USR SYS < "$TMP/time"
echo "$MODE $WALL $(echo "$USR + $SYS" | bc)"
