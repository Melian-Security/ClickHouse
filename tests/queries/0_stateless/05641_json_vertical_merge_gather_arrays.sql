-- Tags: no-random-settings, no-random-merge-tree-settings
-- Vertical merge of interleaved parts with JSON arrays: a typed Array(Nullable(String)) path and arrays of objects
-- in dynamic paths and in shared data, with different types of the same nested path in different parts.

DROP TABLE IF EXISTS test_json_gather_arrays;
CREATE TABLE test_json_gather_arrays (id UInt64, json JSON(max_dynamic_paths = 8, arr Array(Nullable(String))))
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1,
    vertical_merge_algorithm_min_columns_to_activate = 1, index_granularity = 128;

SYSTEM STOP MERGES test_json_gather_arrays;

INSERT INTO test_json_gather_arrays SELECT number * 3, concat(
    '{"arr":["a', toString(number), '",null],',
    '"objs":[', if(number % 5 = 0, '', concat('{"x":', toString(number), ',"y":"s', toString(number % 7), '"}')), '],',
    '"p', toString(number % 6), '":', toString(number), '}')
FROM numbers(3000);

INSERT INTO test_json_gather_arrays SELECT number * 3 + 1, concat(
    '{"arr":[],',
    '"objs":[{"x":"str', toString(number), '","z":[1,2]},{"y":"t"}],',
    '"q', toString(number % 4), '":[{"k":', toString(number), '}]}')
FROM numbers(3000);

INSERT INTO test_json_gather_arrays SELECT number * 3 + 2, concat(
    '{', if(number % 2 = 0, concat('"arr":["c', toString(number), '"],'), ''),
    '"objs":[{"x":', toString(number), ',"w":{"v":[{"u":"', toString(number % 3), '"}]}}],',
    '"p', toString(number % 6), '":"s', toString(number), '"}')
FROM numbers(3000);

DROP TABLE IF EXISTS test_json_gather_arrays_before;
CREATE TABLE test_json_gather_arrays_before ENGINE = Memory AS SELECT id, toString(json) AS s FROM test_json_gather_arrays;

SYSTEM START MERGES test_json_gather_arrays;
OPTIMIZE TABLE test_json_gather_arrays FINAL;

SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_json_gather_arrays' AND active;
SELECT count(), countIf(b.s = toString(a.json))
FROM test_json_gather_arrays AS a INNER JOIN test_json_gather_arrays_before AS b ON a.id = b.id;
SELECT id, json FROM test_json_gather_arrays WHERE id IN (0, 1, 2, 3, 4, 5, 15, 16, 17) ORDER BY id;
SELECT JSONAllPathsWithTypes(json) FROM test_json_gather_arrays WHERE id IN (0, 1, 2) ORDER BY id;

DROP TABLE test_json_gather_arrays_before;
DROP TABLE test_json_gather_arrays;
