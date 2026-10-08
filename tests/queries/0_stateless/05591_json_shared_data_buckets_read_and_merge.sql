-- Tags: no-random-settings, no-random-merge-tree-settings
-- JSON shared data stored in buckets is read back the same as shared data stored in one map: whole objects read
-- over several granules, sub-objects selected by a path prefix, and the result of a merge of such parts.

SET enable_json_type = 1;

DROP TABLE IF EXISTS test_buckets;
DROP TABLE IF EXISTS test_map;

CREATE TABLE test_buckets (id UInt64, json JSON(max_dynamic_paths = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 7,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'map_with_buckets',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets', object_shared_data_buckets_for_wide_part = 4,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1;

CREATE TABLE test_map (id UInt64, json JSON(max_dynamic_paths = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 7,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'map',
    object_shared_data_serialization_version_for_zero_level_parts = 'map';

SYSTEM STOP MERGES test_buckets;

INSERT INTO test_buckets SELECT number, toJSONString(map('a' || toString(number % 5), number, 'b.c' || toString(number % 7), repeat('x', number % 11), 'b.d' || toString(number % 3), [number, number + 1])) FROM numbers(200);
INSERT INTO test_buckets SELECT number, toJSONString(map('a' || toString(number % 13), toString(number), 'b.e' || toString(number % 4), number * 2)) FROM numbers(100, 150);
INSERT INTO test_map SELECT * FROM test_buckets;

SELECT 'whole objects';
SELECT count(), sum(cityHash64(toString(json))) = (SELECT sum(cityHash64(toString(json))) FROM test_map) FROM test_buckets;
SELECT id, json FROM test_buckets ORDER BY id, toString(json) LIMIT 5;

SELECT 'sub-objects';
SELECT sum(cityHash64(toString(json.^b))) = (SELECT sum(cityHash64(toString(json.^b))) FROM test_map) FROM test_buckets;
SELECT id, json.^b FROM test_buckets ORDER BY id, toString(json.^b) LIMIT 5;

SELECT 'after merge';
SYSTEM START MERGES test_buckets;
OPTIMIZE TABLE test_buckets FINAL;
SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_buckets' AND active;
SELECT count(), sum(cityHash64(toString(json))) = (SELECT sum(cityHash64(toString(json))) FROM test_map) FROM test_buckets;
SELECT sum(cityHash64(toString(json.^b))) = (SELECT sum(cityHash64(toString(json.^b))) FROM test_map) FROM test_buckets;

DROP TABLE test_buckets;
DROP TABLE test_map;
