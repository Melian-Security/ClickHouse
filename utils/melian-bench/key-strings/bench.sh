#!/usr/bin/env bash
# JSON-text -> JSON(event type) parse throughput, A/B between two clickhouse binaries.
#
#   bench.sh BASE_BIN FIX_BIN [ROUNDS] [ROWS]
#
# Each round runs both binaries (alternating which goes first) on the same file with
# max_threads=1 and reports user CPU seconds of the whole `clickhouse local` process, which is
# dominated by parsing at this data size. Results go to results.tsv; summary is printed at the end.
# Then both binaries insert the data into a MergeTree table with the production settings and the
# stored data is compared by hash.
set -euo pipefail

BASE=${1:?base binary}
FIX=${2:?fix binary}
ROUNDS=${3:-7}
ROWS=${4:-400000}
DIR=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/tmp/ks-bench}
mkdir -p "$WORK"
DATA=$WORK/data.jsonl

[ -s "$DATA" ] || python3 "$DIR/gen.py" "$ROWS" 42 > "$DATA"

EVENT_TYPE=$(cat "$DIR/event_type.txt")
QUERY="SELECT * FROM file('$DATA', JSONAsObject, 'event $EVENT_TYPE') FORMAT Null SETTINGS max_threads=1, input_format_parallel_parsing=0"

run_one() {
    local bin=$1 label=$2 round=$3
    local t
    t=$( { /usr/bin/time -f '%U %e' "$bin" local --query "$QUERY" > /dev/null; } 2>&1 | tail -1)
    echo -e "$round\t$label\t$t" | tr ' ' '\t' >> "$WORK/results.tsv"
}

: > "$WORK/results.tsv"
# Warm the page cache and both binaries.
"$BASE" local --query "$QUERY" > /dev/null
"$FIX" local --query "$QUERY" > /dev/null
for r in $(seq 1 "$ROUNDS"); do
    if (( r % 2 )); then run_one "$BASE" base "$r"; run_one "$FIX" fix "$r"
    else run_one "$FIX" fix "$r"; run_one "$BASE" base "$r"; fi
done

python3 - "$WORK/results.tsv" <<'PY'
import statistics, sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().split("\n") if l]
for metric, idx in (("user_s", 2), ("wall_s", 3)):
    v = {lab: [float(r[idx]) for r in rows if r[1] == lab] for lab in ("base", "fix")}
    mb, mf = statistics.median(v["base"]), statistics.median(v["fix"])
    ratios = sorted(float(f[idx]) / float(b[idx]) for b in rows if b[1] == "base" for f in rows if f[1] == "fix" and f[0] == b[0])
    print(f"{metric}: base median {mb:.3f} [{min(v['base']):.3f}, {max(v['base']):.3f}]  "
          f"fix median {mf:.3f} [{min(v['fix']):.3f}, {max(v['fix']):.3f}]  "
          f"change {100 * (mf / mb - 1):+.2f}%  median paired ratio {statistics.median(ratios):.4f}")
PY

# Correctness: insert with each binary into a MergeTree table with production-like settings and
# compare the stored data.
for label in base fix; do
    bin=$BASE; [ $label = fix ] && bin=$FIX
    rm -rf "$WORK/db_$label"
    "$bin" local --path "$WORK/db_$label" --multiquery --query "
        CREATE TABLE t (id UInt64, event $EVENT_TYPE) ENGINE = MergeTree ORDER BY id
            SETTINGS object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
                     object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets',
                     min_bytes_for_wide_part = '512Mi';
        INSERT INTO t SELECT rowNumberInAllBlocks(), event FROM file('$DATA', JSONAsObject, 'event $EVENT_TYPE')
            SETTINGS optimize_on_insert = 0, max_insert_block_size = 10500;
        SELECT '$label', count(), cityHash64(groupArray(toString(event))) FROM (SELECT event FROM t ORDER BY id);
        SELECT '$label', groupArray(p) FROM (SELECT arrayJoin(JSONSharedDataPaths(event)) AS p FROM t GROUP BY p ORDER BY p) FORMAT TSV;
    " > "$WORK/check_$label.txt"
done
cut -f2- "$WORK/check_base.txt" | md5sum
cut -f2- "$WORK/check_fix.txt" | md5sum
head -c 300 "$WORK/check_base.txt"; echo
