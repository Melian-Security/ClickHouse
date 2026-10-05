#!/usr/bin/env bash
# Functional reproducer: one row with an unpaired surrogate escape among clean rows.
#   repro.sh BINARY
# Stock 26.9 rejects the whole insert with INCORRECT_DATA under either value of
# input_format_json_throw_on_bad_escape_sequence; the fix accepts it when the setting is 0.
set -uo pipefail
BIN=$1
HERE=$(cd "$(dirname "$0")" && pwd)
STRUCT="event $(cat "$HERE/event_type.sql")"
DATA=$(mktemp)
python3 "$HERE/gen.py" 10000 --seed 7 --surrogate-rate 0.001 > "$DATA"
echo "rows with unpaired surrogates: $(grep -c 'DetectedValues' "$DATA")"
for throw in 1 0; do
    for simd in 1 0; do
        echo "--- throw_on_bad_escape_sequence=$throw allow_simdjson=$simd"
        "$BIN" local --input_format_json_throw_on_bad_escape_sequence "$throw" --allow_simdjson "$simd" --query "
            SELECT count(), countIf(position(toString(event.DetectedValues), unhex('EFBFBD')) > 0)
            FROM file('$DATA', JSONEachRow, '$STRUCT')" 2>&1 | head -c 300
        echo
    done
done
rm -f "$DATA"
