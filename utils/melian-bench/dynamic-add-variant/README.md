# dynamic-add-variant

INSERT CPU spent in `ColumnDynamic::addNewVariant` while parsing JSON text into the `event` JSON column.
It reuses the `json-key-lookup` kit unchanged: same data, server config, table and A/B protocol (HTTP
`INSERT ... FORMAT JSONEachRow`, 40 files of 10,500 rows, `async_insert=0`, CPU per row from `system.query_log`).

Layout used on the build pod (`/work/dav/kit` = `../json-key-lookup`, binaries in `/work/bin`):

    python3 kit/gen.py 420000 1 | split -l 10500 -d -a 3 --additional-suffix=.jsonl - data/insert_
    CORES=0-15 kit/verify.sh run data 10 /work/bin/clickhouse-base /work/bin/clickhouse-fix   # byte-identical parts
    CORES=0-15 kit/bench.sh  run data 8  /work/bin/clickhouse-base /work/bin/clickhouse-fix   # alternating A/B
    ./profile.sh base|fix      # perf: top self symbols and the inclusive share of addNewVariant & co.
    ./breakdown.sh base|fix    # callees / leaves / callers of addNewVariant in that perf.data

`profile.sh` and `breakdown.sh` hard-code `/work/dav` and `/work/bin`; adjust `L`/`B` for another layout.

Result (c8g.24xlarge, 26.9.9.28 base 45fbd37d vs `melian/fix-dynamic-add-variant`, 8 alternating runs):

| | CPU us/row median (min-max) | wall ms/insert median |
|---|---|---|
| base | 53.03 (52.84-53.24) | 576.0 |
| fix | 46.35 (46.10-46.71) | 505.4 |

-12.6% insert CPU/row. perf: `addNewVariant` inclusive 13.5% -> 6.7% of the insert profile.
`verify.sh`: IDENTICAL (10 parts, 101 files, table contents).
