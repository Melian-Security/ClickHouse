#!/usr/bin/env bash
# A/B of one Vertical OPTIMIZE ... FINAL merge of 8 Wide parts x 300K rows into a Wide part, with a JSON column with
# 115 typed paths (schema-typed.sql, written by mkschema.py from schema-wide.sql) and the advanced shared data
# serialization. Uses bench.sh (load / run / prof).
#
#   ab.sh load BIN_BASE POOL_PATHS WORK PORT_OFFSET CPUS   # generate (gen.py, POOL_PATHS untyped paths) and load the parts
#   ab.sh run  BIN_BASE BIN_FIX WORK PORT_OFFSET [RUNS]     # alternate base/fix merges on cores 0-7, summary + checksums
#
# The numbers of the PR: POOL_PATHS=250 in WORK=/work/mws/bench (PORT_OFFSET=0) and POOL_PATHS=2000 in
# WORK=/work/mws/bench2 (PORT_OFFSET=100), 5 runs each.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CMD=$1; shift
case $CMD in
load)
    BIN=$1 POOL=$2; export WORK=$3 PORT_OFFSET=$4 CPUS=$5 SCHEMA=schema-typed.sql
    python3 "$HERE/mkschema.py" > "$HERE/schema-typed.sql"
    GEN=$WORK.gen; mkdir -p "$GEN"
    for p in 0 1 2 3 4 5 6 7; do POOL_PATHS=$POOL python3 "$HERE/gen.py" $p 300000 > "$GEN/part_$p.jsonl" & done
    wait
    GEN_DIR=$GEN bash "$HERE/bench.sh" load "$BIN" "$BIN" 8 300000
    rm -rf "$GEN"
    ;;
run)
    export WORK=$3 PORT_OFFSET=$4 CPUS=0-7 SCHEMA=schema-typed.sql
    rm -f "$WORK/checksums.txt"
    bash "$HERE/bench.sh" run "$1" "$2" "${5:-5}"
    ;;
esac
