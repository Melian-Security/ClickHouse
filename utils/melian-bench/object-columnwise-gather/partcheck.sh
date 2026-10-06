#!/usr/bin/env bash
# object-columnwise-gather-partcheck.sh: runs the new test's tables (without the final DROPs) on base and fix servers
# with several block limits and compares the hashes of all files of the merged parts.
set -uo pipefail
L=/work/ocg; mkdir -p $L/pc; rm -f $L/pc/base.tsv $L/pc/fix.tsv
T=/work/src/tests/queries/0_stateless/05484_json_vertical_merge_gather_by_path.sql
for name in base fix; do
  BIN=/work/bin/clickhouse-$name; [ $name = fix ] && BIN=/work/bin/clickhouse-${1:-fix}
  PORT=19870; [ $name = fix ] && PORT=19880
  D=$L/pc/$name; rm -rf $D; mkdir -p $D/data $D/tmp $D/user_files
  cat > $D/config.xml <<EOF
<clickhouse>
  <logger><level>warning</level><log>$D/server.log</log><errorlog>$D/err.log</errorlog></logger>
  <tcp_port>$PORT</tcp_port><http_port>$((PORT - 1000))</http_port><listen_host>127.0.0.1</listen_host>
  <path>$D/data/</path><tmp_path>$D/tmp/</tmp_path><user_files_path>$D/user_files/</user_files_path>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users>
  <profiles><default/></profiles><quotas><default/></quotas>
  <part_log><database>system</database><table>part_log</table><flush_interval_milliseconds>1000</flush_interval_milliseconds></part_log>
</clickhouse>
EOF
  taskset -c 88-95 $BIN server --config-file=$D/config.xml > /dev/null 2>&1 &
  echo $! > $D/pid
  for _ in $(seq 60); do $BIN client --port $PORT -q "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  # Variants of the block limits: the test's own, tiny byte limits (a batch crosses the limit almost every time),
  # and large ones (no limit is reached).
  for v in "6000:300:4000:200" "1:300:1:200" "700:50:900:30" "100000000:8192:100000000:8192"; do
    IFS=: read -r b1 r1 b2 r2 <<< "$v"
    sed -e '/^DROP TABLE test_json_gather_by_path;$/d' -e '/^DROP TABLE test_json_gather_by_path_replacing;$/d' \
        -e "s/merge_max_block_size = 300, merge_max_block_size_bytes = 6000/merge_max_block_size = $r1, merge_max_block_size_bytes = $b1/" \
        -e "s/merge_max_block_size = 200, merge_max_block_size_bytes = 4000/merge_max_block_size = $r2, merge_max_block_size_bytes = $b2/" $T > $D/t.sql
    $BIN client --port $PORT -n -q "DROP DATABASE IF EXISTS d SYNC; CREATE DATABASE d"
    $BIN client --port $PORT -n --database d < $D/t.sql > $D/out-$v.txt 2>&1
    $BIN client --port $PORT -q "SELECT '$v', table, name, rows, hash_of_all_files FROM system.parts WHERE database = 'd' AND active ORDER BY table FORMAT TSV" | tee -a $L/pc/$name.tsv
    md5sum $D/out-$v.txt
  done
  kill $(cat $D/pid)
done
echo "== diff of part hashes base vs fix"
diff <(cut -f1,2,4,5 $L/pc/base.tsv) <(cut -f1,2,4,5 $L/pc/fix.tsv) && echo IDENTICAL
echo PARTCHECK_DONE
