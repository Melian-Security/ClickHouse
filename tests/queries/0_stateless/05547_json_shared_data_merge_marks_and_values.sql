-- Tags: no-random-settings, no-random-merge-tree-settings
-- Parts with different dynamic paths are merged, so values of every type move from dynamic paths into shared data.
-- The paths of the merged part are then read one by one, which uses the marks of every path and substream in shared
-- data. Small compressed blocks put block boundaries inside granules and inside values.

DROP TABLE IF EXISTS test_json_merge_marks;

CREATE TABLE test_json_merge_marks (id UInt64, json JSON(max_dynamic_paths = 3)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 256,
    min_compress_block_size = 1024, max_compress_block_size = 4096,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced', object_shared_data_buckets_for_wide_part = 2;

SYSTEM STOP MERGES test_json_merge_marks;

-- Dynamic paths s, i and b. Strings of all lengths up to longer than a compressed block, signed numbers, NULLs.
INSERT INTO test_json_merge_marks SELECT number * 3, concat('{"s":"', repeat('x', number % 5000), '","i":', toString(toInt64(number) - 1500),
    ',"b":', if(number % 3 = 0, 'true', 'false'), if(number % 4 = 0, '', concat(',"e":""')), ',"n":', if(number % 5 = 0, 'null', toString(number)),
    ',"m":', if(number % 2 = 0, toString(number), concat('"', toString(number), '"')), '}') FROM numbers(3000);
-- Dynamic paths u, f and t. Numbers that do not fit Int64, floats, arrays and nested objects.
INSERT INTO test_json_merge_marks SELECT number * 3 + 1, concat('{"u":', toString(9223372036854775808 + number), ',"f":', toString(number * 1.25),
    ',"t":"t', toString(number), '","a":[', toString(number), ',', toString(number % 7), '],"o":{"x":', toString(number % 11), ',"y":"', toString(number), '"}',
    if(number % 6 = 0, concat(',"s":"', repeat('y', number % 300), '","i":', toString(number)), ''), '}') FROM numbers(3000);
-- Dynamic paths c1, c2 and c3 in every row, so they stay dynamic paths in the merged part.
INSERT INTO test_json_merge_marks SELECT number * 3 + 2, concat('{"c1":', toString(number), ',"c2":"', toString(number), '","c3":', toString(number % 2 = 0),
    if(number % 9 = 0, concat(',"b":true,"u":', toString(number), ',"f":"', toString(number), '"'), ''), '}') FROM numbers(4000);

SELECT 'zero-level parts';
SELECT JSONDynamicPaths(json) AS paths, count() FROM test_json_merge_marks GROUP BY paths ORDER BY paths;
SELECT count(), sum(cityHash64(toString(json))) FROM test_json_merge_marks;
SELECT sum(cityHash64(toString(json.s))), sum(cityHash64(toString(json.i))), sum(cityHash64(toString(json.b))), sum(cityHash64(toString(json.e))),
    sum(cityHash64(toString(json.n))), sum(cityHash64(toString(json.m))), sum(cityHash64(toString(json.u))), sum(cityHash64(toString(json.f))),
    sum(cityHash64(toString(json.t))), sum(cityHash64(toString(json.a))), sum(cityHash64(toString(json.o.x))), sum(cityHash64(toString(json.o.y))),
    sum(cityHash64(toString(json.^o))), sum(cityHash64(toString(json.c2)))
FROM test_json_merge_marks;

SELECT 'merged';
SYSTEM START MERGES test_json_merge_marks;
OPTIMIZE TABLE test_json_merge_marks FINAL;
SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_json_merge_marks' AND active;
SELECT JSONDynamicPaths(json) AS paths, count() FROM test_json_merge_marks GROUP BY paths ORDER BY paths;
SELECT count(), sum(cityHash64(toString(json))) FROM test_json_merge_marks;
SELECT sum(cityHash64(toString(json.s))), sum(cityHash64(toString(json.i))), sum(cityHash64(toString(json.b))), sum(cityHash64(toString(json.e))),
    sum(cityHash64(toString(json.n))), sum(cityHash64(toString(json.m))), sum(cityHash64(toString(json.u))), sum(cityHash64(toString(json.f))),
    sum(cityHash64(toString(json.t))), sum(cityHash64(toString(json.a))), sum(cityHash64(toString(json.o.x))), sum(cityHash64(toString(json.o.y))),
    sum(cityHash64(toString(json.^o))), sum(cityHash64(toString(json.c2)))
FROM test_json_merge_marks;
SELECT id, length(ifNull(json.s.:String, '')), json.i, json.b, json.e, json.n, json.m, json.u, json.f, json.t, json.a, json.^o
FROM test_json_merge_marks WHERE id % 1999 = 0 OR id IN (1, 4, 3001, 8999) ORDER BY id;
SELECT id, json.u, json.f, json.i FROM test_json_merge_marks WHERE id BETWEEN 2000 AND 2020 ORDER BY id;

DROP TABLE test_json_merge_marks;
