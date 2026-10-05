#!/usr/bin/env bash
# A/B driver: alternates two binaries over the same data, then prints medians.
#
# usage: ab.sh <bin-a> <bin-b> <data-dir> <runs> <results-file>
# Generate data first: python3 gen.py --out <data-dir> --files 20 --rows 10500
set -euo pipefail
A=$1; B=$2; DATA=$3; N=$4; RES=$5
HERE=$(cd "$(dirname "$0")" && pwd)
: > "$RES"
for i in $(seq "$N"); do
  "$HERE/run.sh" "$A" A "$DATA" "$RES" >/dev/null
  "$HERE/run.sh" "$B" B "$DATA" "$RES" >/dev/null
done
python3 "$HERE/summarize.py" "$RES"
