-- Tags: no-random-settings, no-random-merge-tree-settings
-- Vertical merge of JSON parts with interleaved rows: gathering inserts batches of rows path by path and
-- must produce the same data and block boundaries as inserting row by row. Small block limits make many
-- batches end at the limit on block bytes; ReplacingMergeTree adds rows skipped by the merge.

DROP TABLE IF EXISTS test_json_gather_by_path;
CREATE TABLE test_json_gather_by_path
(
    id UInt64,
    json JSON(max_dynamic_paths = 3, max_dynamic_types = 2, a UInt32, l LowCardinality(String), arr Array(JSON(max_dynamic_paths = 1)))
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    index_granularity = 64, merge_max_block_size = 300, merge_max_block_size_bytes = 6000;

SYSTEM STOP MERGES test_json_gather_by_path;

INSERT INTO test_json_gather_by_path SELECT number * 4, concat('{"a" : ', toString(number), ', "l" : "l', toString(number % 3), '", "b" : ', toString(number), ', "c" : "s', toString(number % 7), '"', if(number % 5 = 0, concat(', "x', toString(number % 11), '" : ', toString(number)), ''), '}') FROM numbers(2000);
INSERT INTO test_json_gather_by_path SELECT number * 4 + 1, concat('{"a" : ', toString(number), ', "c" : ', if(number % 2, toString(number), concat('"', toString(number), '"')), ', "d" : [', toString(number), '], "e" : ', toString(number % 3 = 0), ', "arr" : [{"p" : ', toString(number), ', "q" : "', toString(number), '"}]', if(number % 4 = 0, concat(', "y', toString(number % 13), '" : "', repeat('v', number % 300), '"'), ''), '}') FROM numbers(2000);
INSERT INTO test_json_gather_by_path SELECT number * 4 + 2, concat('{"a" : ', toString(number), ', "e" : ', toString(number), ', "f" : {"g" : ', toString(number), '}, "b" : ', toString(number * 1.5), if(number % 3 = 0, concat(', "x', toString(number % 11), '" : "z"'), ''), '}') FROM numbers(2000);
INSERT INTO test_json_gather_by_path SELECT number * 4 + 3, concat('{"b" : "', toString(number), '", "d" : "t', toString(number), '", "c" : null, "z', toString(number % 17), '" : ', toString(number), if(number % 9 = 0, concat(', "w" : "', repeat('w', 2000), '"'), ''), '}') FROM numbers(2000);
INSERT INTO test_json_gather_by_path SELECT 8000 + number, concat('{"b" : ', toString(number), ', "c" : ', toString(number), ', "d" : [', toString(number), ']}') FROM numbers(500);

SELECT 'before merge';
SELECT count(), sum(cityHash64(toString(json))), sum(cityHash64(id, toString(json))) FROM test_json_gather_by_path;
SELECT _part, arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather_by_path GROUP BY _part ORDER BY _part;

SYSTEM START MERGES test_json_gather_by_path;
OPTIMIZE TABLE test_json_gather_by_path FINAL;

SELECT 'after merge';
SELECT count(), sum(cityHash64(toString(json))), sum(cityHash64(id, toString(json))) FROM test_json_gather_by_path;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather_by_path;
SELECT id, json FROM test_json_gather_by_path WHERE id % 397 = 0 ORDER BY id;
SELECT json.b.:Int64, json.b.:String, json.b.:Float64, json.c.:String, json.c.:Int64, json.e.:Bool, json.l, json.arr, length(json.w.:String) FROM test_json_gather_by_path WHERE id IN (0, 1, 2, 3, 4, 5, 39, 8000, 8001) ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm FROM system.part_log WHERE database = currentDatabase() AND table = 'test_json_gather_by_path' AND event_type = 'MergeParts';

DROP TABLE test_json_gather_by_path;

DROP TABLE IF EXISTS test_json_gather_by_path_replacing;
CREATE TABLE test_json_gather_by_path_replacing (id UInt64, version UInt64, json JSON(max_dynamic_paths = 2))
ENGINE = ReplacingMergeTree(version) ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    index_granularity = 64, merge_max_block_size = 200, merge_max_block_size_bytes = 4000;

SYSTEM STOP MERGES test_json_gather_by_path_replacing;

-- Every part has a version of each id, and the latest version of an id is in a different part each time.
INSERT INTO test_json_gather_by_path_replacing SELECT number, (number * 7) % 3, concat('{"k" : ', toString(number), ', "m" : "a', toString(number), '", "n' , toString(number % 5), '" : 0}') FROM numbers(3000);
INSERT INTO test_json_gather_by_path_replacing SELECT number, (number * 7 + 1) % 3, concat('{"k" : "', toString(number), '", "o" : [', toString(number), '], "p' , toString(number % 6), '" : 1}') FROM numbers(3000);
INSERT INTO test_json_gather_by_path_replacing SELECT number, (number * 7 + 2) % 3, concat('{"m" : ', toString(number), ', "q" : {"r" : ', toString(number), '}, "s' , toString(number % 7), '" : 2}') FROM numbers(3000);

SYSTEM START MERGES test_json_gather_by_path_replacing;
OPTIMIZE TABLE test_json_gather_by_path_replacing FINAL;

SELECT 'replacing after merge';
SELECT count(), sum(cityHash64(id, version, toString(json))) FROM test_json_gather_by_path_replacing;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather_by_path_replacing;
SELECT id, version, json FROM test_json_gather_by_path_replacing WHERE id % 499 = 0 ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm FROM system.part_log WHERE database = currentDatabase() AND table = 'test_json_gather_by_path_replacing' AND event_type = 'MergeParts';

DROP TABLE test_json_gather_by_path_replacing;
