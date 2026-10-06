# insert-sort-permute benchmark

Measures the block sort of an INSERT into a table `ORDER BY (org_id, event_time, id)` with the
production `event` JSON column (`ReplacingMergeTree`, `PARTITION BY (org_id, toStartOfWeek(event_time))`,
compact parts, advanced shared data, `optimize_on_insert=0`). `MergeTreeDataWriter` sorts each insert
block by the key and permutes every column, unless the block is already sorted
(`MergeTreeDataWriterBlocksAlreadySorted`).

`gen.py` takes the events of `../json-key-lookup/gen.py` and adds `org_id`, `event_time` and a random
`id`: one org and one week per file of FILE_ROWS rows, about two rows per second (ties are broken by
`id`), rows in random order. `sort.sh` writes the same lines sorted by the key with ClickHouse's own
UUID order.

    python3 gen.py 420000 1 6000 data/shuffled
    ./sort.sh bin/clickhouse-base data/shuffled data/sorted
    CORES=16-23 ./verify.sh work data/shuffled 20 bin/clickhouse-base bin/clickhouse-fix   # parts byte-identical?
    CORES=16-23 ./bench.sh  work data/shuffled 7  bin/clickhouse-base bin/clickhouse-fix   # end-to-end A/B
    CORES=16-23 ./bench.sh  work data/sorted   7  bin/clickhouse-base bin/clickhouse-fix   # no permute
    CORES=16-23 ./micro.sh  work data/shuffled 7  bin/clickhouse-base bin/clickhouse-fix   # sort stage only

`bench.sh` prints per run: binary, run, rows, inserts, CPU us/row, user us/row, wall ms/insert,
already-sorted blocks, sort us/row. Its numbers are dominated by JSON parsing and differ by 1-2%
between two servers running the same binary, so effects below that need `micro.sh`.

`micro.sh` parses the files once into a Memory table, then times single-threaded
`INSERT INTO <t> SELECT * FROM src` into the sorted table and into the same table `ORDER BY tuple()`
(the difference is the sort and the permutation), plus the queries of
`tests/performance/array_string_permute.xml`. It prints CPU ms and wall ms per binary, run and query.
