-- Tags: no-random-settings, no-random-merge-tree-settings
-- Variant, Dynamic and JSON columns read back from Wide and Compact parts over several granules (rows of several
-- variants, of one variant and NULLs, and of NULLs only), alone and together with their subcolumns, and after a
-- Vertical merge, are the values that were inserted.

SET enable_variant_type = 1, enable_dynamic_type = 1, enable_json_type = 1;

DROP TABLE IF EXISTS src;
DROP TABLE IF EXISTS test_wide;
DROP TABLE IF EXISTS test_compact;

CREATE TABLE src
(
    id UInt64,
    v Variant(UInt64, String, Array(UInt64)),
    v_one Variant(UInt64, String),
    v_null Variant(UInt64, String),
    d Dynamic,
    j JSON(max_dynamic_paths = 2, a UInt32)
) ENGINE = Memory;

INSERT INTO src SELECT
    number,
    multiIf(number % 4 = 0, NULL, number % 4 = 1, CAST(number AS Variant(UInt64, String, Array(UInt64))),
        number % 4 = 2, CAST(toString(number) AS Variant(UInt64, String, Array(UInt64))), CAST([number, 1] AS Variant(UInt64, String, Array(UInt64)))),
    if(number % 3 = 0, NULL, CAST(number AS Variant(UInt64, String))),
    if(number < 300, NULL, CAST(toString(number) AS Variant(UInt64, String))),
    multiIf(number % 3 = 0, NULL, number % 3 = 1, number::Dynamic, toString(number)::Dynamic),
    toJSONString(map('a', toString(number), 'b' || toString(number % 5), toString(number * 2)))
FROM numbers(1000);

CREATE TABLE test_wide AS src ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 7,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1;

CREATE TABLE test_compact AS src ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = '10G', min_rows_for_wide_part = 1000000000, index_granularity = 7;

SYSTEM STOP MERGES test_wide;
SYSTEM STOP MERGES test_compact;

INSERT INTO test_wide SELECT * FROM src WHERE id < 400;
INSERT INTO test_wide SELECT * FROM src WHERE id >= 400 AND id < 700;
INSERT INTO test_wide SELECT * FROM src WHERE id >= 700;
INSERT INTO test_compact SELECT * FROM test_wide;

SELECT table, groupUniqArray(part_type) FROM system.parts WHERE database = currentDatabase() AND table LIKE 'test_%' AND active GROUP BY table ORDER BY table;

SELECT 'columns';
SELECT sum(cityHash64(id, toString(v), toString(v_one), toString(v_null), toString(d), toString(j))) FROM src;
SELECT sum(cityHash64(id, toString(v), toString(v_one), toString(v_null), toString(d), toString(j))) FROM test_wide SETTINGS max_block_size = 100;
SELECT sum(cityHash64(id, toString(v), toString(v_one), toString(v_null), toString(d), toString(j))) FROM test_compact SETTINGS max_block_size = 100;

SELECT 'columns with subcolumns';
SELECT sum(cityHash64(id, toString(v), toString(v.UInt64), toString(v.`Array(UInt64)`.size0), toString(v_one.UInt64), toString(d), toString(d.UInt64), toString(j), toString(j.a), toString(j.b1))) FROM src;
SELECT sum(cityHash64(id, toString(v), toString(v.UInt64), toString(v.`Array(UInt64)`.size0), toString(v_one.UInt64), toString(d), toString(d.UInt64), toString(j), toString(j.a), toString(j.b1))) FROM test_wide SETTINGS max_block_size = 100;
SELECT sum(cityHash64(id, toString(v), toString(v.UInt64), toString(v.`Array(UInt64)`.size0), toString(v_one.UInt64), toString(d), toString(d.UInt64), toString(j), toString(j.a), toString(j.b1))) FROM test_compact SETTINGS max_block_size = 100;

SELECT 'ranges';
SELECT id, v, v_one, v_null, d, j FROM test_wide WHERE id % 97 < 3 ORDER BY id;
SELECT sum(cityHash64(id, toString(v), toString(v_one), toString(d), toString(j))) = (SELECT sum(cityHash64(id, toString(v), toString(v_one), toString(d), toString(j))) FROM src WHERE id % 50 < 20)
FROM test_compact WHERE id % 50 < 20;

SELECT 'after merge';
SYSTEM START MERGES test_wide;
OPTIMIZE TABLE test_wide FINAL;
SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_wide' AND active;
SELECT sum(cityHash64(id, toString(v), toString(v_one), toString(v_null), toString(d), toString(j))) FROM test_wide;
SELECT sum(cityHash64(id, toString(v), toString(v.UInt64), toString(v_one.UInt64), toString(d.UInt64), toString(j.a), toString(j.b1))) = (SELECT sum(cityHash64(id, toString(v), toString(v.UInt64), toString(v_one.UInt64), toString(d.UInt64), toString(j.a), toString(j.b1))) FROM src)
FROM test_wide;

DROP TABLE src;
DROP TABLE test_wide;
DROP TABLE test_compact;
