-- Writing JSON shared data in the advanced serializations: paths whose type changes from row to row,
-- NULLs, values kept in the shared variant of Dynamic, and nested objects, in wide and compact parts.

SET enable_json_type = 1;

DROP TABLE IF EXISTS test_shared_data_wide;
DROP TABLE IF EXISTS test_shared_data_wide_chunked;
DROP TABLE IF EXISTS test_shared_data_compact_chunked;

CREATE TABLE test_shared_data_wide (id UInt64, json JSON(max_dynamic_paths = 2, max_dynamic_types = 2))
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, index_granularity = 100, object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced', object_shared_data_serialization_version_for_zero_level_parts = 'advanced',
    object_shared_data_buckets_for_wide_part = 4;

CREATE TABLE test_shared_data_wide_chunked AS test_shared_data_wide;
ALTER TABLE test_shared_data_wide_chunked MODIFY SETTING object_shared_data_serialization_version = 'advanced_chunked',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced_chunked', object_shared_data_target_chunk_rows = 30;

CREATE TABLE test_shared_data_compact_chunked AS test_shared_data_wide;
ALTER TABLE test_shared_data_compact_chunked MODIFY SETTING min_bytes_for_wide_part = '1G', min_rows_for_wide_part = 1000000000,
    object_shared_data_serialization_version = 'advanced_chunked', object_shared_data_serialization_version_for_zero_level_parts = 'advanced_chunked',
    object_shared_data_target_chunk_rows = 30, object_shared_data_buckets_for_compact_part = 3;

-- `b` changes its type every row, `d` has more types than max_dynamic_types, `p*` are sparse paths.
INSERT INTO test_shared_data_wide SELECT number, concat(
    '{"a":', toString(number),
    ',"b":', multiIf(number % 5 = 0, toString(number), number % 5 = 1, concat('"s', toString(number), '"'), number % 5 = 2, concat('[', toString(number), ',1]'), number % 5 = 3, 'null', toString(number / 8)),
    ',"c":[{"x":', toString(number % 3), ',"y":"', toString(number), '"}]',
    ',"d":', multiIf(number % 4 = 0, 'true', number % 4 = 1, toString(number), number % 4 = 2, concat('"v', toString(number), '"'), concat('["', toString(number), '"]')),
    ',"p', toString(number % 37), '":', if(number % 2 = 0, toString(number), concat('"', toString(number), '"')),
    '}') FROM numbers(1500);
INSERT INTO test_shared_data_wide SELECT number, concat(
    '{"b":', if(number % 3 = 0, 'null', toString(number)),
    ',"d":', if(number % 2 = 0, concat('{"k":', toString(number), '}'), toString(number)),
    ',"q', toString(number % 11), '":"', toString(number), '"}') FROM numbers(1500, 1500);

INSERT INTO test_shared_data_wide_chunked SELECT * FROM test_shared_data_wide;
INSERT INTO test_shared_data_compact_chunked SELECT * FROM test_shared_data_wide;
INSERT INTO test_shared_data_wide_chunked SELECT * FROM test_shared_data_wide WHERE id % 3 = 0;
INSERT INTO test_shared_data_compact_chunked SELECT * FROM test_shared_data_wide WHERE id % 3 = 0;

OPTIMIZE TABLE test_shared_data_wide FINAL;
OPTIMIZE TABLE test_shared_data_wide_chunked FINAL;
OPTIMIZE TABLE test_shared_data_compact_chunked FINAL;

SELECT 'wide', count(), sum(cityHash64(toString(json))), groupUniqArray(dynamicType(json.b)), groupUniqArray(dynamicType(json.d)) FROM test_shared_data_wide;
SELECT 'wide_chunked', count(), sum(cityHash64(toString(json))), groupUniqArray(dynamicType(json.b)), groupUniqArray(dynamicType(json.d)) FROM test_shared_data_wide_chunked;
SELECT 'compact_chunked', count(), sum(cityHash64(toString(json))), groupUniqArray(dynamicType(json.b)), groupUniqArray(dynamicType(json.d)) FROM test_shared_data_compact_chunked;

SELECT id, json FROM test_shared_data_wide WHERE id IN (0, 1, 2, 3, 4, 1500, 1501, 1502, 2999) ORDER BY id;
SELECT id, json.b, json.d, json.p5, json.q3, json.c FROM test_shared_data_wide_chunked WHERE id IN (5, 42, 1503, 2001) ORDER BY id, toString(json);
SELECT id, json.^c, json.p0 FROM test_shared_data_compact_chunked WHERE id IN (0, 37, 1665) ORDER BY id, toString(json);

DROP TABLE test_shared_data_wide;
DROP TABLE test_shared_data_wide_chunked;
DROP TABLE test_shared_data_compact_chunked;
