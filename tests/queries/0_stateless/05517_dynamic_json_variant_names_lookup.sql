-- Tags: no-random-settings, no-random-merge-tree-settings
-- Values of Dynamic columns move between the regular variants and the shared variant when variants are
-- added before and after the shared variant in name order, inserted row by row, by ranges and in merges,
-- and JSON paths in shared data (with Array(JSON) values) are counted in the statistics of merged parts.

DROP TABLE IF EXISTS test_dynamic;
CREATE TABLE test_dynamic (id UInt64, d Dynamic(max_types = 3)) ENGINE = MergeTree ORDER BY id SETTINGS min_bytes_for_wide_part = 0;
SYSTEM STOP MERGES test_dynamic;
-- Array(Int64) and Int64 sort before SharedVariant, String sorts after it.
INSERT INTO test_dynamic VALUES (1, 42::Int64), (2, 'a'), (3, [1, 2]::Array(Int64));
INSERT INTO test_dynamic VALUES (4, true), (5, 3.5::Float64), (6, toDate('2020-01-01')), (7, 'b');
INSERT INTO test_dynamic VALUES (8, 7::UInt8), (9, [3]::Array(Int64)), (10, [4, 5, 6]::Array(Int64)), (11, 'c');
SELECT 'parts';
SELECT id, d, dynamicType(d), isDynamicElementInSharedData(d) FROM test_dynamic ORDER BY id;
SYSTEM START MERGES test_dynamic;
OPTIMIZE TABLE test_dynamic FINAL;
SELECT 'merged';
SELECT id, d, dynamicType(d), isDynamicElementInSharedData(d) FROM test_dynamic ORDER BY id;

SELECT 'insert select';
DROP TABLE IF EXISTS test_dynamic_dst;
CREATE TABLE test_dynamic_dst (id UInt64, d Dynamic(max_types = 2)) ENGINE = Memory;
INSERT INTO test_dynamic_dst SELECT * FROM test_dynamic ORDER BY id;
INSERT INTO test_dynamic_dst SELECT id + 100, d FROM test_dynamic ORDER BY id DESC;
SELECT id, d, dynamicType(d), isDynamicElementInSharedData(d) FROM test_dynamic_dst ORDER BY id;
DROP TABLE test_dynamic_dst;
DROP TABLE test_dynamic;

SELECT 'json';
DROP TABLE IF EXISTS test_json;
CREATE TABLE test_json (id UInt64, json JSON(max_dynamic_paths = 2, max_dynamic_types = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1;
SYSTEM STOP MERGES test_json;
INSERT INTO test_json SELECT number, format('{{"a" : {}, "b" : "{}", "c{}" : {}, "arr" : [{{"x" : "{}", "y" : "{}"}}]}}', number, number, number % 5, number, number, number * 2) FROM numbers(20);
INSERT INTO test_json SELECT number + 20, format('{{"c{}" : "{}", "d" : {}, "arr" : [{{"x" : {}, "z" : "{}"}}]}}', number % 7, number, number, number, number) FROM numbers(20);
INSERT INTO test_json SELECT 40, '{"a" : [1, 2], "e" : {"f" : true}, "arr" : [{"x" : 1.5, "w" : [{"v" : 1}]}]}';
SYSTEM START MERGES test_json;
OPTIMIZE TABLE test_json FINAL;
SELECT id, json, JSONSharedDataPaths(json), dynamicType(json.arr) FROM test_json ORDER BY id;
SELECT 'dynamic paths', JSONDynamicPaths(json) FROM test_json ORDER BY id LIMIT 1;
DROP TABLE test_json;
