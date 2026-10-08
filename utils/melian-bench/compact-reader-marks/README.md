# compact-reader-marks

Benchmark for `melian/fix-compact-reader-marks` (the Compact reader no longer looks up a stream file in the
checksums, twice, for every substream of every granule to get an average value size hint that a Compact part
never has).

Data and merge runner are `../merge-stream-naming/` with its Compact-source schema (62 ordinary columns + the
JSON column, Vertical merge into Wide), 24 parts of 60K rows (1.83 GiB):

    for p in $(seq 0 23); do python3 ../merge-stream-naming/gen.py $p 60000 > gen/part_$p.jsonl & done; wait
    WORK=/work/crm/bench CPUS=0-15 GEN_DIR=gen SCHEMA=schema-cvw.sql \
        bash ../merge-stream-naming/bench.sh load BIN_BASE BIN_BASE 24 60000
    WORK=/work/crm/bench CPUS=0-15 bash ../merge-stream-naming/bench.sh run BIN_BASE BIN_FIX 6
    WORK=/work/crm/bench BIN_BASE=... BIN_FIX=... bash readab.sh 7    # SELECT * of the source parts, max_threads=1

Result (16 pinned cores, base = 26.9.9.28-melian.10, median [min, max]):

| | base | fix | change |
|---|---|---|---|
| merge user CPU (6 runs) | 49.24 s [49.07, 49.53] | 48.71 s [48.39, 49.01] | -1.1% |
| merge duration | 50.38 s [50.36, 50.41] | 49.57 s [49.50, 56.48] | -1.6% |
| read user CPU (7 runs) | 9.30 s [9.24, 9.81] | 8.95 s [8.91, 9.43] | -3.7% |
| read wall | 9.41 s [9.41, 10.02] | 9.09 s [9.09, 9.95] | -3.4% |

Merged parts identical in all runs. Profile of the base merge: `getStreamNameForColumn` under the two hint callbacks
0.62% of the merge thread; `estimateMarkRangeBytes` 1.22%, of which 1.18% is loading the marks (the bench restarts
the server, so the mark cache is cold) and ~0.05% is the walk over the marks that #33 made linear.
