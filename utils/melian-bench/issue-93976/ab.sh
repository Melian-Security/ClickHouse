#!/usr/bin/env bash
# A/B of PREWHERE ordering on compact parts with a JSON column: base vs fix binary on the same data.
#
# Usage: ab.sh <base-binary> <fix-binary> <workdir> [rounds=5] [rows=1000000]
#
# Builds the tables once with the base binary (repro.sh layout: compact and wide parts, the
# issue's JSON column and a typed-path one), then alternates the binaries for <rounds> rounds.
# Each round runs every query 3 times in one `clickhouse local` session and keeps the median of
# the `--time` figures (query time only, no process start-up). Prints one TSV row per
# (round, binary, table, query): seconds, ReadCompressedBytes, result.
set -euo pipefail
BASE=$1; FIX=$2; W=$3; ROUNDS=${4:-5}; ROWS=${5:-1000000}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ ! -d "$W/data" ]; then
  bash "$HERE/repro.sh" "$BASE" "$W" "$ROWS" > "$W.build.log" 2>&1 || true
fi

QUERIES=(
  "activity_id = 12 AND event.metadata.event_code = 'no-such-code'"
  "event.metadata.event_code = 'no-such-code' AND activity_id = 12"
  "activity_id = 12 AND event.g95.v = 'no-such-value'"
  "activity_id = 15 AND event.metadata.event_code = 'c7'"
)

printf 'round\tbinary\ttable\tquery\tseconds\tread_compressed\tresult\n'
for r in $(seq "$ROUNDS"); do
  for B in base fix; do
    BIN=$BASE; [ $B = fix ] && BIN=$FIX
    for T in t_issue_compact t_ours_compact t_issue_wide t_ours_wide; do
      for qi in "${!QUERIES[@]}"; do
        Q="SELECT count() FROM d.$T WHERE ${QUERIES[$qi]}"
        OUT=$("$BIN" local --path "$W" --time --multiquery --query "$Q; $Q; $Q" 2>/tmp/ab_time.$$)
        SECS=$(grep -E '^[0-9.]+$' /tmp/ab_time.$$ | sort -n | sed -n 2p)
        BYTES=$("$BIN" local --path "$W" --query "$Q" --print-profile-events --profile-events-delay-ms=-1 2>&1 >/dev/null | grep -m1 -o 'ReadCompressedBytes: [0-9]*' | grep -o '[0-9]*$' || echo 0)
        printf '%s\t%s\t%s\tq%s\t%s\t%s\t%s\n' "$r" "$B" "$T" "$qi" "$SECS" "$BYTES" "$(echo "$OUT" | head -1)"
      done
    done
  done
done
rm -f /tmp/ab_time.$$
