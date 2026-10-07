-- Tags: no-random-settings, no-random-merge-tree-settings
-- Parts with different dynamic paths are merged, so values move between dynamic paths and shared data while
-- the rest of the shared data of each row is copied. Zero-level parts are written with buckets.

DROP TABLE IF EXISTS test_json_copy_runs;
DROP TABLE IF EXISTS test_json_copy_runs_dst;

CREATE TABLE test_json_copy_runs (id UInt64, json JSON(max_dynamic_paths = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 128,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets', object_shared_data_buckets_for_wide_part = 4;

SYSTEM STOP MERGES test_json_copy_runs;

-- Dynamic paths a and b, the other paths in shared data. b is sometimes NULL and c is sometimes absent.
INSERT INTO test_json_copy_runs SELECT number * 3, concat('{"a":', toString(number), if(number % 4 = 0, ',"b":null', concat(',"b":"s', toString(number), '"')), if(number % 3 = 0, '', concat(',"c":', toString(number))), ',"d":[', toString(number), ',1],"e":{"x":', toString(number % 5), '},"k', toString(number % 7), '":"v"}') FROM numbers(3000);
-- Dynamic paths c and d, a and b in shared data with a new path f.
INSERT INTO test_json_copy_runs SELECT number * 3 + 1, concat('{', if(number % 5 = 0, concat('"a":', toString(number), ','), ''), if(number % 2 = 0, '"b":true,', ''), '"c":"t', toString(number), '","d":', toString(number), ',"f":', toString(number * 1.5), '}') FROM numbers(3000);
-- Dynamic paths f and g, rows without shared data in between.
INSERT INTO test_json_copy_runs SELECT number * 3 + 2, concat('{"f":', toString(number), ',"g":"w', toString(number), '"', if(number % 10 < 3, concat(',"a":[', toString(number), '],"z":{"y":', toString(number), '}'), ''), '}') FROM numbers(3000);

SELECT 'zero-level parts';
SELECT count(), sum(cityHash64(toString(json))) FROM test_json_copy_runs;
SELECT id, json FROM test_json_copy_runs WHERE id < 12 OR id BETWEEN 5994 AND 6003 ORDER BY id;

SELECT 'insert select';
CREATE TABLE test_json_copy_runs_dst AS test_json_copy_runs;
INSERT INTO test_json_copy_runs_dst SELECT * FROM test_json_copy_runs ORDER BY id SETTINGS max_block_size = 1000, max_threads = 1;
SELECT count(), sum(cityHash64(toString(json))) FROM test_json_copy_runs_dst;
SELECT JSONDynamicPaths(json) AS paths, count() FROM test_json_copy_runs_dst GROUP BY paths ORDER BY paths;

SELECT 'merged';
SYSTEM START MERGES test_json_copy_runs;
OPTIMIZE TABLE test_json_copy_runs FINAL;
SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_json_copy_runs' AND active;
SELECT count(), sum(cityHash64(toString(json))) FROM test_json_copy_runs;
SELECT JSONDynamicPaths(json) AS paths, count() FROM test_json_copy_runs GROUP BY paths ORDER BY paths;
SELECT JSONSharedDataPaths(json) AS paths, count() FROM test_json_copy_runs GROUP BY paths ORDER BY count() DESC, paths LIMIT 10;
SELECT id, json FROM test_json_copy_runs WHERE id < 12 OR id BETWEEN 5994 AND 6003 ORDER BY id;
SELECT id, json.a, json.b, json.c, json.k3, json.z.y FROM test_json_copy_runs WHERE id % 97 = 0 ORDER BY id LIMIT 20;

DROP TABLE test_json_copy_runs;
DROP TABLE test_json_copy_runs_dst;
