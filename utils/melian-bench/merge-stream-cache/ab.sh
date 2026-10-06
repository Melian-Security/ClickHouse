#!/usr/bin/env bash
# A/B benchmark of a Vertical merge of Wide parts with a JSON column (many substreams per granule).
#
#   ab.sh setup BIN_BASE BIN_FIX DATA_DIR      start both servers, insert every DATA_DIR/*.jsonl as its own Wide part
#   ab.sh run   BIN_BASE BIN_FIX [RUNS]        alternate base/fix merges of all source parts (OPTIMIZE ... FINAL)
#   ab.sh check BIN_BASE BIN_FIX               compare the files of the last merged part of each server byte for byte
#   ab.sh profile BIN [base|fix] [SECONDS]     perf profile of one merge on that server
#   ab.sh stop
#
# Servers and merges run pinned to CPUS (default 0-7). Each run hard-links the source parts into a fresh
# table and merges them into one part; merge time and CPU come from system.part_log.
set -euo pipefail

CMD=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/work/merge-stream-cache/bench}
CPUS=${CPUS:-0-7}
POOL=${POOL:-8}
PERF=${PERF:-/usr/lib/linux-tools/6.8.0-146-generic/perf}
declare -A PORT=([base]=19100 [fix]=19110)
declare -A HPORT=([base]=18100 [fix]=18110)

q() { local name=$1; shift; "${BIN[$name]}" client --receive_timeout=14400 --port "${PORT[$name]}" -q "$@"; }

start_server() {
    local name=$1; local dir=$WORK/$1
    mkdir -p "$dir"
    cat > "$dir/config.xml" <<EOF
<clickhouse>
  <logger><level>information</level><log>$dir/server.log</log><errorlog>$dir/err.log</errorlog></logger>
  <tcp_port>${PORT[$name]}</tcp_port><http_port>${HPORT[$name]}</http_port>
  <path>$dir/data/</path><tmp_path>$dir/tmp/</tmp_path><user_files_path>$dir/user_files/</user_files_path>
  <background_pool_size>$POOL</background_pool_size>
  <merge_tree><number_of_free_entries_in_pool_to_execute_mutation>2</number_of_free_entries_in_pool_to_execute_mutation><number_of_free_entries_in_pool_to_lower_max_size_of_merge>2</number_of_free_entries_in_pool_to_lower_max_size_of_merge><number_of_free_entries_in_pool_to_execute_optimize_entire_partition>2</number_of_free_entries_in_pool_to_execute_optimize_entire_partition></merge_tree>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default/></profiles><quotas><default/></quotas>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></part_log>
</clickhouse>
EOF
    CLICKHOUSE_WATCHDOG_ENABLE=0 taskset -c "$CPUS" "${BIN[$name]}" server --config-file="$dir/config.xml" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    for _ in $(seq 120); do q "$name" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server $name did not start"; exit 1
}

stop_server() {
    local pidf=$WORK/$1/pid
    [ -f "$pidf" ] || return 0
    local pid; pid=$(cat "$pidf")
    kill "$pid" 2>/dev/null || true
    # A server that exits stays a zombie when nothing reaps it, so wait until it is gone or defunct.
    while [ -n "$(ps -o stat= -p "$pid" 2>/dev/null | grep -v Z)" ]; do sleep 1; done
    rm -f "$pidf"
}

ensure_running() {
    local name=$1
    q "$name" "SELECT 1" >/dev/null 2>&1 || start_server "$name"
}

run_one() {
    local name=$1 i=$2 t=r_$2
    q "$name" "DROP TABLE IF EXISTS bench.r_$((i - 1)) SYNC"
    q "$name" "DROP TABLE IF EXISTS bench.$t SYNC"
    q "$name" "CREATE TABLE bench.$t AS bench.src"
    # Only the OPTIMIZE below merges: background merges never pick parts larger than 1 byte, OPTIMIZE FINAL ignores the limit.
    q "$name" "ALTER TABLE bench.$t MODIFY SETTING max_bytes_to_merge_at_max_space_in_pool = 1, max_bytes_to_merge_at_min_space_in_pool = 1"
    q "$name" "SYSTEM STOP MERGES bench.$t"
    q "$name" "ALTER TABLE bench.$t ATTACH PARTITION tuple() FROM bench.src"
    q "$name" "SYSTEM START MERGES bench.$t"
    q "$name" "OPTIMIZE TABLE bench.$t FINAL SETTINGS optimize_throw_if_noop=1"
    q "$name" "SYSTEM FLUSH LOGS part_log"
    q "$name" "SELECT '$name', $i, duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3) AS user_ms, round(ProfileEvents['RealTimeMicroseconds']/1e3) AS real_ms, rows, part_type, merge_algorithm, size_in_bytes FROM system.part_log WHERE database='bench' AND table='$t' AND event_type='MergeParts' ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
}

case $CMD in
setup)
    declare -A BIN=([base]=$1 [fix]=$2); DATA=$3
    for n in base fix; do
        stop_server "$n"; rm -rf "${WORK:?}/$n"; start_server "$n"
        q "$n" "CREATE DATABASE IF NOT EXISTS bench"
        q "$n" "$(cat "$HERE/schema.sql")"
        q "$n" "SYSTEM STOP MERGES bench.src"
    done
    for f in "$DATA"/*.jsonl; do
        for n in base fix; do
            "${BIN[$n]}" client --port "${PORT[$n]}" --optimize_on_insert=0 --input_format_parallel_parsing=0 --max_insert_block_size=1000000 \
                --min_insert_block_size_rows=1000000 --min_insert_block_size_bytes=100000000000 --max_memory_usage=0 \
                -q "INSERT INTO bench.src FORMAT JSONEachRow" < "$f"
        done
    done
    for n in base fix; do
        q "$n" "SELECT '$n', count(), sum(rows), groupUniqArray(part_type), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database='bench' AND table='src' AND active FORMAT TSV"
    done
    ;;
run)
    declare -A BIN=([base]=$1 [fix]=$2); RUNS=${3:-5}
    for n in base fix; do ensure_running "$n"; done
    RES=$WORK/results.tsv
    : > "$RES"
    for i in $(seq "$RUNS"); do
        for n in base fix; do run_one "$n" "$i" | tee -a "$RES"; done
    done
    python3 - "$RES" <<'EOF'
import statistics, sys
rows = [l.split('\t') for l in open(sys.argv[1]) if l.strip()]
for col, label in ((2, 'wall_ms'), (3, 'user_ms')):
    med = {}
    for n in ('base', 'fix'):
        v = sorted(float(r[col]) for r in rows if r[0] == n)
        med[n] = statistics.median(v)
        print(f'{n:4} {label} median={med[n]:.0f} min={v[0]:.0f} max={v[-1]:.0f} n={len(v)}')
    print(f'     {label} change {100 * (med["fix"] - med["base"]) / med["base"]:+.1f}%')
EOF
    ;;
check)
    declare -A BIN=([base]=$1 [fix]=$2)
    for n in base fix; do
        ensure_running "$n"
        t=$(q "$n" "SELECT table FROM system.parts WHERE database='bench' AND table LIKE 'r\\_%' AND active ORDER BY modification_time DESC LIMIT 1")
        p=$(q "$n" "SELECT path FROM system.parts WHERE database='bench' AND table='$t' AND active")
        (cd "$p" && find . -type f ! -name 'metadata_version.txt' -print0 | sort -z | xargs -0 md5sum) > "$WORK/files_$n.txt"
        echo "$n $t $(wc -l < "$WORK/files_$n.txt") files, checksums.txt $(md5sum < "$p/checksums.txt" | cut -c1-32)"
    done
    if diff -q "$WORK/files_base.txt" "$WORK/files_fix.txt" >/dev/null; then echo "IDENTICAL: every file of the merged part"; else echo "DIFFERENT:"; diff "$WORK/files_base.txt" "$WORK/files_fix.txt" | head -20; fi
    ;;
profile)
    BINP=$1; n=${2:-base}; SECS=${3:-60}
    declare -A BIN=([$n]=$BINP)
    ensure_running "$n"
    pid=$(cat "$WORK/$n/pid")
    q "$n" "DROP TABLE IF EXISTS bench.prof SYNC"
    q "$n" "CREATE TABLE bench.prof AS bench.src"
    q "$n" "SYSTEM STOP MERGES bench.prof"
    q "$n" "ALTER TABLE bench.prof ATTACH PARTITION tuple() FROM bench.src"
    q "$n" "SYSTEM START MERGES bench.prof"
    (q "$n" "OPTIMIZE TABLE bench.prof FINAL" ; echo "merge done") &
    merge_pid=$!
    sleep 5
    $PERF record -F 499 -g -p "$pid" -o "$WORK/perf-$n.data" -- sleep "$SECS" >/dev/null 2>&1 || true
    wait "$merge_pid"
    $PERF report -i "$WORK/perf-$n.data" --no-inline --no-children --sort symbol -g none --percent-limit 0.4 --stdio 2>/dev/null | grep -v '^#' | grep '%' | head -40 > "$WORK/perf-$n.txt" || true
    echo "== $n top self symbols"; cat "$WORK/perf-$n.txt"
    q "$n" "DROP TABLE IF EXISTS bench.prof SYNC"
    ;;
stop)
    for n in base fix; do stop_server "$n"; done
    ;;
esac
