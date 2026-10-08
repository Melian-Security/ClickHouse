-- Tags: no-darwin, no-random-merge-tree-settings
-- macOS filesystem (APFS) is case-insensitive, so MergeTree hashes stream filenames unconditionally.

-- Stream file names of substreams whose names need escaping: JSON paths, Tuple elements and Variant types.
DROP TABLE IF EXISTS t_stream_names;
CREATE TABLE t_stream_names
(
    id UInt64,
    t Tuple(`p.q` UInt32, `r s` String),
    v Variant(String, Array(UInt32), Map(String, UInt64)),
    json JSON(max_dynamic_paths = 3, `typed-path` String, `typed.path` Array(Nullable(String)))
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, index_granularity = 2,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    replace_long_file_name_to_hash = 0, escape_variant_subcolumn_filenames = 1, object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced', object_shared_data_serialization_version_for_zero_level_parts = 'advanced',
    object_shared_data_buckets_for_wide_part = 2, enable_block_number_column = 0, enable_block_offset_column = 0, serialization_info_version = 'basic';

SYSTEM STOP MERGES t_stream_names;
INSERT INTO t_stream_names SELECT number, tuple(number, 'x y'),
    multiIf(number % 3 = 0, 'str'::Variant(String, Array(UInt32), Map(String, UInt64)), number % 3 = 1, [1, 2]::Array(UInt32), map('k', number)),
    '{"typed-path" : "a", "typed.path" : ["b", null], "a-b" : 1, "c d" : "e", "é" : [1, 2], "x.y" : {"z%" : 42}, "q/w" : true, "u" : {"v" : [{"w" : 1}]}}'
    FROM numbers(5);
INSERT INTO t_stream_names SELECT number + 5, tuple(number, 'z'), 'str2', '{"typed-path" : "c", "a-b" : "string now", "k$" : 1.5, "x.y" : {"z%" : [1]}}' FROM numbers(5);
SYSTEM START MERGES t_stream_names;
OPTIMIZE TABLE t_stream_names FINAL;

SELECT column, substreams, filenames FROM system.parts_columns WHERE database = currentDatabase() AND table = 't_stream_names' AND active ORDER BY column;
SELECT id, t, v, json FROM t_stream_names ORDER BY id;
SELECT json.`a-b`, json.`c d`, json.`é`, json.x.y.`z%`, json.`q/w`, json.`k$`, json.u.v FROM t_stream_names ORDER BY id;

DROP TABLE t_stream_names;

-- Vertical merges and reads of a subset of columns of compact parts, with and without marks for substreams.
DROP TABLE IF EXISTS t_compact_columns;
CREATE TABLE t_compact_columns
(
    id UInt64,
    s String,
    n UInt64,
    a Array(UInt32),
    `nested.x` Array(UInt8),
    `nested.y` Array(String),
    json JSON(max_dynamic_paths = 2, `t.a` String)
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_rows_for_wide_part = 1000, min_bytes_for_wide_part = 0, index_granularity = 64,
    vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    write_marks_for_substreams_in_compact_parts = 1, max_bytes_to_merge_at_max_space_in_pool = 1, max_bytes_to_merge_at_min_space_in_pool = 1;

SYSTEM STOP MERGES t_compact_columns;
INSERT INTO t_compact_columns SELECT number, toString(number), number * 3, range(number % 5), range(number % 4), arrayMap(x -> toString(x), range(number % 4)),
    '{"t" : {"a" : "' || toString(number) || '"}, "k' || toString(number % 7) || '" : ' || toString(number) || '}'
    FROM numbers(0, 600) SETTINGS max_block_size = 150, max_insert_block_size = 150, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;
ALTER TABLE t_compact_columns MODIFY SETTING write_marks_for_substreams_in_compact_parts = 0;
INSERT INTO t_compact_columns SELECT number, toString(number), number * 3, range(number % 5), range(number % 4), arrayMap(x -> toString(x), range(number % 4)),
    '{"t" : {"a" : "' || toString(number) || '"}, "k' || toString(number % 7) || '" : ' || toString(number) || '}'
    FROM numbers(600, 600) SETTINGS max_block_size = 150, max_insert_block_size = 150, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

SELECT part_type, count(), sum(rows) FROM system.parts WHERE database = currentDatabase() AND table = 't_compact_columns' AND active GROUP BY part_type;
SELECT sum(n), sum(length(a)), sum(arraySum(nested.x)), sum(length(nested.y)), countIf(json.t.a = s), sum(json.k3::UInt64) FROM t_compact_columns;
SELECT n, nested.y, json.k5 FROM t_compact_columns WHERE id IN (5, 599, 600, 1199) ORDER BY id;

SYSTEM START MERGES t_compact_columns;
OPTIMIZE TABLE t_compact_columns FINAL;
SYSTEM FLUSH LOGS part_log;

SELECT part_type, count(), sum(rows) FROM system.parts WHERE database = currentDatabase() AND table = 't_compact_columns' AND active GROUP BY part_type;
SELECT merge_algorithm, length(merged_from) FROM system.part_log WHERE database = currentDatabase() AND table = 't_compact_columns' AND event_type = 'MergeParts';
SELECT sum(n), sum(length(a)), sum(arraySum(nested.x)), sum(length(nested.y)), countIf(json.t.a = s), sum(json.k3::UInt64) FROM t_compact_columns;
SELECT n, nested.y, json.k5 FROM t_compact_columns WHERE id IN (5, 599, 600, 1199) ORDER BY id;

DROP TABLE t_compact_columns;
