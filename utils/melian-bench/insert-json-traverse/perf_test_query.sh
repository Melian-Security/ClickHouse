#!/usr/bin/env bash
# perf_test_query.sh RUNS NAME... : the query of tests/performance/json_parse_varying_keys.xml (and of
# json_parse_runs_of_same_keys.xml) in clickhouse-local, one thread on core 2, alternating base and NAME; CPU seconds per run.
set -uo pipefail
RUNS=${1:-7}; shift
D=/work/ijt/perfxml; mkdir -p $D
TYPE='JSON(max_dynamic_paths=64, `header.id` UUID, `header.source.name` String, `header.source.group` String, kind Int64, level Int64, message String, `endpoint.ip` Nullable(String), `endpoint.port` Int64)'
gen() { # file template-expr
  [ -s $D/$1 ] && return
  /work/bin/clickhouse-base local -q "SELECT concat(
    '{\"header\":{\"id\":\"', toString(generateUUIDv4()), '\",\"source\":{\"name\":\"p', toString(t), '\",\"group\":\"v', toString(t), '\"}},',
    '\"kind\":', toString(number % 7), ',\"level\":', toString(number % 5), ',\"message\":\"m', toString(number), '\",',
    if(number % 3 = 0, '', concat('\"endpoint\":{\"ip\":\"10.0.', toString(number % 256), '.1\",\"port\":', toString(number % 65536), '},')),
    '\"payload\":{', $2, '}}')
  FROM (SELECT number, $3 AS t FROM numbers(200000)) FORMAT TSVRaw" > $D/$1
}
gen varying.tsv "arrayStringConcat(arrayMap(i -> concat('\"k', toString((t * 7 + i * 3) % 90), '\":', if(number % 7 = i % 7, '\"x\"', toString(i))), range(20 + t % 10)), ',')" "number % 40"
gen runs.tsv "arrayStringConcat(arrayMap(i -> concat('\"k', toString(t * 10 + i), '\":', if(number % 7 = i % 7, '\"x\"', toString(i))), range(30)), ',')" "intDiv(number, 100) % 40"
wc -l $D/varying.tsv $D/runs.tsv
for f in varying runs; do
  for r in $(seq $RUNS); do
    for b in base "$@"; do
      TIMEFORMAT='%U %S'
      { time taskset -c 2 /work/bin/clickhouse-$b local --max_threads=1 \
        -q "SELECT s::$TYPE FROM file('$D/$f.tsv', 'TSVRaw', 's String') FORMAT Null" ; } 2> $D/t.txt
      echo -e "$f\t$b\t$r\t$(awk '{print $1 + $2}' $D/t.txt)"
    done
  done
done > $D/res.tsv
python3 - <<'EOF'
import collections, statistics
d = collections.defaultdict(list)
for l in open("/work/ijt/perfxml/res.tsv"):
    f, b, r, t = l.split("\t"); d[(f, b)].append(float(t))
for (f, b), v in sorted(d.items()):
    print(f, b, "median %.3f min %.3f max %.3f n %d" % (statistics.median(v), min(v), max(v), len(v)))
EOF
echo PERFXML DONE
