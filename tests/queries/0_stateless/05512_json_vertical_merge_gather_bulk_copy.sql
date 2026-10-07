-- Tags: no-random-settings, no-random-merge-tree-settings
-- Vertical merge of JSON parts with interleaved rows: the ranges of a gathered batch are copied into typed paths
-- of strings, fixed-size values and Nullable together, and single values and defaults of dynamic paths are
-- copied into their Variant columns together. Every row must keep its values and types.

DROP TABLE IF EXISTS test_json_gather_bulk_copy;
CREATE TABLE test_json_gather_bulk_copy
(
    id UInt64,
    json JSON(max_dynamic_paths = 4, max_dynamic_types = 3,
        s String, n Nullable(String), i8 Int8, i16 Int16, f32 Float32, u UUID, fs FixedString(4), fs3 FixedString(3),
        d Decimal(18, 3), ni Nullable(Int64), ls LowCardinality(String))
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    index_granularity = 64, merge_max_block_size = 500, merge_max_block_size_bytes = 30000;

SYSTEM STOP MERGES test_json_gather_bulk_copy;

-- Typed paths in every part, some of them missing in some rows. Dynamic path p is Int64 or NULL everywhere,
-- q is a String in one part and an Int64 in another, r has two types, t exists in one part only, and paths x*
-- go to shared data.
INSERT INTO test_json_gather_bulk_copy SELECT number * 3, concat('{"s" : "s', toString(number), '", "n" : ', if(number % 4 = 0, 'null', concat('"n', repeat('x', number % 20), '"')),
    ', "i8" : ', toString(number % 100), ', "i16" : ', toString(number % 30000), ', "f32" : ', toString(number / 4),
    ', "u" : "00000000-0000-0000-0000-', leftPad(toString(number), 12, '0'), '", "fs" : "f', toString(number % 1000), '", "fs3" : "', toString(number % 1000),
    '", "d" : ', toString(number / 8), ', "ni" : ', if(number % 3 = 0, 'null', toString(number)), ', "ls" : "l', toString(number % 5), '"',
    ', "p" : ', if(number % 5 = 0, 'null', toString(number)), ', "q" : "q', toString(number), '"', ', "r" : ', if(number % 2, toString(number), concat('"r', toString(number), '"')),
    ', "x', toString(number % 10), '" : ', toString(number), '}') FROM numbers(3000);
INSERT INTO test_json_gather_bulk_copy SELECT number * 3 + 1, concat('{', if(number % 7 = 0, '', concat('"s" : "', repeat('a', number % 50), '", ')), '"n" : "m', toString(number), '"',
    if(number % 6 = 0, '', concat(', "i8" : -', toString(number % 100), ', "i16" : -', toString(number % 30000), ', "f32" : -', toString(number / 8))),
    ', "d" : -', toString(number / 16), ', "ni" : ', toString(number), ', "p" : ', if(number % 3 = 0, 'null', toString(number * 2)),
    ', "q" : ', toString(number), ', "r" : ', if(number % 3, toString(number), concat('"', toString(number), '"')),
    if(number % 4 = 0, concat(', "x', toString(number % 13), '" : "v', toString(number), '"'), ''), '}') FROM numbers(3000);
INSERT INTO test_json_gather_bulk_copy SELECT number * 3 + 2, concat('{"s" : "t', toString(number), '", "u" : "00000000-0000-0000-0001-', leftPad(toString(number), 12, '0'),
    '", "fs" : "', toString(number % 10000), '", "fs3" : "z", "p" : ', toString(number), ', "t" : ', if(number % 2, '[1, 2]', toString(number)),
    if(number % 8 = 0, ', "q" : null', ''), '}') FROM numbers(3000);
-- Rows after all others, copied as long ranges.
INSERT INTO test_json_gather_bulk_copy SELECT 100000 + number, concat('{"s" : "e', toString(number), '", "n" : null, "i8" : 1, "p" : ', toString(number), ', "r" : "e"}') FROM numbers(1000);

SELECT 'before merge';
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_gather_bulk_copy;
SELECT sum(cityHash64(id, dynamicType(json.p), dynamicType(json.q), dynamicType(json.r), dynamicType(json.t))) FROM test_json_gather_bulk_copy;

SYSTEM START MERGES test_json_gather_bulk_copy;
OPTIMIZE TABLE test_json_gather_bulk_copy FINAL;

SELECT 'after merge';
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_gather_bulk_copy;
SELECT sum(cityHash64(id, dynamicType(json.p), dynamicType(json.q), dynamicType(json.r), dynamicType(json.t))) FROM test_json_gather_bulk_copy;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), length(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather_bulk_copy;
SELECT id, json FROM test_json_gather_bulk_copy WHERE id IN (0, 1, 2, 3, 4, 5, 15, 16, 17, 100000, 100999) ORDER BY id;
SELECT id, json.n, json.ni, json.u, json.fs, json.fs3, json.p, dynamicType(json.q), dynamicType(json.r) FROM test_json_gather_bulk_copy WHERE id IN (0, 1, 2, 12, 13, 14) ORDER BY id;

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm FROM system.part_log WHERE database = currentDatabase() AND table = 'test_json_gather_bulk_copy' AND event_type = 'MergeParts';

DROP TABLE test_json_gather_bulk_copy;
