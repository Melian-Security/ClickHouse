#!/usr/bin/env bash
# A/B benchmark of a single JSON-column merge (OPTIMIZE ... FINAL) between two clickhouse binaries.
#
#   run.sh BIN_BASE BIN_FIX DATA_DIR [RUNS] [compact|wide]
#
# Starts one server per binary, inserts every DATA_DIR/*.jsonl file as its own part (merges stopped),
# then alternates runs: each run hard-links the source parts into a fresh table and merges them into one.
# Reports merge duration and merge user CPU from system.part_log, and compares the merged parts
# (hash of all files) and query output between the two binaries.
set -euo pipefail

BASE=$1
FIX=$2
DATA=$3
RUNS=${4:-5}
MODE=${5:-compact}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/home/ssm-user/jm-work}
WIDE_BYTES=536870912
[ "$MODE" = wide ] && WIDE_BYTES=0

declare -A BIN=([base]=$BASE [fix]=$FIX)
declare -A PORT=([base]=19000 [fix]=29000)
declare -A HPORT=([base]=18123 [fix]=28123)

start_server() {
    local name=$1 dir=$WORK/$name
    rm -rf "$dir"; mkdir -p "$dir"
    cat > "$dir/config.xml" <<EOF
<clickhouse>
  <logger><level>information</level><log>$dir/server.log</log><errorlog>$dir/err.log</errorlog></logger>
  <tcp_port>${PORT[$name]}</tcp_port><http_port>${HPORT[$name]}</http_port>
  <path>$dir/data/</path><tmp_path>$dir/tmp/</tmp_path><user_files_path>$DATA/</user_files_path>
  <mark_cache_size>5368709120</mark_cache_size>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default/></profiles><quotas><default/></quotas>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></part_log>
</clickhouse>
EOF
    "${BIN[$name]}" server --config-file="$dir/config.xml" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    for _ in $(seq 60); do q "$name" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server $name did not start"; exit 1
}

q() { local name=$1; shift; "${BIN[$name]}" client --port "${PORT[$name]}" -q "$@"; }

setup() {
    local name=$1
    q "$name" "CREATE DATABASE IF NOT EXISTS bench"
    q "$name" "$(sed "s/{WIDE_BYTES}/$WIDE_BYTES/" "$HERE/schema.sql")"
    q "$name" "SYSTEM STOP MERGES bench.src"
    for f in "$DATA"/*.jsonl; do
        "${BIN[$name]}" client --port "${PORT[$name]}" --optimize_on_insert=0 --max_insert_block_size=1000000 \
            --min_insert_block_size_rows=0 --min_insert_block_size_bytes=0 \
            -q "INSERT INTO bench.src FORMAT JSONEachRow" < "$f"
    done
    echo "$name parts: $(q "$name" "SELECT count() FROM system.parts WHERE database='bench' AND table='src' AND active")"
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
    q "$name" "SELECT '$name', $i, duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3) AS user_ms, rows, part_type, peak_memory_usage FROM system.part_log WHERE database='bench' AND table='$t' AND event_type='MergeParts' ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT TSV"
}

trap 'for n in base fix; do [ -f $WORK/$n/pid ] && kill $(cat $WORK/$n/pid) 2>/dev/null || true; done' EXIT
for n in base fix; do start_server "$n"; setup "$n"; done

RES=$WORK/results_$MODE.tsv
: > "$RES"
for i in $(seq "$RUNS"); do
    for n in base fix; do run_one "$n" "$i" | tee -a "$RES"; done
done

echo "== summary ($MODE): name median_ms min max | median_user_ms"
for n in base fix; do
    awk -v n=$n '$1==n{print $3}' "$RES" | sort -n | awk -v n=$n '{a[NR]=$1} END{printf "%s duration median=%s min=%s max=%s\n", n, a[int((NR+1)/2)], a[1], a[NR]}'
    awk -v n=$n '$1==n{print $4}' "$RES" | sort -n | awk -v n=$n '{a[NR]=$1} END{printf "%s user_cpu  median=%s min=%s max=%s\n", n, a[int((NR+1)/2)], a[1], a[NR]}'
done

echo "== correctness: merged part files and query output (last run)"
for n in base fix; do
    q "$n" "SELECT '$n', hash_of_all_files, hash_of_uncompressed_files, bytes_on_disk FROM system.parts WHERE database='bench' AND table='r_$RUNS' AND active FORMAT TSV"
    echo "$n output $(q "$n" "SELECT * FROM bench.r_$RUNS ORDER BY ts, id FORMAT JSONEachRow" | md5sum)"
    echo "$n subcols $(q "$n" "SELECT event.unmapped.f0, event.^unmapped, event.class_uid, JSONAllPathsWithTypes(event) FROM bench.r_$RUNS ORDER BY ts, id FORMAT JSONEachRow" | md5sum)"
done
