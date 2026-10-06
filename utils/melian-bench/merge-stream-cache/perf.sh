#!/usr/bin/env bash
# merge-stream-cache-perf.sh <base|fix> [SECONDS]: perf profile (self frames, user space) of the server while it merges
# the bench source parts. Uses the ab.sh server dir, pinned to cores 0-7.
set -uo pipefail
L=/work/merge-stream-cache
W=$L/bench
n=$1; SECS=${2:-40}
PERF=/usr/lib/linux-tools/6.8.0-146-generic/perf
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
rm -f "$D/config.d/profiler.xml"
start
pid=$(cat "$D/pid")
q -q "DROP TABLE IF EXISTS bench.prof SYNC"
q -q "CREATE TABLE bench.prof AS bench.src"
q -q "ALTER TABLE bench.prof MODIFY SETTING max_bytes_to_merge_at_max_space_in_pool = 1, max_bytes_to_merge_at_min_space_in_pool = 1"
q -q "SYSTEM STOP MERGES bench.prof"
q -q "ALTER TABLE bench.prof ATTACH PARTITION tuple() FROM bench.src"
q -q "SYSTEM START MERGES bench.prof"
q -q "OPTIMIZE TABLE bench.prof FINAL" &
mpid=$!
sleep 30
$PERF record -F 999 -p "$pid" -o "$W/perf-$n.data" -- sleep "$SECS" > /dev/null 2>&1
wait $mpid
echo "== $n perf samples: $($PERF report -i "$W/perf-$n.data" --stdio --no-inline --header-only 2>/dev/null | grep -m1 'sample' )"
$PERF report -i "$W/perf-$n.data" --stdio --no-inline --no-children --sort symbol --percent-limit 0.3 2>/dev/null | grep -v '^#' | grep '%' | head -45 | cut -c1-170
q -q "DROP TABLE IF EXISTS bench.prof SYNC"
stop
echo "STEP_DONE perf $n"
