#!/usr/bin/env bash
# perf profile of the json-key-lookup HTTP inserts for one binary.
# Usage: dynamic-add-variant-prof.sh base|fix
set -euo pipefail
L=/work/dav
B=/work/bin/clickhouse-$1
PERF=$(ls /usr/lib/linux-tools/*/perf | head -1)
EVENT_TYPE=$(grep -m1 "^EVENT_TYPE=" $L/kit/bench.sh | sed -e "s/^EVENT_TYPE='//" -e "s/'$//")
TABLE_SETTINGS=$(grep -m1 "^TABLE_SETTINGS=" $L/kit/bench.sh | sed -e 's/^TABLE_SETTINGS="//' -e 's/"$//')
d=$L/run/prof-$1
rm -rf $d && mkdir -p $d/data $d/tmp $d/user_files && cd $d
setsid nohup taskset -c 0-15 $B server --config-file=$L/kit/config.xml -- --path=$d/data/ --tmp_path=$d/tmp/ \
  --user_files_path=$d/user_files/ --logger.log=$d/server.log --logger.errorlog=$d/server.err.log \
  --tcp_port=19650 --http_port=19651 --mysql_port=0 --postgresql_port=0 --interserver_http_port=0 > /dev/null 2>&1 &
for _ in $(seq 120); do $B client --port 19650 -q 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done
$B client --port 19650 --multiquery -q "CREATE DATABASE bench; CREATE TABLE bench.t (event $EVENT_TYPE) ENGINE = MergeTree ORDER BY tuple() SETTINGS $TABLE_SETTINGS; SYSTEM STOP MERGES bench.t;"
PID=$(pgrep -n -f "tcp_port=19650")
for f in $L/data/insert_00*.jsonl; do curl -sS --data-binary @$f "http://127.0.0.1:19651/?query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow&async_insert=0" > /dev/null; done
$PERF record -F 999 -g -p $PID -o $d/perf.data -- sleep 30 > /dev/null 2>&1 &
PP=$!
for f in $L/data/*.jsonl; do curl -sS --data-binary @$f "http://127.0.0.1:19651/?query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow&async_insert=0" > /dev/null; done
wait $PP || true
$B client --port 19650 -q 'SYSTEM SHUTDOWN' || true
echo "--- top self"
$PERF report -i $d/perf.data --no-children --sort symbol --stdio -g none 2>/dev/null | grep -E '^ +[0-9]' | head -25 | cut -c1-180 || true
echo "--- inclusive (children) of interest"
$PERF report -i $d/perf.data --children --sort symbol --stdio -g none 2>/dev/null | grep -E '^ +[0-9]' \
  | grep -E 'addNewVariant|createVariantInfo|extendVariantColumn|DataTypeVariant::DataTypeVariant|DataTypeVariant::doGetName|insertIntoSharedData|traverseAndInsert|ReplicatedMergeTreeSink|MergeTreeSink::consume|executeQuery|SerializationJSON' | head -20 | cut -c1-180 || true
rm -rf $d/data
echo PROF DONE
