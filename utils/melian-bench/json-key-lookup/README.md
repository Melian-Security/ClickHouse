# json-key-lookup benchmark

Measures INSERT of JSON text into the production `event` JSON column the way ingestion does it:
one HTTP `INSERT ... FORMAT JSONEachRow` per file of 10,500 rows, `async_insert=0`, into a
MergeTree table with compact parts and the advanced shared-data serialization. Insert CPU per row
is read from `system.query_log` (`UserTimeMicroseconds + SystemTimeMicroseconds`).

`gen.py` is the `path-resolve` generator: OCSF-like rows from 40 sources with fixed key templates,
emitted in runs per source; ~300 distinct paths, 58-76 leaves and ~40 objects per row.

    python3 gen.py 420000 1 | split -l 10500 -d -a 3 --additional-suffix=.jsonl - data/insert_
    CORES=16-23 ./verify.sh work data 10 bin/clickhouse-base bin/clickhouse-fix   # parts byte-identical?
    CORES=16-23 ./bench.sh  work data 6  bin/clickhouse-base bin/clickhouse-fix   # alternating A/B

Both servers are pinned to `$CORES` and use `config.xml` (query_log enabled, merges stopped).
`bench.sh` prints one line per run: binary, run, rows, inserts, CPU us/row, user us/row, wall ms/insert.
