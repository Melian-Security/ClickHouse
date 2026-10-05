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
| `insert-collapse/` | melian/fix-insert-collapse | Server CPU of inserts into `ReplacingMergeTree` with a wide JSON column, `optimize_on_insert` 0 and 1, unique and duplicate keys; `run_all.sh` drives the matrix and `summarize.py` prints medians. |

Usage of each driver is in the header comment of its script.
