#!/usr/bin/env bash
# profile.sh WORK_DIR DATA_DIR BIN : inserts the json-key-lookup files twice with the CPU query profiler on and prints
# the insert profile: top self frames, inclusive share of the JSON object parsing, and self lines of traverseAndInsert.
# The server is pinned to $CORES (default 16-23).
set -uo pipefail
WORK=$1; DATA=$(realpath "$2"); BIN=$3
KIT=$(dirname "$(realpath "$0")")/../json-key-lookup
CORES=${CORES:-16-23}
D=$WORK/prof
rm -rf "$D"; mkdir -p "$D/data" "$D/tmp" "$D/user_files"
sed 's|</query_log>|</query_log><trace_log><database>system</database><table>trace_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></trace_log>|' $KIT/config.xml > "$D/config.xml"
EVENT_TYPE=$(grep -m1 "^EVENT_TYPE=" "$KIT/bench.sh" | sed -e "s/^EVENT_TYPE='//" -e "s/'$//")
TABLE_SETTINGS=$(grep -m1 "^TABLE_SETTINGS=" "$KIT/bench.sh" | sed -e 's/^TABLE_SETTINGS="//' -e 's/"$//')
cd "$D"
setsid nohup taskset -c "$CORES" "$BIN" server --config-file="$D/config.xml" -- --path="$D/data/" --tmp_path="$D/tmp/" \
    --user_files_path="$D/user_files/" --logger.log="$D/server.log" --logger.errorlog="$D/server.err.log" \
    --tcp_port=19700 --http_port=19701 --mysql_port=0 --postgresql_port=0 --interserver_http_port=0 > /dev/null 2>&1 &
C=("$BIN" client --port 19700)
for _ in $(seq 120); do "${C[@]}" -q 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done
"${C[@]}" --multiquery -q "CREATE DATABASE bench; CREATE TABLE bench.t (event $EVENT_TYPE) ENGINE = MergeTree ORDER BY tuple() SETTINGS $TABLE_SETTINGS; SYSTEM STOP MERGES bench.t;"
for rep in 1 2; do
  for f in $DATA/*.jsonl; do
    curl -sS --fail-with-body --data-binary @"$f" \
      "http://127.0.0.1:19701/?query=INSERT%20INTO%20bench.t%20FORMAT%20JSONEachRow&async_insert=0&log_comment=prof&query_profiler_cpu_time_period_ns=200000&query_profiler_real_time_period_ns=0" > /dev/null
  done
done
"${C[@]}" -q 'SYSTEM FLUSH LOGS'
"${C[@]}" --allow_introspection_functions=1 --multiquery -q "
CREATE TEMPORARY TABLE s AS SELECT trace FROM system.trace_log WHERE trace_type = 'CPU'
    AND query_id IN (SELECT query_id FROM system.query_log WHERE log_comment = 'prof' AND type = 'QueryFinish');
CREATE TEMPORARY TABLE syms AS SELECT addr, demangle(addressToSymbol(addr)) AS sym FROM (SELECT DISTINCT arrayJoin(trace) AS addr FROM s);
SELECT 'samples', count() FROM s;
SELECT 'self', count() AS c, round(100 * c / (SELECT count() FROM s), 2) AS pct, substring(sym, 1, 150) FROM s LEFT JOIN syms ON syms.addr = s.trace[1] GROUP BY sym ORDER BY c DESC LIMIT 25 FORMAT TSV;
WITH (SELECT groupArray(addr) FROM syms WHERE sym LIKE '%ObjectJSONNode%traverseAndInsert%') AS tr,
     (SELECT groupArray(addr) FROM syms WHERE sym LIKE '%ObjectJSONNode%insertResultToColumn%') AS ir,
     (SELECT groupArray(addr) FROM syms WHERE sym LIKE '%TCPHandler%' OR sym LIKE '%HTTPHandler%') AS h
SELECT 'incl', round(100 * countIf(arrayExists(a -> has(tr, a), trace)) / count(), 2) AS traverse,
    round(100 * countIf(arrayExists(a -> has(ir, a), trace)) / count(), 2) AS object_insert FROM s FORMAT TSV;
"
"${C[@]}" --allow_introspection_functions=1 -q "
WITH (SELECT count() FROM system.trace_log WHERE trace_type = 'CPU' AND query_id IN (SELECT query_id FROM system.query_log WHERE log_comment = 'prof' AND type = 'QueryFinish')) AS total
SELECT 'line', count() AS c, round(100 * c / total, 2), addressToLine(trace[1]) AS line FROM system.trace_log
WHERE trace_type = 'CPU' AND query_id IN (SELECT query_id FROM system.query_log WHERE log_comment = 'prof' AND type = 'QueryFinish')
    AND (demangle(addressToSymbol(trace[1])) LIKE '%traverseAndInsert%' OR demangle(addressToSymbol(trace[1])) LIKE '%getPathCacheEntry%' OR demangle(addressToSymbol(trace[1])) LIKE '%getDynamicPathColumn%' OR demangle(addressToSymbol(trace[2])) LIKE '%traverseAndInsert%')
GROUP BY line ORDER BY c DESC LIMIT 30 FORMAT TSV"
"${C[@]}" -q "SELECT 'insert', count(), round(sum(ProfileEvents['UserTimeMicroseconds'] + ProfileEvents['SystemTimeMicroseconds']) / sum(written_rows), 3) FROM system.query_log WHERE log_comment = 'prof' AND type = 'QueryFinish' FORMAT TSV"
"${C[@]}" -q 'SYSTEM SHUTDOWN' > /dev/null 2>&1 || true
echo "PROF DONE"
