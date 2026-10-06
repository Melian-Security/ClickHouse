-- Tags: no-random-settings, no-random-merge-tree-settings
-- The statistics written into wide parts (sizes of Dynamic variants, non-null counts of JSON paths in shared data)
-- decide which types stay variants and which paths stay dynamic when parts are merged again.

SET enable_json_type = 1, enable_dynamic_type = 1;

DROP TABLE IF EXISTS test_json_stats;
CREATE TABLE test_json_stats (id UInt64, json JSON(max_dynamic_paths = 2), d Dynamic(max_types = 2))
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 16,
    object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets', dynamic_serialization_version = 'v3';

SYSTEM STOP MERGES test_json_stats;

-- Paths a and b come first, so the first parts keep them as dynamic paths; c, e and f go to shared data.
INSERT INTO test_json_stats SELECT number, toJSONString(map('a', number, 'b', number, 'c', number)), number FROM numbers(10);
INSERT INTO test_json_stats SELECT number + 10, toJSONString(map('a', number, 'b', number, 'c', number, 'e', number)), toString(number) FROM numbers(40);
INSERT INTO test_json_stats SELECT number + 50, '{"c" : 1, "e" : 2, "f" : 3}', toDate(number) FROM numbers(100);

SELECT 'parts', count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_json_stats' AND active;
SYSTEM START MERGES test_json_stats;
OPTIMIZE TABLE test_json_stats FINAL;

SELECT 'first merge';
SELECT 'dynamic paths', arraySort(groupUniqArrayArray(JSONDynamicPaths(json))) FROM test_json_stats;
SELECT 'shared data paths', arraySort(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_stats;
SELECT 'types', dynamicType(d) AS t, isDynamicElementInSharedData(d) AS shared, count() FROM test_json_stats GROUP BY t, shared ORDER BY t, shared;

-- A second merge reads the statistics written by the first one.
SYSTEM STOP MERGES test_json_stats;
INSERT INTO test_json_stats SELECT number + 150, '{"a" : 1, "f" : 2}', number::Float64 FROM numbers(5);
SYSTEM START MERGES test_json_stats;
OPTIMIZE TABLE test_json_stats FINAL;

SELECT 'second merge';
SELECT 'dynamic paths', arraySort(groupUniqArrayArray(JSONDynamicPaths(json))) FROM test_json_stats;
SELECT 'shared data paths', arraySort(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_stats;
SELECT 'types', dynamicType(d) AS t, isDynamicElementInSharedData(d) AS shared, count() FROM test_json_stats GROUP BY t, shared ORDER BY t, shared;
SELECT 'rows', count(), sum(json.c::Nullable(Int64)), sum(json.e::Nullable(Int64)), sum(json.f::Nullable(Int64)) FROM test_json_stats;

DROP TABLE test_json_stats;
