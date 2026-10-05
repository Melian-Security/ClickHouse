#!/usr/bin/env bash
# Second report in issue 93976: after switching an existing table to the v3/advanced JSON
# serialization with ALTER ... MODIFY SETTING, inserts fail with
# "Stream event.attacks.Array(JSON(...)).object_shared_data.1.size1 not found" (LOGICAL_ERROR),
# raised from the projection part writer.
#
# Usage: alter_repro.sh <clickhouse-binary> <workdir>
set -uo pipefail
CH=$1; W=$2
rm -rf "$W"; mkdir -p "$W"
L() { "$CH" local --path "$W" "$@"; }

ROW="concat('{\"metadata\":{\"event_code\":\"c', toString(number % 50), '\"},\"attacks\":[',
  arrayStringConcat(arrayMap(i -> concat('{\"name\":\"a', toString(i), '\",\"k', toString((number + i) % 40), '\":', toString(i), '}'), range(1 + number % 3)), ','),
  '],', arrayStringConcat(arrayMap(i -> concat('\"p', toString((number + i) % 100), '\":', toString(i)), range(20)), ','), '}')"

L --query "CREATE DATABASE d"
for PT in wide compact; do
  if [ $PT = wide ]; then PARTS="min_bytes_for_wide_part=0, min_rows_for_wide_part=0"; else PARTS="min_bytes_for_wide_part='1Gi', min_rows_for_wide_part=0"; fi
  for PROJ in proj noproj; do
    T="t_${PT}_${PROJ}"
    P=""; [ $PROJ = proj ] && P=", PROJECTION p (SELECT activity_id, count() GROUP BY activity_id)"
    L --query "CREATE TABLE d.$T (id UInt64, activity_id Int64, event JSON(max_dynamic_paths=48) $P)
      ENGINE = ReplacingMergeTree ORDER BY id
      SETTINGS $PARTS, deduplicate_merge_projection_mode='rebuild', object_serialization_version='v2', dynamic_serialization_version='v2',
               object_shared_data_serialization_version='map', object_shared_data_serialization_version_for_zero_level_parts='map'"
    L --query "INSERT INTO d.$T SELECT number, number % 10, $ROW FROM numbers(10000)"
    L --query "ALTER TABLE d.$T MODIFY SETTING object_serialization_version='v3', dynamic_serialization_version='v3',
               object_shared_data_serialization_version='advanced', object_shared_data_serialization_version_for_zero_level_parts='map_with_buckets'"
    OUT=$(L --query "INSERT INTO d.$T SELECT number, number % 10, $ROW FROM numbers(10000, 10000)" 2>&1) && R=ok || R="FAIL: $(echo "$OUT" | head -c 300)"
    M=$(L --query "OPTIMIZE TABLE d.$T FINAL" 2>&1) && MR=ok || MR="FAIL: $(echo "$M" | head -c 300)"
    C=$(L --query "SELECT count(), sum(cityHash64(toString(event))), any(dynamicType(event.attacks)) FROM d.$T" 2>&1 | tr "\t" " ")
    echo "$T | insert after ALTER: $R | merge: $MR | check: $C"
  done
done
