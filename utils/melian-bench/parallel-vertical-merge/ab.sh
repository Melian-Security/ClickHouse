#!/usr/bin/env bash
# Benchmark of one Vertical merge of Wide parts with a wide JSON column and ~25 ordinary columns, writing 1, 2 or 4
# columns at the same time (MergeTree setting vertical_merge_max_parallel_columns).
#
#   ab.sh setup BIN_BASE BIN_FIX DATA_DIR   start both servers; load every DATA_DIR/*.jsonl as one Wide part of bench.src on
#                                           the base server, then attach copies of the same parts on the fix server
#   ab.sh run BIN_BASE BIN_FIX RUNS LABELS  alternate the labels RUNS times; a label is `base` (base binary), `pN` (fix
#                                           binary with vertical_merge_max_parallel_columns = N) or `rN` (the same plus
#                                           vertical_merge_read_in_separate_thread = 1)
#   ab.sh stop
#
# Data: python3 ../merge-stream-cache/gen.py DATA 1 250000 42 P for P in 0..7 (one file per source part).
#
# Each run attaches the source parts into a fresh table and merges them into one part with OPTIMIZE ... FINAL. Wall time,
# user/system CPU and peak memory come from system.part_log; the CPU of the whole server process during the merge from
# /proc. The md5 of every file of every merged part goes to sums/<label>_<run>.txt; `summary` checks they all match.
set -euo pipefail

CMD=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/work/parallel-vertical-merge/bench}
CPUS=${CPUS:-24-31}
POOL=${POOL:-8}
declare -A PORT=([base]=19700 [fix]=19710)
declare -A HPORT=([base]=18700 [fix]=18710)
declare -A BIN

q() { local name=$1; shift; "${BIN[$name]}" client --receive_timeout=14400 --send_timeout=14400 --port "${PORT[$name]}" -q "$@"; }

start_server() {
    local name=$1; local dir=$WORK/$1
    mkdir -p "$dir/data" "$dir/tmp" "$dir/user_files"
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
    echo "server $name did not start"; tail -20 "$dir/err.log"; exit 1
}

stop_server() {
    local pidf=$WORK/$1/pid
    [ -f "$pidf" ] || return 0
    local pid; pid=$(cat "$pidf")
    kill "$pid" 2>/dev/null || true
    while [ -n "$(ps -o stat= -p "$pid" 2>/dev/null | grep -v Z)" ]; do sleep 1; done
    rm -f "$pidf"
}

ensure_running() { q "$1" "SELECT 1" >/dev/null 2>&1 || start_server "$1"; }

proc_cpu_ms() { awk '{ print ($14 + $15) * 10 }' "/proc/$(cat "$WORK/$1/pid")/stat"; }

run_one() {
    local label=$1 i=$2 name t=r_$2_$1 par=1 sep=0
    case $label in
        base) name=base ;;
        p*) name=fix; par=${label#p} ;;
        r*) name=fix; par=${label#r}; sep=1 ;;
    esac
    q "$name" "DROP TABLE IF EXISTS bench.$t SYNC"
    q "$name" "CREATE TABLE bench.$t AS bench.src"
    # Only the OPTIMIZE below merges: background merges never pick parts larger than 1 byte, OPTIMIZE FINAL ignores the limit.
    q "$name" "ALTER TABLE bench.$t MODIFY SETTING max_bytes_to_merge_at_max_space_in_pool = 1, max_bytes_to_merge_at_min_space_in_pool = 1"
    [ "$name" = fix ] && q "$name" "ALTER TABLE bench.$t MODIFY SETTING vertical_merge_max_parallel_columns = $par, vertical_merge_read_in_separate_thread = $sep"
    q "$name" "SYSTEM STOP MERGES bench.$t"
    q "$name" "ALTER TABLE bench.$t ATTACH PARTITION tuple() FROM bench.src"
    q "$name" "SYSTEM START MERGES bench.$t"
    # Every run reads the source parts from the page cache, whichever server read them last.
    local src; src=$(q "$name" "SELECT data_paths[1] FROM system.tables WHERE database='bench' AND name='src'")
    find "$src" -type f -name '*.bin' -exec cat {} + > /dev/null
    local cpu0; cpu0=$(proc_cpu_ms "$name")
    q "$name" "OPTIMIZE TABLE bench.$t FINAL SETTINGS optimize_throw_if_noop=1"
    local cpu1; cpu1=$(proc_cpu_ms "$name")
    q "$name" "SYSTEM FLUSH LOGS part_log"
    local p; p=$(q "$name" "SELECT path FROM system.parts WHERE database='bench' AND table='$t' AND active")
    mkdir -p "$WORK/sums"
    (cd "$p" && find . -type f ! -name 'metadata_version.txt' -print0 | sort -z | xargs -0 md5sum) > "$WORK/sums/${label}_$i.txt"
    local h; h=$(md5sum < "$WORK/sums/${label}_$i.txt" | cut -c1-12)
    q "$name" "SELECT '$label', $i, duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3) AS user_ms,
        round(ProfileEvents['SystemTimeMicroseconds']/1e3) AS sys_ms, $((cpu1 - cpu0)) AS proc_cpu_ms,
        round(peak_memory_usage / 1048576) AS peak_mib, rows, merge_algorithm, part_type, size_in_bytes, '$h'
        FROM system.part_log WHERE database='bench' AND table='$t' AND event_type='MergeParts'
        ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
    q "$name" "DROP TABLE bench.$t SYNC"
}

case $CMD in
setup)
    BIN=([base]=$1 [fix]=$2); DATA=$3
    for n in base fix; do stop_server "$n"; rm -rf "${WORK:?}/$n"; start_server "$n"; done
    for n in base fix; do q "$n" "CREATE DATABASE IF NOT EXISTS bench"; "${BIN[$n]}" client --port "${PORT[$n]}" --multiquery < "$HERE/schema.sql"; done
    # SYSTEM STOP MERGES does not survive a restart: the size limits keep background merges off the source parts for good.
    for n in base fix; do
        q "$n" "ALTER TABLE bench.src MODIFY SETTING max_bytes_to_merge_at_max_space_in_pool = 1, max_bytes_to_merge_at_min_space_in_pool = 1"
        q "$n" "SYSTEM STOP MERGES bench.src"
    done
    for f in "$DATA"/*.jsonl; do
        q base "TRUNCATE TABLE bench.stage"
        "${BIN[base]}" client --port "${PORT[base]}" --optimize_on_insert=0 --input_format_parallel_parsing=0 --max_insert_block_size=100000000 \
            --min_insert_block_size_rows=100000000 --min_insert_block_size_bytes=100000000000 --max_memory_usage=0 \
            -q "INSERT INTO bench.stage FORMAT JSONEachRow" < "$f"
        "${BIN[base]}" client --port "${PORT[base]}" --receive_timeout=14400 --multiquery < "$HERE/load.sql"
        echo "loaded $f"
    done
    q base "DROP TABLE bench.stage SYNC"
    q fix "DROP TABLE bench.stage SYNC"
    # The fix server gets byte-identical copies of the source parts.
    src=$(q base "SELECT data_paths[1] FROM system.tables WHERE database='bench' AND name='src'")
    dst=$(q fix "SELECT data_paths[1] FROM system.tables WHERE database='bench' AND name='src'")
    for part in $(q base "SELECT name FROM system.parts WHERE database='bench' AND table='src' AND active ORDER BY name"); do
        cp -a "$src/$part" "$dst/detached/$part"
        q fix "ALTER TABLE bench.src ATTACH PART '$part'"
    done
    for n in base fix; do
        q "$n" "SELECT '$n', count(), sum(rows), groupUniqArray(part_type), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database='bench' AND table='src' AND active FORMAT TSV"
    done
    q base "SELECT column, formatReadableSize(sum(column_data_compressed_bytes)) c FROM system.parts_columns WHERE database='bench' AND table='src' AND active GROUP BY column ORDER BY sum(column_data_compressed_bytes) DESC LIMIT 8 FORMAT TSV"
    ;;
run)
    BIN=([base]=$1 [fix]=$2); RUNS=$3; shift 3; LABELS=("$@")
    for n in base fix; do ensure_running "$n"; done
    RES=$WORK/results.tsv
    for i in $(seq "$RUNS"); do
        for label in "${LABELS[@]}"; do run_one "$label" "$i" | tee -a "$RES"; done
    done
    echo "RUN DONE"
    ;;
summary)
    python3 - "$WORK/results.tsv" <<'EOF'
import statistics, sys
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1]) if l.strip()]
labels = list(dict.fromkeys(r[0] for r in rows))
cols = ((2, 'wall_ms'), (3, 'user_ms'), (4, 'sys_ms'), (5, 'proc_cpu_ms'), (6, 'peak_mib'))
base = {}
for label in labels:
    rs = [r for r in rows if r[0] == label]
    out = [f'{label:5} n={len(rs)}']
    for c, name in cols:
        v = sorted(float(r[c]) for r in rs)
        med = statistics.median(v)
        if label == labels[0]:
            base[c] = med
        out.append(f'{name} {med:.0f} [{v[0]:.0f}..{v[-1]:.0f}] ({100 * (med - base[c]) / base[c]:+.1f}%)')
    out.append('hashes ' + ','.join(sorted(set(r[11] for r in rs))))
    print('  '.join(out))
EOF
    ;;
stop)
    for n in base fix; do stop_server "$n"; done
    ;;
esac
