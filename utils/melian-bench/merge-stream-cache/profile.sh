#!/usr/bin/env bash
# merge-stream-cache-prof.sh <base|fix>: CPU profile of one merge of the bench source parts from the server's own
# sampling profiler (system.trace_log, symbolized by the server). Uses the ab.sh server dir, pinned to cores 0-7.
set -uo pipefail
L=/work/merge-stream-cache
W=$L/bench
n=$1
BIN=/work/bin/clickhouse-base; PORT=19100
[ "$n" = fix ] && BIN=$L/bin/clickhouse-fix && PORT=19110
D=$W/$n
q() { "$BIN" client --receive_timeout=14400 --port $PORT "$@"; }

stop() {
    [ -f "$D/pid" ] || return 0
    local pid; pid=$(cat "$D/pid"); kill "$pid" 2>/dev/null
    while [ -n "$(ps -o stat= -p "$pid" 2>/dev/null | grep -v Z)" ]; do sleep 1; done
    rm -f "$D/pid"
}
start() {
    CLICKHOUSE_WATCHDOG_ENABLE=0 taskset -c 0-7 "$BIN" server --config-file="$D/config.xml" > /dev/null 2>&1 &
    echo $! > "$D/pid"
    for _ in $(seq 120); do q -q "SELECT 1" > /dev/null 2>&1 && return 0; sleep 1; done
    echo "server did not start"; exit 1
}

stop
mkdir -p "$D/config.d"
cat > "$D/config.d/profiler.xml" <<EOF
<clickhouse>
  <global_profiler_cpu_time_period_ns>1000000</global_profiler_cpu_time_period_ns>
  <global_profiler_real_time_period_ns>0</global_profiler_real_time_period_ns>
  <trace_log><database>system</database><table>trace_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></trace_log>
</clickhouse>
EOF
start
q -q "DROP TABLE IF EXISTS bench.prof SYNC"
q -q "CREATE TABLE bench.prof AS bench.src"
# Only the OPTIMIZE below merges: background merges never pick parts larger than 1 byte.
q -q "ALTER TABLE bench.prof MODIFY SETTING max_bytes_to_merge_at_max_space_in_pool = 1, max_bytes_to_merge_at_min_space_in_pool = 1"
q -q "SYSTEM STOP MERGES bench.prof"
q -q "ALTER TABLE bench.prof ATTACH PARTITION tuple() FROM bench.src"
q -q "SYSTEM FLUSH LOGS"
T0=$(q -q "SELECT now64(6)")
q -q "SYSTEM START MERGES bench.prof"
q -q "OPTIMIZE TABLE bench.prof FINAL"
q -q "SYSTEM FLUSH LOGS"
WH="trace_type = 'CPU' AND event_time_microseconds >= '$T0' AND thread_name LIKE 'MergeMutate%'"
echo "== $n merge thread CPU samples: $(q -q "SELECT count() FROM system.trace_log WHERE $WH")"
echo "== $n top self frames (% of merge thread samples)"
q --allow_introspection_functions=1 -q "SELECT round(100 * count() / (SELECT count() FROM system.trace_log WHERE $WH), 2) AS pct, substring(demangle(addressToSymbol(trace[1])), 1, 150) AS sym FROM system.trace_log WHERE $WH GROUP BY sym ORDER BY pct DESC LIMIT 30 FORMAT TSV"
echo "== $n inclusive (% of merge thread samples)"
q --allow_introspection_functions=1 -q "WITH arrayMap(x -> demangle(addressToSymbol(x)), trace) AS st SELECT
    round(100 * countIf(arrayExists(s -> s LIKE '%MergeTreeDataPartWriterWide::writeColumn%', st)) / count(), 2) AS writeColumn,
    round(100 * countIf(arrayExists(s -> s LIKE '%MergeTreeDataPartWriterWide::writeSingleGranule%', st)) / count(), 2) AS writeSingleGranule,
    round(100 * countIf(arrayExists(s -> s LIKE '%MergeTreeDataPartWriterWide::getCurrentMarksForColumn%', st)) / count(), 2) AS getCurrentMarks,
    round(100 * countIf(arrayExists(s -> s LIKE '%MergeTreeDataPartWriterWide::getStream%', st)) / count(), 2) AS getStreamOrName,
    round(100 * countIf(arrayExists(s -> s LIKE '%getFileNameForStream%', st)) / count(), 2) AS getFileNameForStream,
    round(100 * countIf(arrayExists(s -> s LIKE '%replaceFileNameToHashIfNeeded%', st)) / count(), 2) AS replaceFileNameToHash,
    round(100 * countIf(arrayExists(s -> s LIKE '%::getDisk%', st)) / count(), 2) AS getDisk,
    round(100 * countIf(arrayExists(s -> s LIKE '%enumerateStreams%', st)) / count(), 2) AS enumerateStreams,
    round(100 * countIf(arrayExists(s -> s LIKE '%SubstreamPath const&)>%' OR s LIKE '%__policy_func<DB::WriteBuffer%', st)) / count(), 2) AS streamGetterFunc,
    round(100 * countIf(arrayExists(s -> s LIKE '%serializeBinaryBulkWithMultipleStreams%', st)) / count(), 2) AS serializeBulk,
    round(100 * countIf(arrayExists(s -> s LIKE '%PullingPipelineExecutor::pull%', st)) / count(), 2) AS readSource
    FROM system.trace_log WHERE $WH FORMAT Vertical"
q -q "DROP TABLE IF EXISTS bench.prof SYNC"
stop
rm -f "$D/config.d/profiler.xml"
echo "STEP_DONE prof $n"
