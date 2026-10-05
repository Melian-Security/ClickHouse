# path-resolve benchmark

Measures parsing JSON text into the production `event` JSON column (60 typed paths,
`max_dynamic_paths=64`) and inserting it into a compact MergeTree part.

    python3 gen.py 200000 1 > data.jsonl
    ./bench.sh data.jsonl 7 ~/bin/clickhouse-base ~/bin/clickhouse-fix

`gen.py` emits OCSF-like rows from 40 sources; each source has a fixed key template, rows
come in runs per source, ~300 distinct paths overall and ~60 leaves per row, so dynamic
paths overflow into shared data. `bench.sh` alternates binaries and prints wall time per run
for a single-threaded parse (`FORMAT Null`) and a single-threaded MergeTree insert.
