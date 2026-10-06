#!/usr/bin/env bash
# A/B benchmark of a Vertical merge of wide JSON parts between two clickhouse binaries.
#
#   bench.sh BIN_BASE BIN_FIX DATA_DIR [RUNS] [CORES]
#
# Starts one server per binary pinned to CORES, inserts every DATA_DIR/*.jsonl file as its own wide part
# (merges stopped), then alternates runs: each run attaches the source parts into a fresh table and
# merges them into one with OPTIMIZE ... FINAL. Reports merge duration and merge user CPU from
# system.part_log, and compares every file of the merged parts between the two binaries.
set -euo pipefail
if [ -z "${DETACHED:-}" ]; then mkdir -p "${WORK:-/work/variant-stats/bench}"; DETACHED=1 setsid nohup "$0" "$@" > "${WORK:-/work/variant-stats/bench}/${MODE:-ab}.log" 2>&1 < /dev/null & echo "detached $!"; exit 0; fi

BASE=$1
FIX=$2
DATA=$3
RUNS=${4:-5}
CORES=${5:-8-15}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/work/variant-stats/bench}
POOL=${POOL:-8}

declare -A BIN=([base]=$BASE [fix]=$FIX)
declare -A PORT=([base]=19200 [fix]=29200)
declare -A HPORT=([base]=18200 [fix]=28200)

q() { local name=$1; shift; "${BIN[$name]}" client --port "${PORT[$name]}" --receive_timeout=86400 -q "$@"; }

write_config() {
    local name=$1 dir=$WORK/$1
    mkdir -p "$dir"
    cat > "$dir/config.xml" <<EOF
<clickhouse>
  <logger><level>information</level><log>$dir/server.log</log><errorlog>$dir/err.log</errorlog></logger>
  <tcp_port>${PORT[$name]}</tcp_port><http_port>${HPORT[$name]}</http_port>
  <listen_host>127.0.0.1</listen_host>
  <path>$dir/data/</path><tmp_path>$dir/tmp/</tmp_path><user_files_path>$DATA/</user_files_path>
  <background_pool_size>$POOL</background_pool_size>
  <merge_tree><number_of_free_entries_in_pool_to_lower_max_size_of_merge>0</number_of_free_entries_in_pool_to_lower_max_size_of_merge><number_of_free_entries_in_pool_to_execute_mutation>0</number_of_free_entries_in_pool_to_execute_mutation><number_of_free_entries_in_pool_to_execute_optimize_entire_partition>0</number_of_free_entries_in_pool_to_execute_optimize_entire_partition></merge_tree>
  <mark_cache_size>5368709120</mark_cache_size>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default>
    <query_profiler_cpu_time_period_ns>${PROFILE_NS:-0}</query_profiler_cpu_time_period_ns>
    <query_profiler_real_time_period_ns>0</query_profiler_real_time_period_ns>
  </default></profiles><quotas><default/></quotas>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></part_log>
  <trace_log><database>system</database><table>trace_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></trace_log>
</clickhouse>
EOF
}

start_server() {
    local name=$1 dir=$WORK/$1
    taskset -c "$CORES" "${BIN[$name]}" server --config-file="$dir/config.xml" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    for _ in $(seq 120); do q "$name" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server $name did not start"; exit 1
}

setup() {
    local name=$1
    if [ "$(q "$name" "SELECT count() FROM system.parts WHERE database='bench' AND table='src' AND active" 2>/dev/null || echo 0)" != 0 ]; then
        echo "$name: reusing bench.src"
        q "$name" "ALTER TABLE bench.src MODIFY SETTING max_bytes_to_merge_at_max_space_in_pool = 1"
        return 0
    fi
    q "$name" "CREATE DATABASE IF NOT EXISTS bench"
    q "$name" "$(cat "$HERE/schema.sql")"
    q "$name" "SYSTEM STOP MERGES bench.src"
    if [ "$name" = fix ]; then
        # Reuse the source parts written by the base server, so both binaries merge identical inputs.
        local from to
        from=$(q base "SELECT data_paths[1] FROM system.tables WHERE database='bench' AND name='src'")
        to=$(q fix "SELECT data_paths[1] FROM system.tables WHERE database='bench' AND name='src'")
        for d in "$from"all_*; do cp -al "$d" "${to}detached/"; done
        q fix "ALTER TABLE bench.src ATTACH PARTITION tuple()"
    else
        for f in "$DATA"/*.jsonl; do
            "${BIN[$name]}" client --port "${PORT[$name]}" --optimize_on_insert=0 --max_insert_block_size=2000000 --input_format_parallel_parsing=0 \
                --min_insert_block_size_rows=2000000 --min_insert_block_size_bytes=0 --max_memory_usage=0 \
                -q "INSERT INTO bench.src FORMAT JSONEachRow" < "$f"
        done
    fi
    echo "$name parts: $(q "$name" "SELECT count(), sum(rows), groupUniqArray(part_type) FROM system.parts WHERE database='bench' AND table='src' AND active")"
}

run_one() {
    local name=$1 i=$2 t=r_$2
    q "$name" "DROP TABLE IF EXISTS bench.$t SYNC"
    q "$name" "CREATE TABLE bench.$t AS bench.src"
    q "$name" "SYSTEM STOP MERGES bench.$t"
    q "$name" "ALTER TABLE bench.$t ATTACH PARTITION tuple() FROM bench.src"
    q "$name" "SYSTEM START MERGES bench.$t"
    q "$name" "OPTIMIZE TABLE bench.$t FINAL SETTINGS optimize_throw_if_noop=1"
    q "$name" "SYSTEM FLUSH LOGS"
    q "$name" "SELECT '$name', $i, duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3) AS user_ms, rows, part_type, merge_algorithm FROM system.part_log WHERE database='bench' AND table='$t' AND event_type='MergeParts' ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
}

drop_run() { q "$1" "DROP TABLE IF EXISTS bench.r_$2 SYNC"; }

part_dir() { q "$1" "SELECT path FROM system.parts WHERE database='bench' AND table='r_$2' AND active"; }

stop_all() { for n in base fix; do [ -f "$WORK/$n/pid" ] && kill "$(cat "$WORK/$n/pid")" 2>/dev/null || true; done; }
trap stop_all EXIT

if [ "${MODE:-ab}" = profile ]; then
    # Profile one merge on the base binary with the CPU query profiler and print the hottest frames.
    write_config base; start_server base; setup base
    run_one base 0
    q base "SYSTEM FLUSH LOGS"
    q base "SELECT count() FROM system.trace_log WHERE trace_type='CPU'"
    q base "SELECT arrayStringConcat(arrayReverse(arrayMap(x -> demangle(addressToSymbol(x)), trace)), ';') AS stack, count() FROM system.trace_log WHERE trace_type='CPU' GROUP BY trace FORMAT TSV SETTINGS allow_introspection_functions=1" > "$WORK/stacks_base.tsv"
    echo "stacks written to $WORK/stacks_base.tsv"
    exit 0
fi

for n in base fix; do write_config "$n"; start_server "$n"; setup "$n"; done

RES=$WORK/results.tsv
: > "$RES"
for i in $(seq "$RUNS"); do
    for n in base fix; do
        run_one "$n" "$i" | tee -a "$RES"
        [ "$i" != "$RUNS" ] && drop_run "$n" "$i"
    done
done

echo "== summary: name median min max (duration_ms, user_ms)"
for n in base fix; do
    for col in 3 4; do
        awk -v n=$n -v c=$col '$1==n{print $c}' "$RES" | sort -n | awk -v n=$n -v c=$col '{a[NR]=$1} END{printf "%s col%d median=%s min=%s max=%s\n", n, c, a[int((NR+1)/2)], a[1], a[NR]}'
    done
done

echo "== byte-identical check of the merged parts (last run)"
B=$(part_dir base "$RUNS"); F=$(part_dir fix "$RUNS")
(cd "$B" && find . -type f -print0 | sort -z | xargs -0 md5sum) > "$WORK/files_base.md5"
(cd "$F" && find . -type f -print0 | sort -z | xargs -0 md5sum) > "$WORK/files_fix.md5"
echo "files: $(wc -l < "$WORK/files_base.md5") base, $(wc -l < "$WORK/files_fix.md5") fix"
if diff -q "$WORK/files_base.md5" "$WORK/files_fix.md5" >/dev/null; then echo "IDENTICAL (all files, incl. checksums.txt)"; else echo "DIFFERENT:"; diff "$WORK/files_base.md5" "$WORK/files_fix.md5" | head -20; fi
