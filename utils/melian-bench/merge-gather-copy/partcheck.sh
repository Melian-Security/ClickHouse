#!/usr/bin/env bash
# partcheck.sh [FIX_SUFFIX]: runs the tables of stateless tests 05484, 05512, 05536 and 05542 (without their
# final DROPs) on a base and a fix server under several block limits, and compares hash_of_all_files of the merged parts.
set -uo pipefail
L=${WORK:-/work/merge-gather-copy}; mkdir -p $L/pc; rm -f $L/pc/base.tsv $L/pc/fix.tsv
Q=/work/src/tests/queries/0_stateless
for name in base fix; do
  BIN=/work/bin/clickhouse-base; [ $name = fix ] && BIN=/work/bin/clickhouse-${1:-fix}
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
  taskset -c 80-95 $BIN server --config-file=$D/config.xml > /dev/null 2>&1 &
  echo $! > $D/pid
  for _ in $(seq 60); do $BIN client --port $PORT -q "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  # Block limits (rows:bytes): the tests' own, 1-byte limits (almost every batch ends at the limit), and large ones.
  for v in "own" "300:1" "50:700" "8192:100000000"; do
    for t in 05484_json_vertical_merge_gather_by_path 05512_json_vertical_merge_gather_bulk_copy 05536_json_vertical_merge_variant_ranges 05542_json_vertical_merge_gather_source_blocks; do
      if [ $v = own ]; then
        sed -E '/^DROP TABLE [a-z_]+;$/d' $Q/$t.sql > $D/t.sql
      else
        IFS=: read -r r b <<< "$v"
        sed -E -e '/^DROP TABLE [a-z_]+;$/d' -e "s/merge_max_block_size = [0-9]+, merge_max_block_size_bytes = [0-9]+/merge_max_block_size = $r, merge_max_block_size_bytes = $b/" $Q/$t.sql > $D/t.sql
      fi
      $BIN client --port $PORT -n -q "DROP DATABASE IF EXISTS d SYNC; CREATE DATABASE d"
      $BIN client --port $PORT -n --database d < $D/t.sql > $D/out.txt 2>&1
      echo "$v $t out $(md5sum < $D/out.txt | cut -c1-32)" | tee -a $L/pc/$name.tsv
      $BIN client --port $PORT -q "SELECT '$v', table, name, rows, hash_of_all_files FROM system.parts WHERE database = 'd' AND active ORDER BY table FORMAT TSV" | tee -a $L/pc/$name.tsv
    done
  done
  kill $(cat $D/pid)
  sleep 3
done
echo "== diff of outputs and part hashes base vs fix"
diff $L/pc/base.tsv $L/pc/fix.tsv && echo IDENTICAL
echo PARTCHECK_DONE
