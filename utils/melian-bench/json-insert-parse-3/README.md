# json-insert-parse-3

INSERT CPU of parsing JSON text into the `event` JSON column when values go to JSON shared data: arrays of
objects whose objects get new `Dynamic` paths in a temporary column, and `SerializationDynamic::serializeBinary`
of their values. It reuses the `json-insert-parse` kit (`../json-insert-parse/`: same data, server config,
table, Native-over-HTTP inserts and A/B protocol), with date inference off as in the inserts it models:

    sed -i 's/&async_insert=0/\&input_format_try_infer_dates=0\&input_format_try_infer_datetimes=0\&async_insert=0/' kit/bench.sh kit/verify.sh
    python3 kit/gen.py 420000 1 | split -l 10500 -d -a 3 --additional-suffix=.jsonl - data/insert_
    # convert each .jsonl to Native with --output_format_native_write_json_as_string=1 (see ../json-insert-parse/)
    CORES=0-15 kit/verify.sh work data 40 /work/bin/clickhouse-base /work/bin/clickhouse-fix   # byte-identical parts
    CORES=0-15 kit/bench.sh  work data 6  /work/bin/clickhouse-base /work/bin/clickhouse-fix   # alternating A/B
    ./perf_test_query.sh work/local 7 /work/bin/clickhouse-base /work/bin/clickhouse-fix     # perf test query, 1 thread

Result (c8g.24xlarge, 26.9.9.28 base 2cdd69a6 vs `melian/fix-json-insert-parse-3`):

| | CPU us/row median (min-max), 6 runs | wall ms/insert median | perf test query CPU s median (min-max), 7 runs |
|---|---|---|---|
| base | 29.89 (29.67-30.13) | 317.6 | 2.930 (2.838-2.960) |
| fix | 28.22 (28.06-28.38) | 300.2 | 2.754 (2.581-2.833) |

-5.6% insert CPU/row, -6.0% on the perf test query. `verify.sh`: IDENTICAL (40 parts, 401 files, table contents).
