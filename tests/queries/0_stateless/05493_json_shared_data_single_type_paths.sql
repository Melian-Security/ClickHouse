-- Paths of the advanced shared data serialization that hold values of a single type in a chunk are written
-- from the stored value bytes. Check that every such type, absent rows, mixed types, nested types and long
-- values read back the same as from the map serialization.

SET max_threads = 1;

DROP TABLE IF EXISTS src;
DROP TABLE IF EXISTS test_map;
DROP TABLE IF EXISTS test_wide;
DROP TABLE IF EXISTS test_wide_chunked;
DROP TABLE IF EXISTS test_compact_chunked;
DROP TABLE IF EXISTS test_single_stream;
DROP TABLE IF EXISTS test_no_types;

CREATE TABLE src (id UInt64, json String) ENGINE = Memory;
INSERT INTO src SELECT number, concat('{',
    '"dyn":', toString(number), ',',
    '"s":"', repeat('x', number % 7), '",',
    if(number % 3 = 0, concat('"i":', toString(number * 1000003 - 500000000), ','), ''),
    if(number % 4 = 0, concat('"u":1844674407370955', toString(1000 + number % 1000), ','), ''),
    if(number % 5 = 0, concat('"f":', toString(number / 7 + 0.5), ','), ''),
    if(number % 2 = 0, concat('"b":', if(number % 6 = 0, 'true', 'false'), ','), ''),
    if(number % 11 = 0, '"e":"",', ''),
    if(number % 13 = 0, concat('"long":"', repeat('y', 200 + number % 300), '",'), ''),
    if(number % 2 = 0, concat('"mixed":', toString(number), ','), concat('"mixed":"v', toString(number), '",')),
    if(number % 9 = 0, concat('"arr":[', toString(number), ',null],'), ''),
    if(number % 10 = 0, concat('"obj":[{"k":', toString(number), '}],'), ''),
    if(number = 4999, '"rare":1,', ''),
    '"last":null}')
FROM numbers(5000);

CREATE TABLE test_map (id UInt64, json JSON(max_dynamic_paths = 1)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, object_serialization_version = 'v3', object_shared_data_serialization_version = 'map',
    object_shared_data_serialization_version_for_zero_level_parts = 'map';

CREATE TABLE test_wide (id UInt64, json JSON(max_dynamic_paths = 1)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced', object_shared_data_buckets_for_wide_part = 2, index_granularity = 1000;

CREATE TABLE test_wide_chunked (id UInt64, json JSON(max_dynamic_paths = 1)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced_chunked',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced_chunked', object_shared_data_target_chunk_rows = 300, index_granularity = 1000;

CREATE TABLE test_compact_chunked (id UInt64, json JSON(max_dynamic_paths = 1)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = '1G', object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced_chunked',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced_chunked', object_shared_data_target_chunk_rows = 300, index_granularity = 1000;

CREATE TABLE test_single_stream (id UInt64, json JSON(max_dynamic_paths = 1)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced', string_serialization_version = 'single_stream';

CREATE TABLE test_no_types (id UInt64, json JSON(max_dynamic_paths = 1, max_dynamic_types = 0)) ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, object_serialization_version = 'v3', object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced';

INSERT INTO test_map SELECT id, json FROM src;
INSERT INTO test_wide SELECT id, json FROM src;
INSERT INTO test_wide_chunked SELECT id, json FROM src;
INSERT INTO test_compact_chunked SELECT id, json FROM src;
INSERT INTO test_single_stream SELECT id, json FROM src;
INSERT INTO test_no_types SELECT id, json FROM src;

-- A second part of each table, then a merge, so the merged part is written from shared data read back.
INSERT INTO test_map SELECT id + 5000, json FROM src;
INSERT INTO test_wide SELECT id + 5000, json FROM src;
INSERT INTO test_wide_chunked SELECT id + 5000, json FROM src;
INSERT INTO test_compact_chunked SELECT id + 5000, json FROM src;
INSERT INTO test_single_stream SELECT id + 5000, json FROM src;
INSERT INTO test_no_types SELECT id + 5000, json FROM src;

OPTIMIZE TABLE test_map FINAL;
OPTIMIZE TABLE test_wide FINAL;
OPTIMIZE TABLE test_wide_chunked FINAL;
OPTIMIZE TABLE test_compact_chunked FINAL;
OPTIMIZE TABLE test_single_stream FINAL;
OPTIMIZE TABLE test_no_types FINAL;

SELECT 'types';
SELECT arrayJoin(JSONAllPathsWithTypes(json)) AS path_type, count() FROM test_wide GROUP BY path_type ORDER BY path_type;

SELECT 'whole rows';
SELECT 'test_map', count(), groupBitXor(cityHash64(id, toString(json))) FROM test_map;
SELECT 'test_wide', count(), groupBitXor(cityHash64(id, toString(json))) FROM test_wide;
SELECT 'test_wide_chunked', count(), groupBitXor(cityHash64(id, toString(json))) FROM test_wide_chunked;
SELECT 'test_compact_chunked', count(), groupBitXor(cityHash64(id, toString(json))) FROM test_compact_chunked;
SELECT 'test_single_stream', count(), groupBitXor(cityHash64(id, toString(json))) FROM test_single_stream;
SELECT 'test_no_types', count(), groupBitXor(cityHash64(id, toString(json))) FROM test_no_types;

SELECT 'paths';
SELECT sum(cityHash64(toString(json.s), toString(json.i), toString(json.u), toString(json.f), toString(json.b), toString(json.e), toString(json.long), toString(json.mixed), toString(json.arr), toString(json.obj), toString(json.rare))) FROM test_map;
SELECT sum(cityHash64(toString(json.s), toString(json.i), toString(json.u), toString(json.f), toString(json.b), toString(json.e), toString(json.long), toString(json.mixed), toString(json.arr), toString(json.obj), toString(json.rare))) FROM test_wide;
SELECT sum(cityHash64(toString(json.s), toString(json.i), toString(json.u), toString(json.f), toString(json.b), toString(json.e), toString(json.long), toString(json.mixed), toString(json.arr), toString(json.obj), toString(json.rare))) FROM test_wide_chunked;
SELECT sum(cityHash64(toString(json.s), toString(json.i), toString(json.u), toString(json.f), toString(json.b), toString(json.e), toString(json.long), toString(json.mixed), toString(json.arr), toString(json.obj), toString(json.rare))) FROM test_compact_chunked;
SELECT sum(cityHash64(toString(json.s), toString(json.i), toString(json.u), toString(json.f), toString(json.b), toString(json.e), toString(json.long), toString(json.mixed), toString(json.arr), toString(json.obj), toString(json.rare))) FROM test_single_stream;
SELECT sum(cityHash64(toString(json.s), toString(json.i), toString(json.u), toString(json.f), toString(json.b), toString(json.e), toString(json.long), toString(json.mixed), toString(json.arr), toString(json.obj), toString(json.rare))) FROM test_no_types;

SELECT 'typed subcolumns';
SELECT count(), sum(json.i.:Int64), sum(json.u.:UInt64), round(sum(json.f.:Float64), 3), countIf(json.b.:Bool), sum(length(json.s.:String)), sum(length(json.long.:String)) FROM test_wide;
SELECT count(), sum(json.i.:Int64), sum(json.u.:UInt64), round(sum(json.f.:Float64), 3), countIf(json.b.:Bool), sum(length(json.s.:String)), sum(length(json.long.:String)) FROM test_wide_chunked;
SELECT count(), sum(json.i.:Int64), sum(json.u.:UInt64), round(sum(json.f.:Float64), 3), countIf(json.b.:Bool), sum(length(json.s.:String)), sum(length(json.long.:String)) FROM test_compact_chunked;

DROP TABLE src;
DROP TABLE test_map;
DROP TABLE test_wide;
DROP TABLE test_wide_chunked;
DROP TABLE test_compact_chunked;
DROP TABLE test_single_stream;
DROP TABLE test_no_types;
