#!/usr/bin/env bash
# PREWHERE ordering of a small-column predicate against a JSON-path predicate (upstream issue 93976).
#
# Usage: repro.sh <clickhouse-binary> <workdir> [rows] [extra table settings, e.g. ", auto_statistics_types=''"]
#
# Builds tables with a wide JSON column (synthetic data, ~60 nested paths per row out of 300) and,
# for each table, runs `count()` with `activity_id = 12` (inside the min/max of activity_id, never true) combined with a JSON-path
# predicate, written in both orders, with allow_reorder_prewhere_conditions 0 and 1. Prints the
# PREWHERE filter the optimizer chose, the best of 3 wall times and ReadCompressedBytes.
# The bug shows as the JSON predicate being evaluated first, i.e. reading the whole JSON column.
set -euo pipefail
CH=$1; W=$2; ROWS=${3:-1000000}; EXTRA=${4:-}
rm -rf "$W"; mkdir -p "$W"
L() { "$CH" local --path "$W" "$@"; }

GEN="concat('{\"metadata\":{\"event_code\":\"c', toString(number % 50), '\",\"uid\":\"', toString(generateUUIDv4(number)), '\"},',
  arrayStringConcat(arrayMap(i -> concat('\"g', toString((number * 7 + i * 13) % 300), '\":{\"v\":\"', repeat('v', 10 + i % 20), toString(number % 1000), '\"}'), range(60)), ','),
  '}')"
SETS="object_serialization_version='v3', dynamic_serialization_version='v3', object_shared_data_serialization_version='advanced', object_shared_data_serialization_version_for_zero_level_parts='map_with_buckets'"
TYPED="JSON(max_dynamic_paths=64, \`metadata.event_code\` String, \`metadata.uid\` UUID)"

L --query "CREATE DATABASE IF NOT EXISTS d"
# t_issue_*: the issue's column (max_dynamic_paths=0: every path lives in shared data).
# t_ours_*:  max_dynamic_paths=64 with typed paths. *_compact keeps every part compact (production: compact below 512 MiB).
for spec in \
  "t_issue_wide|JSON(max_dynamic_paths=0)|min_bytes_for_wide_part=0, min_rows_for_wide_part=0" \
  "t_issue_compact|JSON(max_dynamic_paths=0)|min_bytes_for_wide_part='10Gi'" \
  "t_ours_compact|$TYPED|min_bytes_for_wide_part='10Gi'" \
  "t_ours_wide|$TYPED|min_bytes_for_wide_part=0, min_rows_for_wide_part=0" \
  ; do
  IFS='|' read -r T TYPE PARTS <<<"$spec"
  L --query "CREATE TABLE d.$T (id UInt64, raw String, activity_id Int64, event $TYPE, event_time DateTime('UTC'))
    ENGINE = ReplacingMergeTree ORDER BY (event_time, id) SETTINGS $PARTS, $SETS $EXTRA"
  L --query "INSERT INTO d.$T SELECT number, repeat('r', 50), 1 + 2 * (number % 10), $GEN, toDateTime('2026-01-01', 'UTC') + number
    FROM numbers($ROWS) SETTINGS max_block_size=100000, min_insert_block_size_rows=100000, min_insert_block_size_bytes=0, max_insert_threads=4"
done
L --query "SELECT table, part_type, count() parts, sum(rows) rows, formatReadableSize(sum(data_compressed_bytes)) size FROM system.parts WHERE database='d' AND active GROUP BY 1,2 ORDER BY 1"
L --query "SELECT table, column, formatReadableSize(sum(column_data_compressed_bytes)) FROM system.parts_columns WHERE database='d' AND active AND column IN ('activity_id','event') GROUP BY 1,2 ORDER BY 1,2"

for T in t_issue_wide t_issue_compact t_ours_compact t_ours_wide; do
  for COND in "activity_id = 12 AND event.metadata.event_code = 'no-such-code'" \
              "event.metadata.event_code = 'no-such-code' AND activity_id = 12" \
              "event.g95.v = 'no-such-value' AND activity_id = 12"; do
    for R in 0 1; do
      Q="SELECT count() FROM d.$T WHERE $COND SETTINGS allow_reorder_prewhere_conditions=$R"
      PW=$(L --query "EXPLAIN actions=1 $Q" | grep -m1 'Prewhere filter column' | sed 's/.*column: //; s/ (removed)//' || true)
      BEST=999
      for _ in 1 2 3; do
        S=$(date +%s.%N); L --query "$Q" >/dev/null; E=$(date +%s.%N)
        BEST=$(python3 -c "print(min($BEST, $E - $S))")
      done
      BYTES=$(L --query "$Q" --print-profile-events --profile-events-delay-ms=-1 2>&1 | grep -m1 -o 'ReadCompressedBytes: [0-9]*' || true)
      printf '%s | reorder=%s | %.3fs | %s | PREWHERE %s\n' "$T" "$R" "$BEST" "$BYTES" "$PW"
    done
  done
done
