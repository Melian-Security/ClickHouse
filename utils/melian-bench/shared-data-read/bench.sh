#!/usr/bin/env bash
# Cold-read A/B of JSON `advanced` shared data in Wide parts on an S3 disk (MinIO), base vs fix binary.
#
#   bench.sh setup  BIN            # MinIO + table + synthetic data (written by BIN), OPTIMIZE FINAL
#   bench.sh run    BIN_BASE BIN_FIX [RUNS] [DELAY_MS]
#   bench.sh check  BIN_BASE BIN_FIX # compare query results of both binaries
#
# The table lives on a plain S3 disk (no filesystem cache) backed by a MinIO container. `run` adds
# DELAY_MS (default 50) of netem latency on the docker bridge, so every request to MinIO pays an
# S3-like round trip, then alternates the binaries: each run starts a server, runs every query once
# with all caches dropped before it, and stops the server. Results are read from system.query_log.
# Environment: WORK (default /home/ssm-user/sdr-work), ROWS_PER_FILE, NUM_FILES.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/home/ssm-user/sdr-work}
NUM_FILES=${NUM_FILES:-160}
ROWS_PER_FILE=${ROWS_PER_FILE:-10500}
PORT=19000
mkdir -p "$WORK"

# MinIO no longer publishes community images or binaries; the Chainguard build is the same server.
MINIO_IMAGE=${MINIO_IMAGE:-cgr.dev/chainguard/minio:latest}

minio_up() {
    if ! sudo docker ps --format '{{.Names}}' | grep -qx sdr-minio; then
        sudo docker rm -f sdr-minio >/dev/null 2>&1 || true
        mkdir -p "$WORK/minio"
        sudo docker run -d -u 0 --name sdr-minio -v "$WORK/minio:/data" -e MINIO_ROOT_USER=minioadmin \
            -e MINIO_ROOT_PASSWORD=minioadmin "$MINIO_IMAGE" server /data >/dev/null
        sleep 5
        curl -s -o /dev/null --aws-sigv4 "aws:amz:us-east-1:s3" --user minioadmin:minioadmin -X PUT "http://$(minio_ip):9000/bench" || true
    fi
}

minio_ip() { sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' sdr-minio; }

set_delay() {
    sudo tc qdisc del dev docker0 root 2>/dev/null || true
    if [ "${1:-0}" != 0 ]; then sudo tc qdisc add dev docker0 root netem delay "${1}ms"; fi
}

start_server() {
    local bin=$1 dir=$WORK/server
    mkdir -p "$dir"
    cat > "$dir/config.xml" <<EOF
<clickhouse>
  <logger><level>${LOGLEVEL:-information}</level><log>$dir/server.log</log><errorlog>$dir/err.log</errorlog></logger>
  <tcp_port>$PORT</tcp_port><http_port>18123</http_port>
  <path>$dir/data/</path><tmp_path>$dir/tmp/</tmp_path><user_files_path>$WORK/gen/</user_files_path>
  <mark_cache_size>5368709120</mark_cache_size>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default/></profiles><quotas><default/></quotas>
  <query_log><database>system</database><table>query_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></query_log>
  <storage_configuration>
    <disks><s3d><type>s3</type><endpoint>http://$(minio_ip):9000/bench/data/</endpoint>
      <access_key_id>minioadmin</access_key_id><secret_access_key>minioadmin</secret_access_key></s3d></disks>
    <policies><s3><volumes><main><disk>s3d</disk></main></volumes></s3></policies>
  </storage_configuration>
</clickhouse>
EOF
    "$bin" server --config-file="$dir/config.xml" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    for _ in $(seq 120); do "$bin" client --port $PORT -q "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
    echo "server did not start"; exit 1
}

stop_server() {
    local pid; pid=$(cat "$WORK/server/pid")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 120); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
}

q() { "$BIN" client --port $PORT "$@"; }

drop_caches() {
    for c in "MARK CACHE" "UNCOMPRESSED CACHE" "FILESYSTEM CACHE" "PAGE CACHE" "QUERY CONDITION CACHE" \
             "PRIMARY INDEX CACHE" "SKIPPING INDEX CACHE" "INDEX MARK CACHE" "INDEX UNCOMPRESSED CACHE"; do
        q -q "SYSTEM DROP $c" 2>/dev/null || true
    done
}

# Queries: name<TAB>sql. {POINT} and {PATHS} are filled from files written by `setup`.
queries() {
    local point paths
    point=$(cat "$WORK/point.txt"); paths=$(cat "$WORK/paths.txt")
    cat <<EOF
sub_point	SELECT event.^unmapped FROM bench.t WHERE (k, ts, id) IN ($point)
sub_range	SELECT event.^unmapped FROM bench.t WHERE k = 'tenant-7'
paths_point	SELECT $paths FROM bench.t WHERE (k, ts, id) IN ($point)
paths_all	SELECT $paths FROM bench.t
event_range	SELECT event FROM bench.t WHERE k = 'tenant-7'
allpaths_range	SELECT arrayJoin(JSONAllPaths(event)) AS p, count() FROM bench.t WHERE k = 'tenant-7' GROUP BY p
EOF
}

cmd=$1; shift
case $cmd in
setup)
    BIN=$1
    minio_up; set_delay 0
    if [ ! -f "$WORK/gen/part_$(printf %03d $((NUM_FILES - 1))).jsonl" ]; then
        python3 "$HERE/gen.py" "$WORK/gen" "$NUM_FILES" "$ROWS_PER_FILE" 42 4
    fi
    start_server "$BIN"
    q -q "CREATE DATABASE IF NOT EXISTS bench"
    q -q "DROP TABLE IF EXISTS bench.t SYNC"
    q -q "$(cat "$HERE/schema.sql")"
    for f in "$WORK"/gen/*.jsonl; do
        q --optimize_on_insert=0 -q "INSERT INTO bench.t FORMAT JSONEachRow" < "$f"
    done
    q -q "OPTIMIZE TABLE bench.t FINAL" --receive_timeout=36000
    q -q "SELECT partition, name, part_type, rows, formatReadableSize(bytes_on_disk) FROM system.parts WHERE database='bench' AND table='t' AND active"
    # One row per part for the point lookups, and the three most frequent shared-data paths.
    q --format TSVRaw -q "SELECT arrayStringConcat(groupArray(format('(\'{}\', toDateTime(\'{}\'), {})', k, toString(ts), toString(id))), ', ') FROM (SELECT k, ts, id FROM bench.t WHERE k = 'tenant-5' ORDER BY ts LIMIT 1 BY _partition_id)" > "$WORK/point.txt"
    q --format TSVRaw -q "SELECT arrayStringConcat(groupArray(concat('event.', p)), ', ') FROM (SELECT p FROM (SELECT arrayJoin(JSONSharedDataPaths(event)) AS p FROM bench.t WHERE k = 'tenant-3') GROUP BY p ORDER BY count() DESC, p LIMIT 3)" > "$WORK/paths.txt"
    cat "$WORK/point.txt" "$WORK/paths.txt"
    stop_server
    ;;
run)
    BASE=$1; FIX=$2; RUNS=${3:-5}; DELAY=${4:-50}
    minio_up; set_delay "$DELAY"
    tag=$(date +%s)
    for i in $(seq "$RUNS"); do
        for v in base fix; do
            BIN=$BASE; [ $v = fix ] && BIN=$FIX
            start_server "$BIN"
            while IFS=$'\t' read -r name sql; do
                drop_caches
                q --log_comment="$tag;$v;$i;$name" -q "$sql FORMAT Null"
            done < <(queries)
            stop_server
        done
    done
    set_delay 0
    BIN=$BASE; start_server "$BIN"
    q -q "SYSTEM FLUSH LOGS"
    q --format PrettyCompactMonoBlock -q "
        WITH splitByChar(';', log_comment) AS c
        SELECT c[4] AS query, c[2] AS v, count() AS n,
            round(median(query_duration_ms)) AS med_ms, min(query_duration_ms) AS min_ms, max(query_duration_ms) AS max_ms,
            round(median(ProfileEvents['S3GetObject'])) AS s3_get,
            round(median(ProfileEvents['ReadBufferFromS3Microseconds']) / 1e3) AS s3_read_ms,
            round(median(ProfileEvents['RemoteFSPrefetches'])) AS prefetches,
            round(median(ProfileEvents['RemoteFSPrefetchedReads'])) AS prefetched_reads,
            round(median(ProfileEvents['RemoteFSUnprefetchedReads'])) AS unprefetched_reads,
            round(median(ProfileEvents['RemoteFSCancelledPrefetches'])) AS cancelled,
            round(median(ProfileEvents['SynchronousRemoteReadWaitMicroseconds']) / 1e3) AS sync_wait_ms,
            round(median(ProfileEvents['WaitMarksLoadMicroseconds']) / 1e3) AS marks_wait_ms
        FROM system.query_log
        WHERE type = 'QueryFinish' AND c[1] = '$tag'
        GROUP BY query, v ORDER BY query, v DESC" | tee "$WORK/results_$tag.txt"
    q --format TSV -q "
        WITH splitByChar(';', log_comment) AS c
        SELECT c[2], c[3], c[4], query_duration_ms FROM system.query_log
        WHERE type = 'QueryFinish' AND c[1] = '$tag' ORDER BY event_time_microseconds" > "$WORK/raw_$tag.tsv"
    stop_server
    ;;
check)
    BASE=$1; FIX=$2
    minio_up; set_delay 0
    for v in base fix; do
        BIN=$BASE; [ $v = fix ] && BIN=$FIX
        start_server "$BIN"
        while IFS=$'\t' read -r name sql; do
            echo "$v $name $(q -q "$sql FORMAT JSONEachRow" | sort | md5sum | cut -c1-32)"
        done < <(queries)
        stop_server
    done | sort -k2,2 -k1,1 | tee "$WORK/check.txt"
    ;;
esac
