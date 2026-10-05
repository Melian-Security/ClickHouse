#!/usr/bin/env bash
# One cold run of every benchmark query on one binary, printing the S3/prefetch/marks profile events.
#
#   profile.sh BIN [DELAY_MS] [TAG]
#
# Uses the table and MinIO container from `bench.sh setup`.
set -euo pipefail
cd "$(dirname "$0")"
BIN=$1; DELAY=${2:-50}; TAG=${3:-profile}
source <(sed -n '/^MINIO_IMAGE=/,/^cmd=\$1/p' bench.sh | grep -v '^cmd=')
WORK=${WORK:-/home/ssm-user/sdr-work}; PORT=19000
minio_up; set_delay "$DELAY"; start_server "$BIN"
while IFS=$'\t' read -r name sql; do
    drop_caches
    q --log_comment="profile;$TAG;$name" -q "$sql FORMAT Null"
done < <(queries)
set_delay 0
q -q "SYSTEM FLUSH LOGS"
q --format PrettyCompactMonoBlock -q "
    SELECT splitByChar(';', log_comment)[3] AS q, query_duration_ms AS ms,
        ProfileEvents['S3GetObject'] AS get, round(ProfileEvents['ReadBufferFromS3Microseconds'] / 1e3) AS s3_ms,
        ProfileEvents['RemoteFSPrefetches'] AS pf, ProfileEvents['RemoteFSPrefetchedReads'] AS pf_reads,
        ProfileEvents['RemoteFSUnprefetchedReads'] AS unpf_reads, ProfileEvents['RemoteFSCancelledPrefetches'] AS cancelled,
        round(ProfileEvents['SynchronousRemoteReadWaitMicroseconds'] / 1e3) AS sync_wait_ms,
        round(ProfileEvents['WaitMarksLoadMicroseconds'] / 1e3) AS marks_wait_ms, read_rows
    FROM system.query_log
    WHERE type = 'QueryFinish' AND log_comment LIKE 'profile;$TAG;%' ORDER BY event_time_microseconds"
stop_server
