-- Tags: no-random-settings, no-random-merge-tree-settings
-- A Vertical merge writes JSON, Dynamic and nested JSON columns in many blocks. Every block after the first one
-- takes the statistics of the first block; only the column objects that hold statistics are copied for that, the
-- data stays shared with the merged block. Every row must keep its values and types.

SET enable_json_type = 1, enable_dynamic_type = 1;

DROP TABLE IF EXISTS test_writer_statistics;
CREATE TABLE test_writer_statistics
(
    id UInt64,
    json JSON(max_dynamic_paths = 3, max_dynamic_types = 2, s String),
    d Dynamic(max_types = 2),
    arr Array(JSON(max_dynamic_paths = 2)),
    t Tuple(a JSON(max_dynamic_paths = 2), b String)
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    index_granularity = 64, merge_max_block_size = 300, merge_max_block_size_bytes = 20000;

SYSTEM STOP MERGES test_writer_statistics;

INSERT INTO test_writer_statistics SELECT number * 2,
    concat('{"s" : "s', toString(number), '", "a" : ', toString(number), ', "b" : "b', toString(number % 7), '"',
        if(number % 3 = 0, concat(', "c' , toString(number % 11), '" : ', toString(number)), ''), '}'),
    multiIf(number % 3 = 0, toString(number)::Dynamic, number % 3 = 1, number::Dynamic, [number, number + 1]::Dynamic),
    [concat('{"x" : ', toString(number), '}')::JSON(max_dynamic_paths = 2), concat('{"y" : "', toString(number), '", "z' , toString(number % 5), '" : 1}')::JSON(max_dynamic_paths = 2)],
    tuple(concat('{"p" : ', toString(number), ', "q' , toString(number % 4), '" : "v"}')::JSON(max_dynamic_paths = 2), toString(number))
FROM numbers(4000);
INSERT INTO test_writer_statistics SELECT number * 2 + 1,
    concat('{"s" : "', repeat('x', number % 30), '", "a" : "', toString(number), '"',
        if(number % 2 = 0, concat(', "d' , toString(number % 13), '" : [', toString(number), ']'), ''), '}'),
    multiIf(number % 4 = 0, NULL, number % 4 = 1, (number / 3)::Dynamic, toDate(number % 1000)::Dynamic),
    [concat('{"x" : "', toString(number), '", "w" : ', toString(number), '}')::JSON(max_dynamic_paths = 2)],
    tuple(concat('{"p" : "', toString(number), '"}')::JSON(max_dynamic_paths = 2), '')
FROM numbers(4000);

SELECT 'before merge';
SELECT count(), sum(cityHash64(id, toString(json), toString(d), toString(arr), toString(t))) FROM test_writer_statistics;
SELECT sum(cityHash64(id, dynamicType(json.a), dynamicType(d), arrayMap(x -> dynamicType(x.x), arr), dynamicType(t.a.p))) FROM test_writer_statistics;

SYSTEM START MERGES test_writer_statistics;
OPTIMIZE TABLE test_writer_statistics FINAL;

SELECT 'after merge';
SELECT count(), sum(cityHash64(id, toString(json), toString(d), toString(arr), toString(t))) FROM test_writer_statistics;
SELECT sum(cityHash64(id, dynamicType(json.a), dynamicType(d), arrayMap(x -> dynamicType(x.x), arr), dynamicType(t.a.p))) FROM test_writer_statistics;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_writer_statistics;
SELECT id, json, d, dynamicType(d), arr, t FROM test_writer_statistics WHERE id IN (0, 1, 2, 3, 6, 7, 7998, 7999) ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm FROM system.part_log WHERE database = currentDatabase() AND table = 'test_writer_statistics' AND event_type = 'MergeParts';

DROP TABLE test_writer_statistics;
