-- Tags: no-random-merge-tree-settings
-- Vertical merges of Wide parts write every column with a separate writer, which skips the offsets
-- streams written by the previous columns (Nested), keeps marks in the mark cache and may replace long
-- stream names with their hashes. Check the merged data for a JSON column with many substreams.

DROP TABLE IF EXISTS t_wide_vertical_merge_streams;

CREATE TABLE t_wide_vertical_merge_streams
(
    id UInt64,
    n Nested(a UInt64, b String),
    json JSON(max_dynamic_paths = 4, `typed.arr` Array(UInt64), `typed.str` String),
    column_with_a_name_longer_than_the_maximum_file_name_length Array(String)
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 7, index_granularity_bytes = 0,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    replace_long_file_name_to_hash = 1, max_file_name_length = 32, prewarm_mark_cache = 1,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets';

SYSTEM STOP MERGES t_wide_vertical_merge_streams;

INSERT INTO t_wide_vertical_merge_streams
SELECT
    number,
    range(number % 4),
    arrayMap(x -> toString(x), range(number % 4)),
    ('{"typed":{"arr":[' || arrayStringConcat(arrayMap(x -> toString(x), range(number % 3)), ',') || '],"str":"s' || toString(number) || '"},'
        || arrayStringConcat(arrayMap(i -> '"k' || toString((number + i) % 20) || '":' || if(i % 2 = 0, toString(number * i), '"v' || toString(i) || '"'), range(6)), ',')
        || ',"arr":[' || arrayStringConcat(arrayMap(x -> '{"x":' || toString(x) || '}', range(number % 3)), ',') || ']}')::JSON,
    arrayMap(x -> repeat('a', x), range(number % 5))
FROM numbers(0, 100);

INSERT INTO t_wide_vertical_merge_streams
SELECT
    number,
    range(number % 3),
    arrayMap(x -> toString(x * 2), range(number % 3)),
    ('{"typed":{"arr":[' || arrayStringConcat(arrayMap(x -> toString(x), range(number % 2)), ',') || '],"str":"t' || toString(number) || '"},'
        || arrayStringConcat(arrayMap(i -> '"k' || toString((number * 7 + i) % 25) || '":' || if(i % 3 = 0, '"w' || toString(number) || '"', toString(i)), range(5)), ',')
        || '}')::JSON,
    arrayMap(x -> repeat('b', x), range(number % 4))
FROM numbers(100, 150);

INSERT INTO t_wide_vertical_merge_streams
SELECT number, [], [], '{}'::JSON, [] FROM numbers(250, 10);

SELECT 'before';
SELECT count(), sum(length(n.a)), sum(arraySum(n.a)), sum(length(json.typed.arr)), sum(length(column_with_a_name_longer_than_the_maximum_file_name_length))
FROM t_wide_vertical_merge_streams;

CREATE TEMPORARY TABLE hashes (stage String, h UInt64);
INSERT INTO hashes SELECT 'before', cityHash64(groupArray(toString(tuple(id, n.a, n.b, toString(json), column_with_a_name_longer_than_the_maximum_file_name_length)))) FROM (SELECT * FROM t_wide_vertical_merge_streams ORDER BY id);

SYSTEM START MERGES t_wide_vertical_merge_streams;
OPTIMIZE TABLE t_wide_vertical_merge_streams FINAL;

SELECT 'after';
SELECT count(), uniqExact(_part) FROM t_wide_vertical_merge_streams;
INSERT INTO hashes SELECT 'after', cityHash64(groupArray(toString(tuple(id, n.a, n.b, toString(json), column_with_a_name_longer_than_the_maximum_file_name_length)))) FROM (SELECT * FROM t_wide_vertical_merge_streams ORDER BY id);
SELECT uniqExact(h) FROM hashes;

SELECT json.typed.arr, json.typed.str, json.k5, json.k11, json.arr[].x, n.a, n.b FROM t_wide_vertical_merge_streams WHERE id IN (5, 77, 123, 249, 255) ORDER BY id;
SELECT id, json.^typed FROM t_wide_vertical_merge_streams WHERE id IN (8, 200) ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm FROM system.part_log
WHERE database = currentDatabase() AND table = 't_wide_vertical_merge_streams' AND event_type = 'MergeParts';

DROP TABLE t_wide_vertical_merge_streams;
