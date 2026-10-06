#!/usr/bin/env bash
# perftests.sh SRC_DIR RUNS BIN_BASE BIN_FIX : the queries of tests/performance/json_parse_typed_and_dynamic_paths.xml
# (key templates change every row) and json_parse_runs_of_same_keys.xml (runs of rows with the same keys), base vs fix,
# alternating, in clickhouse local pinned to $CORES (default 16-23). Prints the best of 3 query times per run.
set -uo pipefail
SRC=$1/tests/performance; RUNS=$2
declare -A BINS=([base]=$3 [fix]=$4)
CORES=${CORES:-16-23}
run() { # bin xml
    local bin=$1 xml=$2
    local create fill query
    create=$(python3 -c "import re,sys; t=open(sys.argv[1]).read(); print(re.search(r'<create_query>(.*?)</create_query>', t, re.S).group(1))" "$xml")
    fill=$(python3 -c "import re,sys; t=open(sys.argv[1]).read(); print(re.search(r'<fill_query>(.*?)</fill_query>', t, re.S).group(1))" "$xml")
    query=$(python3 -c "import re,sys; t=open(sys.argv[1]).read(); print(re.search(r'<query>(.*?)</query>', t, re.S).group(1))" "$xml")
    taskset -c "$CORES" "$bin" local --max_threads 8 --multiquery --time -q "$create; $fill; $query; $query; $query" 2>&1 >/dev/null | tail -3 | sort -n | head -1
}
for xml in $SRC/json_parse_typed_and_dynamic_paths.xml $SRC/json_parse_runs_of_same_keys.xml; do
    echo "== $(basename "$xml") (best of 3 per run)"
    for r in $(seq "$RUNS"); do
        if (( r % 2 )); then order="base fix"; else order="fix base"; fi
        for b in $order; do echo "$b run$r $(run "${BINS[$b]}" "$xml")"; done
    done
done
echo PERFTESTS DONE
