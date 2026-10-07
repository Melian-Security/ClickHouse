-- Tags: no-random-settings, no-random-merge-tree-settings
-- Vertical merge of JSON parts whose rows interleave both one by one and in runs of several rows: the runs and single
-- values of dynamic paths, NULLs and defaults are copied into their Variant columns together, values of Array(JSON)
-- in shared data are read back with their types, and Variant discriminators are written a block at a time in the
-- compact and the basic modes. Every row must keep its values and types.

DROP TABLE IF EXISTS test_json_variant_ranges;
DROP TABLE IF EXISTS test_json_variant_ranges_basic;

CREATE TABLE test_json_variant_ranges
(
    id UInt64,
    json JSON(max_dynamic_paths = 4, max_dynamic_types = 3, s String)
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    index_granularity = 64, merge_max_block_size = 700, merge_max_block_size_bytes = 50000;

CREATE TABLE test_json_variant_ranges_basic AS test_json_variant_ranges
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    index_granularity = 64, merge_max_block_size = 700, merge_max_block_size_bytes = 50000, use_compact_variant_discriminators_serialization = 0;

SYSTEM STOP MERGES test_json_variant_ranges;
SYSTEM STOP MERGES test_json_variant_ranges_basic;

-- Part 1 has ids 0, 10, 20, ...; part 2 has runs of 1 to 9 consecutive ids between them; part 3 has ids 100000+ after
-- all others. Path a is Int64, String or NULL, b has a different type in each part, c is an array of objects or a
-- Bool, d gets a third type in part 2 only, and paths x*, y* and z go to shared data, z as an array of objects.
INSERT INTO test_json_variant_ranges SELECT number * 10, concat('{"s" : "s', toString(number), '"',
    ', "a" : ', multiIf(number % 5 = 0, 'null', number % 2 = 0, toString(number), concat('"a', toString(number), '"')),
    ', "b" : ', toString(number),
    ', "c" : ', if(number % 3 = 0, concat('[{"k" : ', toString(number), ', "v" : "w', toString(number), '"}]'), 'true'),
    ', "d" : ', toString(number / 4),
    ', "x', toString(number % 7), '" : ', toString(number),
    if(number % 4 = 0, concat(', "z" : [{"m" : ', toString(number), ', "f" : ', toString(number / 8), ', "t" : true, "n" : "q', toString(number), '"}]'), ''),
    '}') FROM numbers(2000);
INSERT INTO test_json_variant_ranges SELECT intDiv(number, 9) * 10 + 1 + number % 9, concat('{"s" : "', repeat('r', number % 40), '"',
    if(intDiv(number, 9) % 3 = 0, '', concat(', "a" : ', if(number % 4 = 0, 'null', toString(number)))),
    ', "b" : "b', toString(number), '"',
    if(number % 11 = 0, '', concat(', "c" : ', if(number % 2 = 0, 'false', concat('[{"k" : ', toString(number), '}]')))),
    ', "d" : ', multiIf(number % 3 = 0, toString(number), number % 3 = 1, concat('"d', toString(number), '"'), '[1, 2, 3]'),
    if(number % 5 = 0, concat(', "y', toString(number % 3), '" : "v', toString(number), '"'), ''),
    if(number % 6 = 0, concat(', "z" : [{"m" : "', toString(number), '", "u" : ', toString(number), '}, {"t" : false}]'), ''),
    '}') FROM numbers(18000) WHERE number % 9 <= intDiv(number, 9) % 9;
INSERT INTO test_json_variant_ranges SELECT 100000 + number, concat('{"s" : "e', toString(number), '", "a" : ', toString(number),
    ', "b" : [', toString(number), '], "d" : null, "z" : [{"m" : 1.5}]}') FROM numbers(1500);

INSERT INTO test_json_variant_ranges_basic SELECT * FROM test_json_variant_ranges WHERE id % 10 = 0 OR id >= 100000;
INSERT INTO test_json_variant_ranges_basic SELECT * FROM test_json_variant_ranges WHERE id % 10 != 0 AND id < 100000;

SELECT 'before merge';
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_variant_ranges;
SELECT sum(cityHash64(id, dynamicType(json.a), dynamicType(json.b), dynamicType(json.c), dynamicType(json.d), toString(json.z))) FROM test_json_variant_ranges;
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_variant_ranges_basic;

SYSTEM START MERGES test_json_variant_ranges;
SYSTEM START MERGES test_json_variant_ranges_basic;
OPTIMIZE TABLE test_json_variant_ranges FINAL;
OPTIMIZE TABLE test_json_variant_ranges_basic FINAL;

SELECT 'after merge';
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_variant_ranges;
SELECT sum(cityHash64(id, dynamicType(json.a), dynamicType(json.b), dynamicType(json.c), dynamicType(json.d), toString(json.z))) FROM test_json_variant_ranges;
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_variant_ranges_basic;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), arraySort(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_variant_ranges;
SELECT id, json FROM test_json_variant_ranges WHERE id IN (0, 1, 2, 9, 10, 11, 30, 31, 39, 60, 100000, 101499) ORDER BY id;
SELECT id, dynamicType(json.a), dynamicType(json.b), dynamicType(json.c), dynamicType(json.d), json.z.:`Array(JSON)` FROM test_json_variant_ranges WHERE id IN (0, 1, 2, 3, 40, 41, 100001) ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT table, merge_algorithm FROM system.part_log WHERE database = currentDatabase() AND table LIKE 'test_json_variant_ranges%' AND event_type = 'MergeParts' ORDER BY table;

DROP TABLE test_json_variant_ranges;
DROP TABLE test_json_variant_ranges_basic;
