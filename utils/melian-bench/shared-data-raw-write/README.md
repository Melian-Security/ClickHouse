# shared-data-raw-write

A/B of a Vertical merge of 8 Wide parts (8M rows, 8.15 GiB) with the production JSON type and advanced
shared data, for the change that copies single-type shared data paths without reading them into Dynamic
columns. Data and schema come from `../shared-data-write` (gen.py, schema.sql).

    bench.sh load BIN_BASE BIN_FIX 8 1000000   # build the source parts once, cloned for both servers
    bench.sh run  BIN_BASE BIN_FIX 5           # alternate base/fix merges; part_log CPU + checksums of the merged part
    PERF=/usr/lib/linux-tools/<ver>/perf bench.sh prof BIN NAME
    perf script -i $WORK/perf-NAME.data -F comm,ip,sym | python3 stacks.py serializeChunkBucketData

Differences from `../shared-data-write/bench.sh`: the merge is not started with `OPTIMIZE ... FINAL` (it
races the merge that `SYSTEM START MERGES` schedules and times out); the script waits for that merge.
