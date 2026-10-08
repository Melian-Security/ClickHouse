#!/usr/bin/env bash
# readab.sh [RUNS]: alternating base/fix single-thread full reads of the 24 Compact source parts
# (bench.src) with the data loaded by the bench kit. Reports wall ms and server user CPU ms (system.events delta).
set -euo pipefail
RUNS=${1:-7}
W=${WORK:-/work/crm/bench}
CPUS=0-15
declare -A BIN=([base]=${BIN_BASE:-/work/bin/clickhouse-base} [fix]=${BIN_FIX:-/work/bin/clickhouse-fix})
declare -A PORT=([base]=19800 [fix]=29800)
start() { taskset -c $CPUS "${BIN[$1]}" server --config-file="$W/$1/config.xml" >/dev/null 2>&1 & echo $! > "$W/$1/pid";
  for _ in $(seq 120); do "${BIN[$1]}" client --port "${PORT[$1]}" -q 'SELECT 1' >/dev/null 2>&1 && return 0; sleep 1; done; exit 1; }
stop() { kill "$(cat "$W/$1/pid")"; for _ in $(seq 60); do kill -0 "$(cat "$W/$1/pid")" 2>/dev/null || break; sleep 1; done; }
for n in base fix; do start $n; done
trap 'stop base; stop fix' EXIT
R=$W/read-results.tsv; : > "$R"
for i in $(seq "$RUNS"); do
  for n in base fix; do
    ev() { "${BIN[$n]}" client --port "${PORT[$n]}" -q "SELECT value FROM system.events WHERE event = 'UserTimeMicroseconds'"; }
    u0=$(ev); t0=$(date +%s%N)
    "${BIN[$n]}" client --port "${PORT[$n]}" --max_threads 1 --use_uncompressed_cache 0 -q "SELECT * FROM bench.src FORMAT Null"
    t1=$(date +%s%N); u1=$(ev)
    echo -e "$n\t$i\t$(( (t1 - t0) / 1000000 ))\t$(( (u1 - u0) / 1000 ))" | tee -a "$R"
  done
done
for c in 3:wall 4:user_cpu; do
  for n in base fix; do
    awk -v n=$n -v c=${c%%:*} '$1==n{print $c}' "$R" | sort -n | awk -v n=$n -v l=${c#*:} '{a[NR]=$1} END{printf "%-5s %-9s median=%s min=%s max=%s\n", n, l, a[int((NR+1)/2)], a[1], a[NR]}'
  done
done
echo "READAB DONE"
