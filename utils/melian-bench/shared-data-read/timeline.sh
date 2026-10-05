#!/usr/bin/env bash
# One cold run of one benchmark query with test-level server logs, then a per-second count of the files
# opened on S3 by kind: shared data streams, Dynamic/Object prefixes, variant discriminators, marks.
# Shows whether the reads of a phase overlap (a burst) or wait for each other (a steady trickle).
#
#   timeline.sh BIN QUERY_NAME [DELAY_MS]      # QUERY_NAME is a name from `queries` in bench.sh
set -euo pipefail
cd "$(dirname "$0")"
BIN=$1; QNAME=$2; DELAY=${3:-50}
source <(sed -n '/^MINIO_IMAGE=/,/^cmd=\$1/p' bench.sh | grep -v '^cmd=')
WORK=${WORK:-/home/ssm-user/sdr-work}; PORT=19000
minio_up; set_delay "$DELAY"; LOGLEVEL=test start_server "$BIN"
: > "$WORK/server/server.log"
sql=$(queries | awk -F'\t' -v n="$QNAME" '$1 == n {print $2}')
drop_caches
q --time -q "$sql FORMAT Null"
set_delay 0
stop_server
grep "Reading from file" "$WORK/server/server.log" | awk '{
    t = substr($2, 1, 8); c = "other"
    if ($0 ~ /object_shared_data/) c = "shared_data"
    else if ($0 ~ /cmrk/) c = "marks"
    else if ($0 ~ /dynamic_structure|object_structure/) c = "prefix"
    else if ($0 ~ /variant_discr/) c = "discr"
    print t, c }' | sort | uniq -c | awk '{a[$2] = a[$2] " " $3 "=" $1} END {for (k in a) print k, a[k]}' | sort
