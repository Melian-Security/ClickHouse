#!/usr/bin/env bash
# Parse-throughput A/B for JSON text into the production `event` column type.
#
#   bench.sh BINARY_A BINARY_B [RUNS] [ROWS]
#
# Generates clean synthetic rows once, then alternates A and B RUNS times on two workloads:
#   parse:  SELECT * FROM file(JSONEachRow) FORMAT Null   (JSON text -> JSON column only)
#   insert: INSERT INTO MergeTree SELECT * FROM file(...)   (parse + part write, as on ingest)
# Prints one line per run and a median/min/max summary per binary and workload.
set -euo pipefail

A=$1
B=$2
RUNS=${3:-7}
ROWS=${4:-500000}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/tmp/melian-bench-surrogates}
mkdir -p "$WORK"
DATA=$WORK/clean_${ROWS}.jsonl
[ -s "$DATA" ] || python3 "$HERE/gen.py" "$ROWS" --seed 42 > "$DATA"

EVENT_TYPE=$(cat "$HERE/event_type.sql")
STRUCT="event $EVENT_TYPE"

run_parse() {
    "$1" local --max_threads 8 --query "SELECT * FROM file('$DATA', JSONEachRow, '$STRUCT') FORMAT Null"
}

run_insert() {
    local dir
    dir=$(mktemp -d "$WORK/db.XXXX")
    "$1" local --path "$dir" --max_threads 8 --max_insert_threads 8 --optimize_on_insert 0 --query "
        CREATE TABLE t (event $EVENT_TYPE) ENGINE = MergeTree ORDER BY tuple()
            SETTINGS min_bytes_for_wide_part = '512Mi';
        INSERT INTO t SELECT * FROM file('$DATA', JSONEachRow, '$STRUCT');"
    rm -rf "$dir"
}

timeit() {
    local start end
    start=$(date +%s.%N)
    "$@" > /dev/null
    end=$(date +%s.%N)
    echo "$end - $start" | bc
}

RESULTS=$WORK/results.tsv
: > "$RESULTS"
for workload in parse insert; do
    run_$workload "$A" > /dev/null  # warm the page cache
    for i in $(seq 1 "$RUNS"); do
        for label in A B; do
            bin=$A; [ "$label" = B ] && bin=$B
            t=$(timeit run_$workload "$bin")
            echo -e "$workload\t$label\t$i\t$t" | tee -a "$RESULTS"
        done
    done
done

python3 - "$RESULTS" "$ROWS" <<'EOF'
import statistics, sys
rows = int(sys.argv[2])
data = {}
for line in open(sys.argv[1]):
    w, label, _, t = line.split("\t")
    data.setdefault((w, label), []).append(float(t))
for w in ("parse", "insert"):
    med = {}
    for label in ("A", "B"):
        ts = data[(w, label)]
        med[label] = statistics.median(ts)
        print(f"{w} {label}: median {med[label]:.3f}s ({rows / med[label]:,.0f} rows/s) min {min(ts):.3f} max {max(ts):.3f} n={len(ts)}")
    print(f"{w} B vs A: {100 * (med['B'] - med['A']) / med['A']:+.2f}% time")
EOF
