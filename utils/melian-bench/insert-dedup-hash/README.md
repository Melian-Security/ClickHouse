# insert-dedup-hash

Cost of the insert deduplication data hash (`DeduplicationInfo::calculateDataHashes`) for synchronous
JSONEachRow inserts of ~10.5k rows (~63 MB) into a ReplicatedReplacingMergeTree with the production JSON
type and an embedded Keeper.

- `gen.py` writes the dataset (one file per INSERT, one partition per file). `insertion_time` is sent
  explicitly: a server-side `DEFAULT now()` column is part of the hashed block, so the same file sent in
  another second gets another block id.
- `bench.sh <bin> <data> dedup|nodedup|token <label> [results]` runs one pass on a fresh server pinned to
  `$CORES`. `nodedup` uses `deduplicate_insert = 'disable'`: on 26.9 `deduplicate_insert = 'enable'` (the
  default) supersedes `insert_deduplicate = 0`. With `PERF=<perf binary>` the server is sampled during the
  inserts and the inclusive/self shares of the hash functions are appended.
- `ab.sh <base> <fix> <out> [runs]` alternates base/fix (dedup) and base nodedup/token; `summarize.py`
  prints medians. The `blocks=` field (md5 of the block ids in Keeper) must match between base and fix.
