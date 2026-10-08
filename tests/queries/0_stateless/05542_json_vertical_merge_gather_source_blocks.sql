-- Tags: no-random-settings, no-random-merge-tree-settings
-- Vertical merge of JSON parts with small granules into large blocks: each block of the result is filled from many
-- blocks of every source part, which have different dynamic paths and types, so how the rows of a source are
-- inserted is resolved for each of its blocks while the result block is filled. Every row must keep its values.

DROP TABLE IF EXISTS test_json_gather_source_blocks;

CREATE TABLE test_json_gather_source_blocks
(
    id UInt64,
    json JSON(max_dynamic_paths = 3, max_dynamic_types = 2, s String, n Nullable(Int64))
)
ENGINE = MergeTree ORDER BY id
SETTINGS min_bytes_for_wide_part = 0, vertical_merge_algorithm_min_rows_to_activate = 1, vertical_merge_algorithm_min_columns_to_activate = 1,
    index_granularity = 16, index_granularity_bytes = 0, merge_max_block_size = 5000, merge_max_block_size_bytes = 100000000;

SYSTEM STOP MERGES test_json_gather_source_blocks;

-- Part p has ids p, p + 5, p + 10, ... interleaved with the other parts, and runs of up to 3 consecutive ids for p = 4.
-- Each part has its own dynamic paths: a<p> and b<p> fill the limit of the part, the other paths go to shared data.
INSERT INTO test_json_gather_source_blocks SELECT number * 5, concat('{"s" : "s', toString(number), '", "n" : ',
    if(number % 3 = 0, 'null', toString(number)), ', "a0" : ', toString(number), ', "b0" : "', toString(number), '"',
    ', "c', toString(number % 4), '" : ', toString(number), '}') FROM numbers(3000);
INSERT INTO test_json_gather_source_blocks SELECT number * 5 + 1, concat('{"s" : "', repeat('t', number % 13), '"',
    ', "a1" : [', toString(number), '], "b1" : ', if(number % 2 = 0, 'true', toString(number / 2)),
    ', "a0" : "', toString(number), '"}') FROM numbers(3000);
INSERT INTO test_json_gather_source_blocks SELECT number * 5 + 2, concat('{"n" : ', toString(number),
    ', "a2" : {"k" : ', toString(number), '}, "b2" : ', toString(number), ', "a1" : ', toString(number), '}') FROM numbers(3000);
INSERT INTO test_json_gather_source_blocks SELECT number * 5 + 3, concat('{"s" : "u', toString(number), '"',
    if(number % 5 = 0, '', concat(', "a3" : ', toString(number))), ', "b0" : ', toString(number), '}') FROM numbers(3000);
INSERT INTO test_json_gather_source_blocks SELECT intDiv(number, 3) * 5 + 4, concat('{"s" : "v', toString(number), '"',
    ', "a4" : "', toString(number), '", "b4" : ', toString(number), ', "c', toString(number % 4), '" : "', toString(number), '"}')
    FROM numbers(9000) WHERE number % 3 <= intDiv(number, 3) % 3;

SELECT 'before merge';
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_gather_source_blocks;

SYSTEM START MERGES test_json_gather_source_blocks;
OPTIMIZE TABLE test_json_gather_source_blocks FINAL;

SELECT 'after merge';
SELECT count(), sum(cityHash64(id, toString(json))) FROM test_json_gather_source_blocks;
SELECT arraySort(groupUniqArrayArray(JSONDynamicPaths(json))), arraySort(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_gather_source_blocks;
SELECT id, json FROM test_json_gather_source_blocks WHERE id IN (0, 1, 2, 3, 4, 9, 14975, 14976, 14977, 14978) ORDER BY id, toString(json);

SYSTEM FLUSH LOGS part_log;
SELECT merge_algorithm, rows FROM system.part_log WHERE database = currentDatabase() AND table = 'test_json_gather_source_blocks' AND event_type = 'MergeParts';

DROP TABLE test_json_gather_source_blocks;
