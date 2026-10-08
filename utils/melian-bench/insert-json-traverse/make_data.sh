#!/usr/bin/env bash
# Generates 640,000 rows as 40 Native insert files of 16,000 rows in /work/ijt/data, with the JSON column written as
# JSON text, and copies this kit to /work/ijt/kit. Needs /work/bin/clickhouse-base.
set -euo pipefail
L=/work/ijt
mkdir -p $L/kit $L/data
cp "$(dirname "$(realpath "$0")")"/{bench.sh,verify.sh,config.xml,gen.py} $L/kit/
rm -f $L/data/*
python3 $L/kit/gen.py 640000 1 | split -l 16000 -d -a 3 --additional-suffix=.jsonl - $L/data/insert_
EVENT_TYPE=$(grep -m1 "^EVENT_TYPE=" "$L/kit/bench.sh" | sed -e "s/^EVENT_TYPE='//" -e "s/'$//")
for f in $L/data/*.jsonl; do
  /work/bin/clickhouse-base local --input-format JSONEachRow --structure "event $EVENT_TYPE" \
    --output_format_native_write_json_as_string=1 -q "SELECT * FROM table FORMAT Native" < "$f" > "${f%.jsonl}.native"
done
rm -f $L/data/*.jsonl
ls $L/data/*.native | wc -l
du -sh $L/data
echo GEN DONE
