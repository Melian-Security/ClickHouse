#!/usr/bin/env bash
# run_test_local.sh TEST.sql: run one test with clickhouse local for base and fix, diff the outputs.
set -uo pipefail
T=/work/scripts/$1
for n in base fix; do
  rm -rf /work/mrt/t1-$n && mkdir -p /work/mrt/t1-$n && cd /work/mrt/t1-$n
  /work/bin/clickhouse-$n local --path /work/mrt/t1-$n/data --queries-file "$T" > /work/mrt/t1-$n.out 2> /work/mrt/t1-$n.err
  echo "$n exit $? lines $(wc -l < /work/mrt/t1-$n.out)"; head -5 /work/mrt/t1-$n.err
done
diff /work/mrt/t1-base.out /work/mrt/t1-fix.out && echo SAME
head -30 /work/mrt/t1-base.out | cut -c1-200
echo T1_DONE
