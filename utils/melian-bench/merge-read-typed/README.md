# merge-read-typed

Benchmark of the source-read side of Vertical merges of a `JSON` column with many typed paths
(the reading of Variant, Dynamic, String and Array substreams in `MergeTreeReaderWide` and
`MergeTreeReaderCompact`).

- `schema.sql`: `JSON(max_dynamic_paths = 64, 115 typed paths)` (String, Int64, Bool, UUID,
  Nullable(String), Array(Nullable(String))), `advanced` shared data, `map_with_buckets` zero-level parts.
- `gen.py PART ROWS`: synthetic rows, typed paths with fill rates from 3% to 100% (the rarest are sparse),
  ~250 untyped paths of mixed types, 40-80 per row; timestamps of all parts overlap so a merge interleaves them.
- `gen_parts.sh 8 250000`, then `load.sh 8 250000`: 8 source parts of 250K rows loaded once as Wide parts
  (`$L/bench`) and once as Compact parts (`$L/benchc`).
- `ab_all.sh 5`: 5 alternating base/fix `OPTIMIZE ... FINAL` merges of each variant, servers pinned to cores
  0-7, merge CPU and duration from `system.part_log`, and the md5 of `checksums.txt` and of every file of the
  merged part. The Compact variant sets `min_bytes_for_wide_part = 0` on the merged table (`AFTER_CREATE`), so the
  Compact source parts are merged Vertically into one Wide part.
- `prof.sh BIN NAME VARIANT`: one merge under `perf`, read-side self time of the merge thread.
- `run_test_local.sh TEST.sql`: runs a stateless test with `clickhouse local` for base and fix and diffs the output.

Binaries: `/work/bin/clickhouse-base`, `/work/bin/clickhouse-fix`.
