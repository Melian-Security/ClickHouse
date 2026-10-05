#!/usr/bin/env bash
# Server-side timing A/B on data built by repro.sh (or ab.sh): alternates base and fix servers on
# the same data directory for <rounds> rounds; each round runs every query <reps> times and reads
# query_duration_ms and ReadCompressedBytes from system.query_log. The query condition cache is off,
# otherwise repeated runs skip the granules the first run rejected.
#
# Usage: ab_server.sh <base-binary> <fix-binary> <data-dir> <config.xml> [rounds=5] [reps=7]
# <config.xml> is a stock server config; the data path is overridden with --path.
set -uo pipefail
BASE=$1; FIX=$2; D=$3; CFG=$4; ROUNDS=${5:-5}; REPS=${6:-7}

QUERIES=(
  "activity_id = 12 AND event.metadata.event_code = 'no-such-code'"
  "event.metadata.event_code = 'no-such-code' AND activity_id = 12"
  "activity_id = 12 AND event.g95.v = 'no-such-value'"
  "activity_id = 15 AND event.metadata.event_code = 'c7'"
)
TABLES="t_issue_compact t_ours_compact t_issue_wide t_ours_wide"

printf 'round\tbinary\ttable\tquery\tmedian_ms\tmin_ms\tmax_ms\tread_compressed\tresult\n'
for r in $(seq "$ROUNDS"); do
  for B in base fix; do
    BIN=$BASE; [ $B = fix ] && BIN=$FIX
    "$BIN" server --config-file="$CFG" -- --path="$D/" > /dev/null 2>&1 &
    P=$!
    for _ in $(seq 120); do "$BIN" client -q "SELECT 1" > /dev/null 2>&1 && break; sleep 1; done
    for T in $TABLES; do
      for qi in "${!QUERIES[@]}"; do
        TAG="ab $r $B $T q$qi"
        RES=$("$BIN" client -q "SELECT count() FROM d.$T WHERE ${QUERIES[$qi]}")
        for _ in $(seq "$REPS"); do
          "$BIN" client -q "SELECT count() FROM d.$T WHERE ${QUERIES[$qi]} SETTINGS use_query_condition_cache = 0, log_comment = '$TAG'" > /dev/null
        done
        "$BIN" client -q "SYSTEM FLUSH LOGS query_log"
        "$BIN" client -q "
          SELECT '$r', '$B', '$T', 'q$qi', quantileExact(0.5)(query_duration_ms), min(query_duration_ms), max(query_duration_ms),
                 quantileExact(0.5)(ProfileEvents['ReadCompressedBytes']), '$RES'
          FROM system.query_log WHERE type = 'QueryFinish' AND log_comment = '$TAG'" --format TSV
      done
    done
    kill $P; wait $P
  done
done
