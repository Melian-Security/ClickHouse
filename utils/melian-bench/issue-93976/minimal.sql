-- Minimal reproducer for issue 93976: run with clickhouse-client against a server.
-- activity_id = 12 never matches (values are odd, 1..19, inside its min/max), so evaluating it
-- first means the JSON column is never read. Compact parts (the default for small parts).
DROP TABLE IF EXISTS t_93976;

CREATE TABLE t_93976
(
    id UInt64,
    activity_id Int64,
    event JSON
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = '10G';

INSERT INTO t_93976
SELECT
    number,
    1 + 2 * (number % 10),
    concat('{"metadata":{"event_code":"c', toString(number % 50), '"},',
        arrayStringConcat(arrayMap(i -> concat('"g', toString((number * 7 + i * 13) % 300), '":{"v":"', repeat('v', 10 + i % 20), toString(number % 1000), '"}'), range(60)), ','),
        '}')
FROM numbers(1000000);

SELECT count() FROM t_93976 WHERE activity_id = 12 AND event.metadata.event_code = 'no-such-code'
SETTINGS allow_reorder_prewhere_conditions = 0, log_comment = 't_93976 reorder=0';

SELECT count() FROM t_93976 WHERE activity_id = 12 AND event.metadata.event_code = 'no-such-code'
SETTINGS allow_reorder_prewhere_conditions = 1, log_comment = 't_93976 reorder=1';

SYSTEM FLUSH LOGS query_log;

SELECT
    log_comment,
    formatReadableSize(ProfileEvents['ReadCompressedBytes']) AS read_compressed,
    formatReadableSize(read_bytes) AS read_uncompressed,
    query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish' AND log_comment LIKE 't_93976 reorder=%' AND current_database = currentDatabase()
ORDER BY log_comment;
