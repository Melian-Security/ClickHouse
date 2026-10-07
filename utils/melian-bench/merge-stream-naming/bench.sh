#!/usr/bin/env bash
# A/B benchmark of one OPTIMIZE ... FINAL merge per run, for per-substream overhead in merges: the size estimate
# of compact part readers and the stream names of the Wide part writer.
#
#   bench.sh load  BIN_BASE BIN_FIX [PARTS] [ROWS_PER_PART]   # build source parts once, clone for both
#   bench.sh run   BIN_BASE BIN_FIX [RUNS]                    # alternate base/fix merges, report
#   bench.sh prof  BIN NAME                                   # one merge under perf (PERF=path to perf), NAME = base|fix
#
# Env: SCHEMA picks the table (default schema-cvw.sql):
#   schema-cvw.sql   62 ordinary columns + the JSON column, Compact source parts (min_rows_for_wide_part=100000),
#                    Vertical merge into a Wide part. Load with PARTS=48 ROWS=20000.
#   schema-wide.sql  Wide source parts, Vertical merge into a Wide part. Load with PARTS=8 ROWS=300000.
#   schema-ch.sql    Compact source parts merged (Horizontal) into a Compact part. Load with PARTS=48 ROWS=20000.
# WORK (default /work/merge-stream-naming/bench), CPUS (default 0-7), GEN_DIR (load: pre-generated part_<i>.jsonl
# from `python3 gen.py I ROWS`). Both servers are pinned to CPUS; only one merge runs at a time.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/work/merge-stream-naming/bench}
CPUS=${CPUS:-0-7}
CMD=$1; shift

declare -A PORT=([base]=19800 [fix]=29800)
declare -A HPORT=([base]=18800 [fix]=28800)
declare -A BIN

write_config() {
    local name=$1 dir=$WORK/$1
    mkdir -p "$dir"
    cat > "$dir/config.xml" <<EOF
<clickhouse>
  <logger><level>information</level><log>$dir/server.log</log><errorlog>$dir/err.log</errorlog></logger>
  <tcp_port>${PORT[$name]}</tcp_port><http_port>${HPORT[$name]}</http_port>
  <listen_host>127.0.0.1</listen_host>
  <path>$dir/data/</path><tmp_path>$dir/tmp/</tmp_path><user_files_path>$dir/user_files/</user_files_path>
  <background_pool_size>8</background_pool_size>
  <merge_tree><number_of_free_entries_in_pool_to_execute_mutation>4</number_of_free_entries_in_pool_to_execute_mutation><number_of_free_entries_in_pool_to_lower_max_size_of_merge>4</number_of_free_entries_in_pool_to_lower_max_size_of_merge><number_of_free_entries_in_pool_to_execute_optimize_entire_partition>4</number_of_free_entries_in_pool_to_execute_optimize_entire_partition></merge_tree>
  <mark_cache_size>5368709120</mark_cache_size>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default/></profiles><quotas><default/></quotas>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></part_log>
</clickhouse>
EOF
}

# q NAME [CLIENT_OPTION...] QUERY
q() { local name=$1; shift; local query=${*: -1}; "${BIN[$name]}" client --port "${PORT[$name]}" "${@:1:$#-1}" -q "$query"; }

start_server() {
    local name=$1 dir=$WORK/$1
    write_config "$name"
    # WRAP (e.g. a perf record command) is put in front of the server command line.
    taskset -c "$CPUS" ${WRAP:-} "${BIN[$name]}" server --config-file="$dir/config.xml" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    for _ in $(seq 120); do q "$name" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server $name did not start"; tail -20 "$dir/err.log"; exit 1
}

stop_server() {
    local name=$1 pidf=$WORK/$1/pid
    [ -f "$pidf" ] || return 0
    kill "$(cat "$pidf")" 2>/dev/null || true
    for _ in $(seq 120); do kill -0 "$(cat "$pidf")" 2>/dev/null || break; sleep 1; done
    rm -f "$pidf"
}

stop_all() { for n in base fix; do stop_server "$n"; done; }

case $CMD in
load)
    BIN[base]=$1; BIN[fix]=$2; PARTS=${3:-8}; ROWS=${4:-500000}
    trap stop_all EXIT
    rm -rf "$WORK/base" "$WORK/fix"
    write_config base; write_config fix
    start_server base
    q base "CREATE DATABASE IF NOT EXISTS bench"
    q base "$(cat "$HERE/${SCHEMA:-schema-cvw.sql}")"
    q base "SYSTEM STOP MERGES bench.src"
    for p in $(seq 0 $((PARTS - 1))); do
        # GEN_DIR: read part_<p>.jsonl files written by gen.py beforehand (e.g. generated in parallel).
        if [ -n "${GEN_DIR:-}" ]; then cat "$GEN_DIR/part_$p.jsonl"; else python3 "$HERE/gen.py" "$p" "$ROWS"; fi | "${BIN[base]}" client --port "${PORT[base]}" \
            --optimize_on_insert=0 --input_format_parallel_parsing=0 \
            --max_insert_block_size=100000000 --min_insert_block_size_rows=100000000 --min_insert_block_size_bytes=0 \
            -q "INSERT INTO bench.src FORMAT JSONEachRow"
    done
    q base "SELECT count() AS parts, sum(rows) AS rows, groupUniqArray(part_type) AS types, formatReadableSize(sum(bytes_on_disk)) AS size FROM system.parts WHERE database='bench' AND table='src' AND active FORMAT PrettyCompactMonoBlock"
    stop_server base
    cp -a "$WORK/base/data" "$WORK/fix/"
    ;;
run)
    BIN[base]=$1; BIN[fix]=$2; RUNS=${3:-5}
    trap stop_all EXIT
    for n in base fix; do start_server "$n"; done
    RES=$WORK/results.tsv
    : > "$RES"
    for i in $(seq "$RUNS"); do
        for n in base fix; do
            t=r_$i
            q "$n" "DROP TABLE IF EXISTS bench.$t SYNC"
            q "$n" "CREATE TABLE bench.$t AS bench.src"
            q "$n" "SYSTEM STOP MERGES bench.$t"
            q "$n" "ALTER TABLE bench.$t ATTACH PARTITION tuple() FROM bench.src"
            q "$n" "SYSTEM START MERGES bench.$t"
            q "$n" --receive_timeout=86400 "OPTIMIZE TABLE bench.$t FINAL SETTINGS optimize_throw_if_noop=1"
            q "$n" "SYSTEM FLUSH LOGS part_log"
            q "$n" "SELECT '$n', $i, duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3), round(ProfileEvents['SystemTimeMicroseconds']/1e3), round(ProfileEvents['RealTimeMicroseconds']/1e3), merge_algorithm, rows, part_type, peak_memory_usage FROM system.part_log WHERE database='bench' AND table='$t' AND event_type='MergeParts' ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV" | tee -a "$RES"
            path=$(q "$n" "SELECT path FROM system.parts WHERE database='bench' AND table='$t' AND active")
            echo "$n $i checksums $(md5sum < "$path/checksums.txt" | cut -c1-32) files $(cd "$path" && find . -type f ! -name 'metadata_version.txt' -print0 | sort -z | xargs -0 md5sum | md5sum | cut -c1-32)" | tee -a "$WORK/checksums.txt"
            [ "$i" -lt "$RUNS" ] && q "$n" "DROP TABLE bench.$t SYNC"
        done
    done
    echo "== summary: median [min, max] over $RUNS runs (ms)"
    for col in 3:duration 4:user_cpu 6:real_time; do
        c=${col%%:*}; label=${col#*:}
        for n in base fix; do
            awk -v n="$n" -v c="$c" '$1==n{print $c}' "$RES" | sort -n | awk -v n="$n" -v l="$label" '{a[NR]=$1} END{printf "%-5s %-9s median=%s min=%s max=%s\n", n, l, a[int((NR+1)/2)], a[1], a[NR]}'
        done
    done
    echo "== merged parts (all runs must share one checksum)"
    awk '{print $1, $4, $6}' "$WORK/checksums.txt" | sort | uniq -c
    ;;
prof)
    BIN[$2]=$1; n=$2
    PERF=${PERF:-perf}
    trap stop_all EXIT
    # The whole server runs under perf, so every thread it starts is sampled (user space only).
    WRAP="$PERF record -F 499 -g -o $WORK/perf-$n.data --" start_server "$n"
    q "$n" "DROP TABLE IF EXISTS bench.prof SYNC"
    q "$n" "CREATE TABLE bench.prof AS bench.src"
    q "$n" "SYSTEM STOP MERGES bench.prof"
    q "$n" "ALTER TABLE bench.prof ATTACH PARTITION tuple() FROM bench.src"
    q "$n" "SYSTEM START MERGES bench.prof"
    q "$n" --receive_timeout=86400 "OPTIMIZE TABLE bench.prof FINAL"
    q "$n" "DROP TABLE bench.prof SYNC"
    stop_server "$n"
    # The merge runs in one background thread; report its samples only.
    "$PERF" report -i "$WORK/perf-$n.data" --sort comm --stdio -g none 2>/dev/null | grep '%' | head -5 > "$WORK/prof-$n-comm.txt"
    comm=$(awk '$NF != "AsyncLogger" {print $NF; exit}' "$WORK/prof-$n-comm.txt")
    "$PERF" report -i "$WORK/perf-$n.data" --comms "$comm" --children --sort symbol --stdio -g none --percent-limit 0.8 2>/dev/null | grep '%' > "$WORK/prof-$n-incl.txt"
    "$PERF" report -i "$WORK/perf-$n.data" --comms "$comm" --no-children --sort symbol --stdio -g none --percent-limit 0.4 2>/dev/null | grep '%' > "$WORK/prof-$n-self.txt"
    ;;
*)
    echo "unknown command $CMD"; exit 1
    ;;
esac
