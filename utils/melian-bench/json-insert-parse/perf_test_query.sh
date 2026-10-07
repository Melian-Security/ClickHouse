#!/usr/bin/env bash
# Times the query of tests/performance/json_parse_shared_data_arrays_of_objects.xml with clickhouse-local, 7 alternating runs per binary, cores 0-7.
set -uo pipefail
Q="CREATE TABLE src (s String) ENGINE = Memory;
INSERT INTO src SELECT '{\"a\":' || toString(number) || ',\"b' || toString(number % 7) || '\":[{\"k\":\"k' || toString(number % 50) || '\",\"v\":' || toString(number % 1000) || '}]' || ',\"c' || toString(number % 5) || '\":[{\"x\":1,\"y\":\"y' || toString(number % 13) || '\"},{\"x\":2,\"z\":[1,2]}]' || ',\"d' || toString(number % 3) || '\":[\"t' || toString(number % 300) || '\"]}' FROM numbers(300000);
SELECT s::JSON(max_dynamic_paths = 1) FROM src FORMAT Null SETTINGS enable_json_type = 1;"
for r in 1 2 3 4 5 6 7; do
  for b in base fix; do
    t=$( { taskset -c 0-7 /work/bin/clickhouse-$b local --time --multiquery -q "$Q" > /dev/null; } 2>&1 | tail -1)
    echo "$b run$r $t"
  done
done
echo PERFXML DONE
