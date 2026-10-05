# Benchmark kits for the melian/fix-* branches

These kits produced the numbers quoted in the fork PRs. They are kept here, off the PR
branches, so the PRs carry only the change and its upstream-style tests. Each directory has a
synthetic data generator (`gen.py`) and an A/B driver that alternates a base and a fix binary.

| kit | branch | measures |
|---|---|---|
| `json-merge/` | melian/fix-json-merge | One `OPTIMIZE ... FINAL` merge of many parts with a wide JSON column (`advanced` shared data, `map_with_buckets` zero-level parts). Merge duration and user CPU from `system.part_log`, compact and wide parts; `profile.sh` records a system-wide perf profile of the merge. |
| `path-resolve/` | melian/fix-path-resolve | Single-threaded parse of JSON text into a JSON column with typed paths and `max_dynamic_paths=64` (`FORMAT Null`), and a single-threaded MergeTree insert. |
| `surrogates/` | melian/fix-surrogates | Parse and MergeTree insert throughput on clean data (checks the surrogate fallback costs nothing); `repro.sh` reproduces the unpaired-surrogate parse error. |
| `key-strings/` | melian/fix-key-strings | Single-threaded `JSONAsObject` parse into a JSON column, user CPU of `clickhouse local`; then compares the MergeTree parts written by both binaries byte for byte. |
| `dupkey/` | melian/fix-dupkey | JSON-type parsing (parallel and single-thread) and MergeTree insert, wall and CPU time. |
| `issue-93976/` | melian/fix-issue-93976 | PREWHERE ordering of `activity_id = 12 AND <JSON path> = ...` on compact and wide parts: `repro.sh` prints the chosen order and ReadCompressedBytes per binary, `ab.sh` / `ab_server.sh` alternate base and fix (`ab_server.sh` reads `query_duration_ms` from `query_log`), `minimal.sql` is the upstream-issue reproducer, `alter_repro.sh` checks the ALTER-to-v3-serialization report from the same issue. |
| `insert-collapse/` | melian/fix-insert-collapse | Server CPU of inserts into `ReplacingMergeTree` with a wide JSON column, `optimize_on_insert` 0 and 1, unique and duplicate keys; `run_all.sh` drives the matrix and `summarize.py` prints medians. |
| `shared-data-read/` | melian/fix-shared-data-read | Cold reads of a wide JSON column (`advanced` shared data, 32 buckets, Wide parts) from an S3 disk backed by a MinIO container with `tc netem` latency on the docker bridge: sub-object (`event.^unmapped`) point lookups and ranges, shared-data paths, whole `event`, `JSONAllPaths`. `bench.sh setup` loads the data, `run` alternates base and fix with all caches dropped before each query and summarises `query_log` (duration, S3 GETs, prefetches, marks wait), `check` compares query results. |
| `dynamic-serialization/` | melian/fix-dynamic-serialization | Server CPU of concurrent `INSERT ... FORMAT JSONEachRow` over HTTP (the server parses the JSON; `CONC` inserts at once) into the production `event` type with ~300 distinct paths overflowing into shared data (arrays of objects and of strings, date-time strings), then CPU of `OPTIMIZE ... FINAL`; `run.sh` takes an optional `perf record` prefix, `ab.sh` alternates two binaries and `summarize.py` prints medians and content hashes. `micro.sh` runs the queries of the PR's perf test. |

Usage of each driver is in the header comment of its script.
