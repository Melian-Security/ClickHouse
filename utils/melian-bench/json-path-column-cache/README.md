# json-path-column-cache benchmark

Measures the per-leaf path resolution of JSON text parsing into a JSON column (typed path, dynamic path or
shared data), which branch `melian/fix-json-path-column-cache` replaces with a per-position path cache.

Insert benchmark and byte-identical check: reuse `../json-key-lookup` (JSONEachRow over HTTP, 10,500 rows per insert,
`async_insert=0`, the production-shaped JSON type, rows in runs per source):

    python3 ../json-key-lookup/gen.py 420000 1 | split -l 10500 -d -a 3 --additional-suffix=.jsonl - data/insert_
    CORES=16-23 ../json-key-lookup/verify.sh work data 10 bin/clickhouse-base bin/clickhouse-fix
    CORES=16-23 ../json-key-lookup/bench.sh  work data 6  bin/clickhouse-base bin/clickhouse-fix

Profile of the inserts (CPU query profiler, trace_log): `profile.sh work data bin/clickhouse-base`.

Best and worst case for the cache, from the two performance tests of the source tree (`CAST(String AS JSON)` in
clickhouse local): `perftests.sh <source dir> 5 bin/clickhouse-base bin/clickhouse-fix`.
`json_parse_typed_and_dynamic_paths` changes the key template on every row, so the cache misses for most paths;
`json_parse_runs_of_same_keys` has runs of 100 rows with the same keys.

Results on a c8g.24xlarge, servers pinned to 8 cores, 26.9.9.28 + fork #17 as base:

| | base | fix | change |
|---|---|---|---|
| kit insert CPU, us/row (median of 6) | 51.53 (51.28-51.68) | 48.47 (48.31-48.68) | -5.9% |
| kit wall, ms/insert (median of 6) | 559.7 | 527.7 | -5.7% |
| json_parse_runs_of_same_keys, s (median of 5) | 0.371 | 0.323 | -13% |
| json_parse_typed_and_dynamic_paths, s (median of 5) | 0.514 | 0.518 | +0.8% (noise) |

All 10 verify parts and the table contents were byte-identical.
