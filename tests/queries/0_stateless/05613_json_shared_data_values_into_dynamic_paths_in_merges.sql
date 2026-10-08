-- Values of JSON paths that are in shared data in one part and dynamic paths in the merged part,
-- for the types that are read from shared data without their serialization and for the others.

SET enable_json_type = 1;

DROP TABLE IF EXISTS test_json_shared_data_values;

CREATE TABLE test_json_shared_data_values (id UInt64, json JSON(max_dynamic_paths = 4))
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets';

SYSTEM STOP MERGES test_json_shared_data_values;

-- In these parts paths a, b, c and d fill the dynamic paths, so all the others go to shared data.
INSERT INTO test_json_shared_data_values SELECT number, toJSONString(map('a', number, 'b', number, 'c', number, 'd', number)) FROM numbers(10);
INSERT INTO test_json_shared_data_values SELECT 10 + number, concat('{"a" : 1, "b" : 2, "c" : 3, "d" : 4, "s" : "', repeat('x', number), '", "i" : ', toString(number * 1000000007), ', "f" : ', toString(number / 4), ', "t" : ', if(number % 2, 'true', 'false'), ', "m" : ', if(number % 3 = 0, toString(number), concat('"', toString(number), '"')), ', "n" : -', toString(number), ', "arr" : [', toString(number), ', 1]}') FROM numbers(30);
-- In these parts paths s, i, m and t are dynamic paths, and the most frequent ones, so they are the dynamic paths of the merged part.
INSERT INTO test_json_shared_data_values SELECT 100 + number, concat('{"s" : "', toString(number), '", "i" : ', toString(number), '}') FROM numbers(1000);
INSERT INTO test_json_shared_data_values SELECT 2000 + number, concat('{"m" : ', toString(number), ', "t" : true}') FROM numbers(500);

SELECT 'before merge';
SELECT id, json.s, json.i, json.f, json.t, json.m, json.n, json.arr, dynamicType(json.s), dynamicType(json.i), dynamicType(json.f), dynamicType(json.t), dynamicType(json.m), dynamicType(json.n)
FROM test_json_shared_data_values WHERE id BETWEEN 10 AND 39 ORDER BY id;

SYSTEM START MERGES test_json_shared_data_values;
OPTIMIZE TABLE test_json_shared_data_values FINAL;

SELECT 'after merge';
SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_json_shared_data_values' AND active;
SELECT arraySort(JSONDynamicPaths(json)) FROM test_json_shared_data_values WHERE id = 10;
SELECT id, json.s, json.i, json.f, json.t, json.m, json.n, json.arr, dynamicType(json.s), dynamicType(json.i), dynamicType(json.f), dynamicType(json.t), dynamicType(json.m), dynamicType(json.n)
FROM test_json_shared_data_values WHERE id BETWEEN 10 AND 39 ORDER BY id;
SELECT sum(length(json.s::String)), sum(json.i::Int64), countIf(json.t::Bool), sum(json.m::Int64) FROM test_json_shared_data_values;

DROP TABLE test_json_shared_data_values;
