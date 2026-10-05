#!/usr/bin/env bash
# The two queries of tests/performance/json_shared_data_dynamic_values.xml in `clickhouse local`,
# alternating two binaries; prints wall and user time per query.
#
# usage: micro.sh <bin-a> <bin-b> [runs]
set -euo pipefail
A=$1; B=$2; N=${3:-5}
P=$(mktemp -d /tmp/dynser-micro.XXXX)
trap 'rm -rf "$P"' EXIT
F="INSERT INTO src SELECT concat('{\"id\":', toString(number), ',\"tags\":[\"a\",\"b\",\"c\"],\"items\":[', arrayStringConcat(arrayMap(i -> concat('{\"k\":', toString(number + i), ',\"s\":\"v', toString(i), '\",\"f\":1.5,\"b\":true}'), range(5)), ','), ']}') FROM numbers(300000)"
"$A" local --path "$P" -q "CREATE TABLE src (s String) ENGINE = MergeTree ORDER BY tuple(); CREATE TABLE dst (j JSON(max_dynamic_paths = 2)) ENGINE = Null; $F; OPTIMIZE TABLE src FINAL"
for _ in $(seq "$N"); do
  for b in "$A" "$B"; do
    /usr/bin/time -f "$b q1 wall=%e user=%U" "$b" local --path "$P" -q "INSERT INTO dst SELECT s FROM src"
    /usr/bin/time -f "$b q2 wall=%e user=%U" "$b" local --path "$P" -q "SELECT count() FROM src WHERE NOT ignore(s::JSON(max_dynamic_paths = 0))" > /dev/null
  done
done
