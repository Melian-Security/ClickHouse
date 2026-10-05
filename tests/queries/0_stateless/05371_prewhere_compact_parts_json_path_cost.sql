-- On compact parts no column has a measured size, so PREWHERE conditions are ranked by estimated
-- selectivity. A JSON path has no statistics and gets the default equality selectivity, which made
-- it look cheaper than a predicate on a small column with statistics, so the whole JSON column was
-- read first even when the small-column predicate rejects every row.

SET enable_analyzer = 1;
SET use_statistics = 1;
SET materialize_statistics_on_insert = 1;
SET optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 1;
SET move_all_conditions_to_prewhere = 1;
SET allow_reorder_prewhere_conditions = 1;
SET explain_query_plan_default = 'legacy';

DROP TABLE IF EXISTS t_prewhere_json_compact;

CREATE TABLE t_prewhere_json_compact
(
    id UInt64,
    activity_id Int64,
    n Nullable(Int64),
    event JSON(max_dynamic_paths = 8, `metadata.event_code` String)
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = '10G', min_rows_for_wide_part = 0, auto_statistics_types = 'basic, uniq_v2';

-- activity_id takes 10 odd values, so `activity_id = 12` is inside its min/max but matches nothing.
INSERT INTO t_prewhere_json_compact
SELECT
    number,
    1 + 2 * (number % 10),
    number % 100,
    concat('{"metadata":{"event_code":"c', toString(number % 50), '"},',
        arrayStringConcat(arrayMap(i -> concat('"g', toString((number + i * 7) % 40), '":{"v":"', repeat('v', 10 + i % 20), '"}'), range(20)), ','),
        '}')
FROM numbers(20000);

SELECT count() FROM system.parts
WHERE database = currentDatabase() AND table = 't_prewhere_json_compact' AND active AND part_type != 'Compact';

-- Returns the conditions of the PREWHERE filter in evaluation order.
SELECT '-- typed JSON path';
SELECT extractAll(replaceRegexpAll(explain, '__table1\.', ''), '(activity_id|event\.metadata\.event_code)') FROM (
    EXPLAIN actions = 1 SELECT count() FROM t_prewhere_json_compact
    WHERE event.metadata.event_code = 'no-such-code' AND activity_id = 12
) WHERE explain LIKE '%Prewhere filter column%';

SELECT '-- dynamic JSON path';
SELECT extractAll(replaceRegexpAll(explain, '__table1\.', ''), '(activity_id|event\.g7\.v)') FROM (
    EXPLAIN actions = 1 SELECT count() FROM t_prewhere_json_compact
    WHERE event.g7.v = 'no-such-value' AND activity_id = 12
) WHERE explain LIKE '%Prewhere filter column%';

-- Fixed-width columns are still ordered by selectivity: `n = 50` (1 in 100) before `activity_id = 11` (1 in 10).
SELECT '-- fixed-width columns';
SELECT extractAll(replaceRegexpAll(explain, '__table1\.', ''), '(activity_id|\\bn\\b)') FROM (
    EXPLAIN actions = 1 SELECT count() FROM t_prewhere_json_compact
    WHERE activity_id = 11 AND n = 50
) WHERE explain LIKE '%Prewhere filter column%';

SELECT '-- results do not depend on the order';
SELECT count() FROM t_prewhere_json_compact WHERE event.metadata.event_code = 'c7' AND activity_id = 15;
SELECT count() FROM t_prewhere_json_compact WHERE event.metadata.event_code = 'c7' AND activity_id = 15
SETTINGS allow_reorder_prewhere_conditions = 0;
SELECT count() FROM t_prewhere_json_compact WHERE toString(event.g7.v) LIKE 'vvvvvvvvvvvvvvv%' AND activity_id = 5;
SELECT count() FROM t_prewhere_json_compact WHERE toString(event.g7.v) LIKE 'vvvvvvvvvvvvvvv%' AND activity_id = 5
SETTINGS allow_reorder_prewhere_conditions = 0;

DROP TABLE t_prewhere_json_compact;
