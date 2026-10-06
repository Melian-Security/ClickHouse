-- Tags: no-random-merge-tree-settings, no-random-settings
-- A Vertical merge that writes several columns at the same time writes the same part as one that writes them one after another,
-- including the columns of a Nested, which share their offsets, and columns with skip indexes.

DROP TABLE IF EXISTS t_vertical_serial;
DROP TABLE IF EXISTS t_vertical_parallel;

CREATE TABLE t_vertical_serial
(
    id UInt64,
    s String,
    lc LowCardinality(String),
    arr Array(String),
    m Map(String, UInt64),
    n Nested(a UInt32, b String),
    j JSON(max_dynamic_paths = 4, x UInt64),
    d Dynamic,
    t Tuple(a UInt64, b String),
    INDEX idx_s s TYPE bloom_filter GRANULARITY 1,
    INDEX idx_lc lc TYPE set(100) GRANULARITY 1
)
ENGINE = MergeTree
ORDER BY id
SETTINGS
    min_bytes_for_wide_part = 0,
    index_granularity = 128,
    vertical_merge_algorithm_min_rows_to_activate = 1,
    vertical_merge_algorithm_min_columns_to_activate = 1,
    vertical_merge_max_parallel_columns = 1;

CREATE TABLE t_vertical_parallel AS t_vertical_serial;
ALTER TABLE t_vertical_parallel MODIFY SETTING vertical_merge_max_parallel_columns = 4;

SYSTEM STOP MERGES t_vertical_serial;
SYSTEM STOP MERGES t_vertical_parallel;

INSERT INTO t_vertical_serial SELECT
    number,
    toString(number % 1000),
    toString(number % 17),
    arrayMap(x -> toString(x), range(number % 5)),
    map(toString(number % 3), number),
    range(number % 4),
    arrayMap(x -> toString(x * number), range(number % 4)),
    concat('{"x": ', toString(number), ', "k', toString(number % 10), '": "', toString(number), '", "arr": [', toString(number % 7), ']}'),
    if(number % 2, number::Dynamic, toString(number)::Dynamic),
    (number, toString(number))
FROM numbers(9000);
INSERT INTO t_vertical_serial SELECT number + 9000, 'x', 'y', ['a'], map('a', 1), [1], ['b'], '{"x": 1, "other": "v"}', 1::Dynamic, (1, 'a') FROM numbers(1000);
INSERT INTO t_vertical_serial SELECT number + 20000, toString(number), 'z', [], map(), [], [], '{"y": [1, 2]}', NULL, (2, 'b') FROM numbers(1500);

INSERT INTO t_vertical_parallel SELECT
    number,
    toString(number % 1000),
    toString(number % 17),
    arrayMap(x -> toString(x), range(number % 5)),
    map(toString(number % 3), number),
    range(number % 4),
    arrayMap(x -> toString(x * number), range(number % 4)),
    concat('{"x": ', toString(number), ', "k', toString(number % 10), '": "', toString(number), '", "arr": [', toString(number % 7), ']}'),
    if(number % 2, number::Dynamic, toString(number)::Dynamic),
    (number, toString(number))
FROM numbers(9000);
INSERT INTO t_vertical_parallel SELECT number + 9000, 'x', 'y', ['a'], map('a', 1), [1], ['b'], '{"x": 1, "other": "v"}', 1::Dynamic, (1, 'a') FROM numbers(1000);
INSERT INTO t_vertical_parallel SELECT number + 20000, toString(number), 'z', [], map(), [], [], '{"y": [1, 2]}', NULL, (2, 'b') FROM numbers(1500);

SELECT 'parts before merge', (SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 't_vertical_serial' AND active),
    (SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 't_vertical_parallel' AND active);

SYSTEM START MERGES t_vertical_serial;
SYSTEM START MERGES t_vertical_parallel;
OPTIMIZE TABLE t_vertical_serial FINAL;
OPTIMIZE TABLE t_vertical_parallel FINAL;

SYSTEM FLUSH LOGS part_log;
SELECT table, merge_algorithm FROM system.part_log
WHERE database = currentDatabase() AND table IN ('t_vertical_serial', 't_vertical_parallel') AND event_type = 'MergeParts'
ORDER BY table;

SELECT 'same files',
    (SELECT hash_of_all_files FROM system.parts WHERE database = currentDatabase() AND table = 't_vertical_serial' AND active)
    = (SELECT hash_of_all_files FROM system.parts WHERE database = currentDatabase() AND table = 't_vertical_parallel' AND active);

SELECT count(), groupBitXor(cityHash64(id, s, lc, arr, m, n.a, n.b, toString(j), toString(d), t)) = (
    SELECT groupBitXor(cityHash64(id, s, lc, arr, m, n.a, n.b, toString(j), toString(d), t)) FROM t_vertical_serial)
FROM t_vertical_parallel;
SELECT sum(length(n.a)), sum(length(n.b)), sum(j.x), countIf(j.k3 IS NOT NULL) FROM t_vertical_parallel;
SELECT count() FROM t_vertical_parallel WHERE s = '42';
CHECK TABLE t_vertical_parallel SETTINGS check_query_single_value_result = 1;

DROP TABLE t_vertical_serial;
DROP TABLE t_vertical_parallel;
