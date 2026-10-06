# object-columnwise-gather

Benchmark for `melian/fix-object-columnwise-gather` (JSON columns gathered path by path in Vertical merges).

Merge timing reuses `../shared-data-gather/` unchanged: Vertical `OPTIMIZE ... FINAL` of 8 Wide parts x 1M rows,
interleaved sources, `JSON(max_dynamic_paths=64, ~60 typed paths)`, advanced shared-data serialization.

    bash ../shared-data-gather/bench.sh load BIN_BASE BIN_BASE 8 1000000
    bash ../shared-data-gather/bench.sh run  BIN_BASE BIN_FIX 5      # also checks checksums.txt + every file md5

`partcheck.sh [fix-binary-suffix]` runs the tables of stateless test `05484_json_vertical_merge_gather_by_path`
on a base and a fix server under four pairs of block limits (`merge_max_block_size`, `merge_max_block_size_bytes`),
including 1-byte limits that end almost every batch at the byte limit, and diffs `hash_of_all_files` of the merged
parts. Paths assume binaries in /work/bin and the source tree in /work/src.
