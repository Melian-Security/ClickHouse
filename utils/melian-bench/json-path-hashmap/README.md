# json-path-hashmap

A/B of a single-threaded insert of 500K rows into a JSON column whose overflow paths go to shared data:
server-side JSONEachRow parsing (`Array(JSON)` values are serialized into shared data), statistics and the
write of one Compact part. Data and schema come from `../shared-data-gather` (gen.py, schema.sql with
`min_bytes_for_wide_part` raised so the insert writes a Compact part). The merge side of the same change is
measured with `../shared-data-gather/bench.sh`.

    python3 ../shared-data-gather/gen.py 0 500000 > part_0.jsonl
    insert.sh BIN_BASE BIN_FIX part_0.jsonl 5   # alternate base/fix inserts; query_log CPU + checksum of the inserted part

Base timings on a shared host moved by up to 7% between sessions, so compare only base/fix runs of the same
`insert.sh` invocation.
