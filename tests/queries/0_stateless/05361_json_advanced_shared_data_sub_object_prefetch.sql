-- Tags: no-fasttest, no-random-settings, no-random-merge-tree-settings
-- no-fasttest: needs an S3 disk.

-- A sub-object of JSON with the `advanced` shared data serialization in a Wide part is read bucket by bucket,
-- and the readers that prefetch start the reads of all buckets before deserializing any of them.
-- Check that it reads the same data as the `map` serialization, with and without prefetches, on a local and on an S3 disk.

SET max_threads = 1, max_block_size = 100;

DROP TABLE IF EXISTS t_sub_object_map;
DROP TABLE IF EXISTS t_sub_object_local;
DROP TABLE IF EXISTS t_sub_object_s3;

CREATE TABLE t_sub_object_map (id UInt64, json JSON(max_dynamic_paths = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS index_granularity = 64, min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'map', object_shared_data_serialization_version_for_zero_level_parts = 'map';

CREATE TABLE t_sub_object_local (id UInt64, json JSON(max_dynamic_paths = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS index_granularity = 64, min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced', object_shared_data_serialization_version_for_zero_level_parts = 'advanced',
    object_shared_data_buckets_for_wide_part = 8;

CREATE TABLE t_sub_object_s3 (id UInt64, json JSON(max_dynamic_paths = 2)) ENGINE = MergeTree ORDER BY id
SETTINGS index_granularity = 64, min_bytes_for_wide_part = 0, min_rows_for_wide_part = 0, object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced', object_shared_data_serialization_version_for_zero_level_parts = 'advanced',
    object_shared_data_buckets_for_wide_part = 8, storage_policy = 's3_no_cache';

-- Two parts, each with many paths under the prefixes `a` and `b` spread over all buckets, with values of different types.
INSERT INTO t_sub_object_map SELECT number, concat('{"a":{"p', toString(number % 37), '":', toString(number), ',"s', toString(number % 23), '":"', toString(number * 3), '","x":{"y', toString(number % 11), '":[', toString(number), ',', toString(number + 1), ']}},"b":{"q', toString(number % 29), '":', toString(number % 5), '},"c', toString(number % 13), '":"c"}') FROM numbers(1000);
INSERT INTO t_sub_object_map SELECT number, concat('{"a":{"p', toString(number % 41), '":"v', toString(number), '"},"b":{"q', toString(number % 31), '":[{"z":', toString(number), '}]}}') FROM numbers(1000, 700);

INSERT INTO t_sub_object_local SELECT * FROM t_sub_object_map WHERE id < 1000 ORDER BY id;
INSERT INTO t_sub_object_local SELECT * FROM t_sub_object_map WHERE id >= 1000 ORDER BY id;
INSERT INTO t_sub_object_s3 SELECT * FROM t_sub_object_map WHERE id < 1000 ORDER BY id;
INSERT INTO t_sub_object_s3 SELECT * FROM t_sub_object_map WHERE id >= 1000 ORDER BY id;

SELECT table, part_type, count() FROM system.parts WHERE database = currentDatabase() AND table LIKE 't_sub_object_%' AND active GROUP BY table, part_type ORDER BY table;

-- Every query reads the sub-objects `a` and `a.x` and a path of shared data, over a point, a range, a sparse set of granules and the whole table.
SELECT 'prefetch';
SET remote_filesystem_read_prefetch = 1, local_filesystem_read_prefetch = 1, local_filesystem_read_method = 'pread_threadpool';

SELECT (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id = 500)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_local WHERE id = 500),
    (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id = 500)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_s3 WHERE id = 500);

SELECT (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id BETWEEN 100 AND 1450)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_local WHERE id BETWEEN 100 AND 1450),
    (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id BETWEEN 100 AND 1450)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_s3 WHERE id BETWEEN 100 AND 1450);

SELECT (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id % 300 < 3)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_local WHERE id % 300 < 3),
    (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id % 300 < 3)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_s3 WHERE id % 300 < 3);

SELECT (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_map)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_local),
    (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_map)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_s3);

SELECT 'no prefetch';
SET remote_filesystem_read_prefetch = 0, local_filesystem_read_prefetch = 0;

SELECT (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id BETWEEN 100 AND 1450)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_local WHERE id BETWEEN 100 AND 1450),
    (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_map WHERE id BETWEEN 100 AND 1450)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^a.x), toString(json.a.p3))) FROM t_sub_object_s3 WHERE id BETWEEN 100 AND 1450);

SELECT (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_map)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_local),
    (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_map)
    = (SELECT sum(cityHash64(id, toString(json.^a), toString(json.^b))) FROM t_sub_object_s3);

DROP TABLE t_sub_object_map;
DROP TABLE t_sub_object_local;
DROP TABLE t_sub_object_s3;
