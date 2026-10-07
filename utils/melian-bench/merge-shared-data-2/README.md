# merge-shared-data-2

A/B for Melian-Security/ClickHouse#32 (JSON shared data written in merges: mark getter and substream names once per
block/part, prefetch of scattered values, direct String/number values into shared data in the gather).

Uses the `shared-data-gather` kit: 8 parts of 500K rows of OCSF-like JSON (`JSON(max_dynamic_paths=64, ~60 typed
paths)`, `advanced` shared data, zero-level parts in `map_with_buckets`), one Vertical `OPTIMIZE ... FINAL` merge into
one Wide part of 4M rows, servers pinned to `CPUS`, alternating base/fix, with a byte-identity check of the merged part.

    bash ab.sh /work/bin/clickhouse-base /work/bin/clickhouse-fix 5

Result on a c8g.24xlarge (cores 0-7), RelWithDebInfo, base = 26.9.9.28-melian.9 (fbdd4cf6):

| | base median [min, max] | fix median [min, max] | change |
|---|---|---|---|
| user CPU | 119.94 s [119.61, 120.12] | 116.53 s [116.32, 116.77] | -2.8% |
| wall | 121.23 s [120.98, 122.00] | 118.11 s [117.91, 118.36] | -2.6% |

All 10 merged parts have the same `checksums.txt` and file hashes.

Profiles: `bash ../shared-data-gather/bench.sh prof BIN NAME` with `PERF` set (writes `prof-NAME-{self,incl}.txt`).
