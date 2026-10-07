#!/usr/bin/env bash
# A/B benchmark of inserts into a JSON column whose overflow paths go to shared data: JSONEachRow parsing
# (Array(JSON) values are serialized into shared data), statistics and the write of one compact part.
# The data of the shared-data-gather kit is reused (gen.py, schema.sql with compact parts for inserts).
#
#   insert.sh BIN_BASE BIN_FIX FILE [RUNS]
#
# Env: WORK (default /work/json-path-hashmap/insert), CPUS (default 8-15).
# Server-side parse: INSERT ... SELECT FROM file() in one thread, so query_log CPU covers parse and write.
# Every run prints the checksum of the inserted part; all runs of both binaries must share one checksum.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/work/json-path-hashmap/insert}
CPUS=${CPUS:-8-15}
BASE=$1; FIX=$2; FILE=$3; RUNS=${4:-5}

declare -A PORT=([base]=19810 [fix]=29810)
declare -A HPORT=([base]=18810 [fix]=28810)
declare -A BIN=([base]=$BASE [fix]=$FIX)

q() { local name=$1; shift; local query=${*: -1}; "${BIN[$name]}" client --port "${PORT[$name]}" "${@:1:$#-1}" -q "$query"; }

start_server() {
    local name=$1 dir=$WORK/$1
    rm -rf "$dir"; mkdir -p "$dir/user_files"
    ln -s "$FILE" "$dir/user_files/data.jsonl"
    cat > "$dir/config.xml" <<EOF
<clickhouse>
  <logger><level>information</level><log>$dir/server.log</log><errorlog>$dir/err.log</errorlog></logger>
  <tcp_port>${PORT[$name]}</tcp_port><http_port>${HPORT[$name]}</http_port>
  <listen_host>127.0.0.1</listen_host>
  <path>$dir/data/</path><tmp_path>$dir/tmp/</tmp_path><user_files_path>$dir/user_files/</user_files_path>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default/></profiles><quotas><default/></quotas>
  <query_log><database>system</database><table>query_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></query_log>
</clickhouse>
EOF
    taskset -c "$CPUS" "${BIN[$name]}" server --config-file="$dir/config.xml" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    for _ in $(seq 120); do q "$name" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server $name did not start"; tail -20 "$dir/err.log"; exit 1
}

stop_all() {
    for n in base fix; do
        local pidf=$WORK/$n/pid
        [ -f "$pidf" ] || continue
        kill "$(cat "$pidf")" 2>/dev/null || true
        for _ in $(seq 120); do kill -0 "$(cat "$pidf")" 2>/dev/null || break; sleep 1; done
        rm -f "$pidf"
    done
}
trap stop_all EXIT

# Inserts write compact parts, as small inserts do.
SCHEMA=$(sed -e 's/bench\.src/bench.ins/' -e 's/min_bytes_for_wide_part = 0/min_bytes_for_wide_part = 1000000000000/' "$HERE/../shared-data-gather/schema.sql")
for n in base fix; do
    start_server "$n"
    q "$n" "CREATE DATABASE bench"
    q "$n" "$SCHEMA"
done

RES=$WORK/results.tsv
: > "$RES"
: > "$WORK/checksums.txt"
for i in $(seq "$RUNS"); do
    for n in base fix; do
        q "$n" "TRUNCATE TABLE bench.ins SYNC"
        qid="ins_${n}_$i"
        q "$n" --query_id="$qid" --max_threads=1 --input_format_parallel_parsing=0 --max_insert_threads=1 \
            --max_insert_block_size=100000000 --min_insert_block_size_rows=100000000 --min_insert_block_size_bytes=0 \
            --max_block_size=100000000 --optimize_on_insert=0 \
            "INSERT INTO bench.ins SELECT * FROM file('data.jsonl', JSONEachRow)"
        q "$n" "SYSTEM FLUSH LOGS query_log"
        q "$n" "SELECT '$n', $i, query_duration_ms, round(ProfileEvents['UserTimeMicroseconds']/1e3), round(ProfileEvents['SystemTimeMicroseconds']/1e3), written_rows, memory_usage FROM system.query_log WHERE query_id='$qid' AND type='QueryFinish' FORMAT TSV" | tee -a "$RES"
        path=$(q "$n" "SELECT path FROM system.parts WHERE database='bench' AND table='ins' AND active")
        echo "$n $i parts $(echo "$path" | wc -l) files $(cd "$path" && find . -type f ! -name 'metadata_version.txt' -print0 | sort -z | xargs -0 md5sum | md5sum | cut -c1-32)" | tee -a "$WORK/checksums.txt"
    done
done

echo "== summary: median [min, max] over $RUNS runs (ms)"
for col in 3:duration 4:user_cpu; do
    c=${col%%:*}; label=${col#*:}
    for n in base fix; do
        awk -v n="$n" -v c="$c" '$1==n{print $c}' "$RES" | sort -n | awk -v n="$n" -v l="$label" '{a[NR]=$1} END{printf "%-5s %-9s median=%s min=%s max=%s\n", n, l, a[int((NR+1)/2)], a[1], a[NR]}'
    done
done
echo "== inserted parts (all runs must share one checksum)"
awk '{print $1, $6}' "$WORK/checksums.txt" | sort | uniq -c
