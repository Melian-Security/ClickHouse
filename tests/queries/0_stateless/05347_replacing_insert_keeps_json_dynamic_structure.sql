-- Tags: no-random-merge-tree-settings
-- The insert-time merge of a ReplacingMergeTree block keeps the dynamic structure the
-- block was parsed with, and a later merge still re-selects the paths from statistics.

SET optimize_on_insert = 1;
SET max_insert_block_size = 1000000, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;
SET insert_deduplicate = 0;

DROP TABLE IF EXISTS t_replacing_json_uniq;
DROP TABLE IF EXISTS t_replacing_json_dup;

CREATE TABLE t_replacing_json_uniq (id UInt64, j JSON(max_dynamic_paths = 4)) ENGINE = ReplacingMergeTree ORDER BY id;
CREATE TABLE t_replacing_json_dup (id UInt64, j JSON(max_dynamic_paths = 4)) ENGINE = ReplacingMergeTree ORDER BY id;

-- Rows 0..3 carry one rare path each, so the parser makes rare_0..rare_3 the dynamic paths;
-- the other rows carry frequent paths f0..f5 (with arrays of objects) that go to shared data.
-- Unique keys: the merge keeps every row.
INSERT INTO t_replacing_json_uniq
SELECT number,
    if(number < 4,
        concat('{"rare_', toString(number), '": ', toString(number), '}'),
        concat('{', arrayStringConcat(arrayMap(k -> concat('"f', toString(k), '": [{"a": ', toString(number % 7), ', "b": "x', toString(number % 3), '"}]'), range(6)), ', '), '}'))
FROM numbers(40);

-- Keys 4..13 repeat: the merge drops rows and keeps the last row of each key.
INSERT INTO t_replacing_json_dup
SELECT if(number < 4, number, 4 + number % 10),
    if(number < 4,
        concat('{"rare_', toString(number), '": ', toString(number), '}'),
        concat('{', arrayStringConcat(arrayMap(k -> concat('"f', toString(k), '": [{"a": ', toString(number), ', "b": "x', toString(number % 3), '"}]'), range(6)), ', '), '}'))
FROM numbers(40);

SELECT 'uniq', count(), arraySort(groupUniqArrayArray(JSONDynamicPaths(j))), arraySort(groupUniqArrayArray(JSONSharedDataPaths(j))) FROM t_replacing_json_uniq;
SELECT 'dup', count(), arraySort(groupUniqArrayArray(JSONDynamicPaths(j))), arraySort(groupUniqArrayArray(JSONSharedDataPaths(j))) FROM t_replacing_json_dup;
SELECT id, j FROM t_replacing_json_dup WHERE id IN (2, 4, 13) ORDER BY id;
SELECT id, j.f0, j.rare_1 FROM t_replacing_json_uniq WHERE id IN (1, 5) ORDER BY id;

-- A background merge still chooses the most frequent paths.
OPTIMIZE TABLE t_replacing_json_uniq FINAL;
OPTIMIZE TABLE t_replacing_json_dup FINAL;
SELECT 'uniq merged', count(), arraySort(groupUniqArrayArray(JSONDynamicPaths(j))) FROM t_replacing_json_uniq;
SELECT 'dup merged', count(), arraySort(groupUniqArrayArray(JSONDynamicPaths(j))) FROM t_replacing_json_dup;
SELECT id, j FROM t_replacing_json_dup WHERE id IN (2, 4, 13) ORDER BY id;

DROP TABLE t_replacing_json_uniq;
DROP TABLE t_replacing_json_dup;
