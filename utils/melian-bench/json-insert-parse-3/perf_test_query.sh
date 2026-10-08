#!/usr/bin/env bash
# Times the query of the json_parse_shared_data_wide_arrays_of_objects perf test in clickhouse-local, one thread on one
# core, alternating two binaries. Date inference is off, as in the inserts the kit models.
#
#   perf_test_query.sh WORK_DIR RUNS BIN_A BIN_B
#
# Prints one TSV line per run: binary, run, user+sys CPU seconds, wall seconds.
set -uo pipefail
WORK=$1; RUNS=$2; shift 2
BINS=("$@")
CORE=${CORE:-2}
mkdir -p "$WORK"
if [ ! -s "$WORK/wide.tsv" ]; then
    "${BINS[0]}" local -q "SELECT
            '{\"a\":' || toString(number) ||
            ',\"b' || toString(number % 1000) || '\":[' || arrayStringConcat(arrayMap(i ->
                '{\"k1\":\"v' || toString(number % 50 + i) || '\",\"k2\":' || toString(i) || ',\"k3\":' || if(i % 2 = 1, 'true', 'false') ||
                ',\"k4\":' || toString(number % 100 / 8) || ',\"k5\":\"x\",\"k6\":{\"k7\":\"y' || toString(i) || '\",\"k8\":' || toString(number % 13) || '}}',
                range(3)), ',') || ']}'
        FROM numbers(200000) FORMAT TSVRaw" > "$WORK/wide.tsv"
fi
TIMEFORMAT='%U %S %R'
for r in $(seq "$RUNS"); do
    for b in "${BINS[@]}"; do
        t=$( { time taskset -c "$CORE" "$b" local --max_threads=1 --input_format_try_infer_dates=0 --input_format_try_infer_datetimes=0 \
                -q "SELECT s::JSON(max_dynamic_paths = 16) FROM file('$WORK/wide.tsv', 'TSVRaw', 's String') FORMAT Null" > /dev/null; } 2>&1 | tail -1)
        echo -e "$b\t$r\t$(echo "$t" | awk '{print $1 + $2 "\t" $3}')"
    done
done
