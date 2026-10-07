# merge-gather-copy

Benchmark for `melian/fix-merge-gather-copy` (JSON gather plans kept between the `gather` calls that fill one block
of a Vertical merge; source `Variant` columns resolved once per plan).

`IColumn::gather` returns whenever a source needs its next block, and a source block is one granule, so the cost
that was paid per call grows with the number of source parts. The merge therefore uses many smaller parts than
`../shared-data-gather/` (same generator, schema and runner, same 8M rows):

    bash ../shared-data-gather/bench.sh load BIN_BASE BIN_BASE 32 250000   # 32 Wide parts, 8.18 GiB
    bash ../shared-data-gather/bench.sh run  BIN_BASE BIN_FIX 5            # also checks checksums.txt + every file md5

Result (8 pinned cores, 5 alternating runs, median [min, max]):

| | duration | user CPU |
|---|---|---|
| base (melian.9) | 276.0 s [274.7, 276.1] | 271.9 s [271.3, 272.8] |
| fix | 270.9 s [269.5, 271.2] | 267.6 s [265.9, 267.6] |

-1.8% duration, -1.6% user CPU, identical merged parts. With the 8 x 1M-row parts of `shared-data-gather` the
first change alone made no measurable difference in one run.

`partcheck.sh [fix-binary-suffix]` runs the tables of stateless tests `05484`, `05512`, `05536` and `05542` on a base
and a fix server under four pairs of block limits (`merge_max_block_size`, `merge_max_block_size_bytes`) and diffs
`hash_of_all_files` of the merged parts. Paths assume binaries in /work/bin and the source tree in /work/src.
