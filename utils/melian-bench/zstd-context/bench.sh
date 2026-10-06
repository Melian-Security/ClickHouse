#!/usr/bin/env bash
# BASE_BIN=... FIX_BIN=... DATA=... bench.sh RUNS MODE... : A/B of base vs fix binary, per memory mode, alternating base/fix each run.
#   MODE default = stock memory worker; MODE poc = memory_worker_purge_total_memory_threshold_ratio=0.001
#   (the memory worker keeps jemalloc dirty_decay_ms at 0, as on servers near their memory limit).
# The first MODE's data dir gets NPARTS wide source parts (built once with BASE_BIN); later modes copy it.
# Each run restarts the server, runs an insert pass
# (HTTP JSONEachRow, CONC concurrent) into a compact-part table, then one vertical merge of MPARTS wide parts.
# Also records merge-thread trace_log samples (total, madvise/purge, ZSTD_freeCCtx, ZSTD_createCCtx) and an md5 list
# of every file of the merged part for a byte-level comparison.
set -uo pipefail
RUNS=$1; shift; MODES=("$@")
W=${W:-/work/zstd-context}
DATA=${DATA:?directory of part_*.jsonl from ../json-merge/gen.py DATA 128}
CORES=${CORES:-24-31}
CONC=${CONC:-8}
NPARTS=${NPARTS:-6}
RES=$W/results.tsv
mkdir -p $W/parts
binof() { case $1 in base) echo "${BASE_BIN:?}";; fix) echo "${FIX_BIN:?}";; esac; }
port() { case $1 in default) echo 41;; poc) echo 42;; esac; }
mode_cfg() { [ "$1" = poc ] && echo "<memory_worker_purge_total_memory_threshold_ratio>0.001</memory_worker_purge_total_memory_threshold_ratio>"; }

BIN=${BASE_BIN:?}
start() {   # $1 mode
    local m=$1 d=$W/srv/$1 p; p=$(port "$m")
    mkdir -p "$d"
    cat > "$d/config.xml" <<EOF
<clickhouse>
  <logger><level>information</level><log>$d/server.log</log><errorlog>$d/err.log</errorlog></logger>
  <tcp_port>21${p}0</tcp_port><http_port>22${p}0</http_port><listen_host>127.0.0.1</listen_host>
  <path>$d/data/</path><tmp_path>$d/tmp/</tmp_path><user_files_path>$DATA/</user_files_path>
  <background_pool_size>8</background_pool_size>
  <merge_tree><number_of_free_entries_in_pool_to_execute_mutation>4</number_of_free_entries_in_pool_to_execute_mutation><number_of_free_entries_in_pool_to_execute_optimize_entire_partition>4</number_of_free_entries_in_pool_to_execute_optimize_entire_partition><number_of_free_entries_in_pool_to_lower_max_size_of_merge>4</number_of_free_entries_in_pool_to_lower_max_size_of_merge></merge_tree>
  <max_server_memory_usage>171798691840</max_server_memory_usage>
  <global_profiler_cpu_time_period_ns>10000000</global_profiler_cpu_time_period_ns>
  <global_profiler_real_time_period_ns>0</global_profiler_real_time_period_ns>
  $(mode_cfg "$m")
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default><async_insert>0</async_insert><optimize_on_insert>0</optimize_on_insert><allow_introspection_functions>1</allow_introspection_functions><query_profiler_cpu_time_period_ns>10000000</query_profiler_cpu_time_period_ns><query_profiler_real_time_period_ns>0</query_profiler_real_time_period_ns></default></profiles><quotas><default/></quotas>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></part_log>
  <trace_log><database>system</database><table>trace_log</table><flush_interval_milliseconds>2000</flush_interval_milliseconds></trace_log>
  <query_log><database>system</database><table>query_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></query_log>
</clickhouse>
EOF
    env CLICKHOUSE_WATCHDOG_ENABLE=0 taskset -c "$CORES" "$BIN" server --config-file="$d/config.xml" >/dev/null 2>&1 &
    echo $! > "$d/pid"
    for _ in $(seq 120); do q "$m" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server $m did not start"; tail -5 "$d/err.log"; exit 1
}
stop() { local d=$W/srv/$1; kill "$(cat "$d/pid")" 2>/dev/null; while kill -0 "$(cat "$d/pid")" 2>/dev/null; do sleep 1; done; }
q() { local m=$1; shift; "$BIN" client --receive_timeout=7200 --port "21$(port "$m")0" -q "$@"; }
cpu_ticks() { awk '{print $14+$15}' /proc/"$1"/stat; }
hwm() { awk '/VmHWM/{print int($2/1024)}' /proc/"$1"/status; }
schema() { # $1 table $2 wide_bytes
    sed -e "s/bench.src/bench.$1/" -e "s/{WIDE_BYTES}/$2/" $(dirname "$0")/../json-merge/schema.sql \
      | sed -e "s/map_with_buckets';/map_with_buckets', vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1;/"
}

setup() {
    local m=$1
    BIN=$BASE_BIN
    start "$m"
    q "$m" "CREATE DATABASE IF NOT EXISTS bench"
    q "$m" "$(schema src 0)"
    q "$m" "ALTER TABLE bench.src MODIFY SETTING min_parts_to_merge_at_once = 100"
    q "$m" "SYSTEM STOP MERGES bench.src"
    for k in $(seq 0 $((NPARTS-1))); do
        q "$m" "INSERT INTO bench.src SELECT id + $k * 100000000, ts, event FROM file('part_*.jsonl', JSONEachRow, 'id UInt64, ts DateTime, event $(sed -n 's/^ *event \(JSON(.*)\)$/\1/p' $(dirname "$0")/../json-merge/schema.sql)') SETTINGS max_insert_block_size=2000000, min_insert_block_size_rows=2000000, min_insert_block_size_bytes=0, max_block_size=2000000, max_threads=8"
    done
    echo "$m parts: $(q "$m" "SELECT count(), sum(rows), any(part_type), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database='bench' AND table='src' AND active FORMAT TSV")"
    stop "$m"
}

run_one() {   # $1 bin(base|fix) $2 mode $3 i
    local b=$1 m=$2 i=$3 pid c0 c1 c2 t0 t1 t2 h1 tm
    BIN=$(binof "$b")
    start "$m"; pid=$(cat "$W/srv/$m/pid")
    q "$m" "DROP TABLE IF EXISTS bench.ins SYNC"; q "$m" "DROP TABLE IF EXISTS bench.m SYNC"
    q "$m" "$(schema ins 536870912)"; q "$m" "SYSTEM STOP MERGES bench.ins"
    q "$m" "$(schema m 0)"; q "$m" "SYSTEM STOP MERGES bench.m"
    q "$m" "ALTER TABLE bench.m ATTACH PARTITION tuple() FROM bench.src"; q "$m" "ALTER TABLE bench.m MODIFY SETTING min_parts_to_merge_at_once = 100"
    for pn in $(q "$m" "SELECT name FROM system.parts WHERE database='bench' AND table='m' AND active ORDER BY min_block_number LIMIT 100 OFFSET ${MPARTS:-3}"); do
        q "$m" "ALTER TABLE bench.m DROP PART '$pn'"
    done
    sleep 8
    local tag="${b}_${m}_$i"
    c0=$(cpu_ticks "$pid"); t0=$(date +%s.%N)
    ls "$DATA"/part_*.jsonl | head -n "${INSFILES:-64}" | xargs -P "$CONC" -I{} curl -sS --fail -o /dev/null --data-binary @{} \
        "http://127.0.0.1:22$(port "$m")0/?query=INSERT%20INTO%20bench.ins%20FORMAT%20JSONEachRow&log_comment=$tag&async_insert=0"
    c1=$(cpu_ticks "$pid"); t1=$(date +%s.%N); h1=$(hwm "$pid")
    tm=$(q "$m" "SELECT toString(now64(6))")
    q "$m" "SYSTEM START MERGES bench.m"
    q "$m" "OPTIMIZE TABLE bench.m FINAL SETTINGS optimize_throw_if_noop=1"
    c2=$(cpu_ticks "$pid"); t2=$(date +%s.%N)
    q "$m" "SYSTEM FLUSH LOGS"
    local ins mg hash tr path
    ins=$(q "$m" "SELECT sum(written_rows), round(sum(ProfileEvents['UserTimeMicroseconds']+ProfileEvents['SystemTimeMicroseconds'])/sum(written_rows),3), round(sum(ProfileEvents['SystemTimeMicroseconds'])/sum(written_rows),3) FROM system.query_log WHERE log_comment='$tag' AND type='QueryFinish' AND query_kind='Insert' FORMAT TSV")
    mg=$(q "$m" "SELECT duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3), round(ProfileEvents['SystemTimeMicroseconds']/1e3), peak_memory_usage, rows, part_name FROM system.part_log WHERE database='bench' AND table='m' AND event_type='MergeParts' ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV")
    hash=$(q "$m" "SELECT hash_of_all_files FROM system.parts WHERE database='bench' AND table='m' AND active FORMAT TSV")
    path=$(q "$m" "SELECT path FROM system.parts WHERE database='bench' AND table='m' AND active FORMAT TSV")
    (cd "$path" && find . -type f ! -name 'txn_version.txt' | sort | xargs md5sum) > "$W/parts/$tag.md5"
    # merge-thread CPU samples during the merge: total, madvise/purge, ZSTD_freeCCtx, ZSTD_createCCtx, ZSTD_compress2
    tr=$(q "$m" "SELECT count(), countIf(arrayExists(a -> addressToSymbol(a) IN ('pages_purge_forced','pages_purge_lazy','madvise'), trace)), countIf(arrayExists(a -> addressToSymbol(a) = 'ZSTD_freeCCtx', trace)), countIf(arrayExists(a -> addressToSymbol(a) = 'ZSTD_createCCtx', trace)), countIf(arrayExists(a -> addressToSymbol(a) = 'ZSTD_compress2', trace)) FROM system.trace_log WHERE trace_type='CPU' AND event_time_microseconds >= '$tm' AND (thread_name LIKE '%Merge%' OR thread_name LIKE 'MergeMutate%') FORMAT TSV")
    # bin mode i | ins_rows ins_us/row ins_sys_us/row | ins_wall ins_proc_cpu | merge_ms m_user_ms m_sys_ms peak rows part | merge_wall merge_proc_cpu | hwm_ins hwm_final | hash | samples madv free create compress2
    printf "%s\t%s\t%s\t%s\t%.1f\t%.1f\t%s\t%.1f\t%.1f\t%s\t%s\t%s\t%s\n" "$b" "$m" "$i" "$ins" \
        "$(awk "BEGIN{print $t1-$t0}")" "$(awk "BEGIN{print ($c1-$c0)/100}")" "$mg" \
        "$(awk "BEGIN{print $t2-$t1}")" "$(awk "BEGIN{print ($c2-$c1)/100}")" "$h1" "$(hwm "$pid")" "$hash" "$tr" | tee -a "$RES"
    stop "$m"
}

if [ ! -d "$W/srv/${MODES[0]}/data" ]; then setup "${MODES[0]}"; fi
for m in "${MODES[@]:1}"; do
    [ -d "$W/srv/$m/data" ] || { mkdir -p "$W/srv/$m"; cp -a "$W/srv/${MODES[0]}/data" "$W/srv/$m/data"; }
done
for i in $(seq "$RUNS"); do
    for m in "${MODES[@]}"; do
        if [ $((i % 2)) = 1 ]; then run_one base "$m" "$i"; run_one fix "$m" "$i"; else run_one fix "$m" "$i"; run_one base "$m" "$i"; fi
    done
done
echo BENCH_DONE
