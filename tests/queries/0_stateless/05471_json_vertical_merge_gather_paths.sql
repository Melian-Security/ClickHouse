-- Tags: no-random-settings, no-random-merge-tree-settings
-- Vertical merge of JSON parts whose dynamic paths differ from each other and from the merged part:
-- gathering moves values between dynamic paths and shared data per source part. The data must not change.

DROP TABLE IF EXISTS test_json_gather;
CREATE TABLE test_json_gather (id UInt64, json JSON(max_dynamic_paths = 3, max_dynamic_types = 3, a UInt32))
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1, index_granularity = 128;

SYSTEM STOP MERGES test_json_gather;

-- Rows of the first three parts interleave by id, the fourth part is a contiguous range.
INSERT INTO test_json_gather SELECT number * 3, concat('{"a" : ', toString(number), ', "b" : ', toString(number), ', "c" : "s', toString(number % 7), '"', if(number % 5 = 0, concat(', "x', toString(number % 11), '" : ', toString(number)), ''), '}') FROM numbers(1000);
INSERT INTO test_json_gather SELECT number * 3 + 1, concat('{"a" : ', toString(number), ', "c" : ', if(number % 2, toString(number), concat('"', toString(number), '"')), ', "d" : [', toString(number), '], "e" : ', toString(number % 3 = 0), if(number % 4 = 0, concat(', "y', toString(number % 13), '" : "v"'), ''), '}') FROM numbers(1000);
INSERT INTO test_json_gather SELECT number * 3 + 2, concat('{"a" : ', toString(number), ', "e" : ', toString(number), ', "f" : {"g" : ', toString(number), '}, "b" : ', toString(number * 1.5), if(number % 3 = 0, concat(', "x', toString(number % 11), '" : "z"'), ''), '}') FROM numbers(1000);
INSERT INTO test_json_gather SELECT 3000 + number, concat('{"b" : ', toString(number), ', "d" : "t', toString(number), '", "h" : null, "z', toString(number % 17), '" : ', toString(number), '}') FROM numbers(1000);

SELECT 'before merge';
SELECT count(), sum(cityHash64(toString(json))), sum(cityHash64(id, toString(json))) FROM test_json_gather;
SELECT _part, arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather GROUP BY _part ORDER BY _part;

SYSTEM START MERGES test_json_gather;
OPTIMIZE TABLE test_json_gather FINAL;

SELECT 'after merge';
SELECT count(), sum(cityHash64(toString(json))), sum(cityHash64(id, toString(json))) FROM test_json_gather;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather;
SELECT id, json FROM test_json_gather WHERE id % 97 = 0 ORDER BY id;
SELECT json.b.:Int64, json.b.:Float64, json.c.:String, json.c.:Int64, json.e.:Bool, json.x5, json.y4 FROM test_json_gather WHERE id IN (0, 1, 2, 3, 4, 5, 12, 13, 14, 3000, 3001) ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm FROM system.part_log WHERE database = currentDatabase() AND table = 'test_json_gather' AND event_type = 'MergeParts';

DROP TABLE test_json_gather;
