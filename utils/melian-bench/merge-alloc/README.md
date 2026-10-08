# merge-alloc

A/B for `melian/fix-merge-alloc` (columns read by a merge shrunk only when that releases at least half of their
memory; JSON shared data collected from buckets and paths flattened from shared data allocated at their final size).

Uses the `shared-data-gather` kit: 8 Wide parts of 500K rows of OCSF-like JSON (`JSON(max_dynamic_paths=64, ~60 typed
paths)`, `advanced` shared data, zero-level parts in `map_with_buckets`), one Vertical `OPTIMIZE ... FINAL` merge into
one Wide part of 4M rows, servers pinned to `CPUS`, alternating base/fix, with a byte-identity check of the merged part.

    bash ab.sh /work/bin/clickhouse-base /work/bin/clickhouse-fix 5

Result on a c8g.24xlarge (cores 8-15), RelWithDebInfo, base = 26.9.9.28-melian.10 (2cdd69a6):

| | base median [min, max] | fix median [min, max] | change |
|---|---|---|---|
| user CPU | 112.85 s [112.59, 113.06] | 110.63 s [110.45, 110.79] | -2.0% |
| wall | 114.24 s [114.14, 114.47] | 112.07 s [111.91, 112.37] | -1.9% |
| merge peak memory | 1.759 GB | 1.796 GB | +2.1% |

All 10 merged parts have the same `checksums.txt` and file hashes.

`realloc-callers.sh PERF_DATA [REGEX]` groups the merge-thread samples of a `perf record -g` file (for example from
`bash ../shared-data-gather/bench.sh prof BIN NAME`) whose stack contains `REGEX` (default `do_rallocx`) by the first
three frames above the allocator. Stacks with `do_rallocx`: 2.20% of merge-thread samples on base, 1.22% with the fix.
