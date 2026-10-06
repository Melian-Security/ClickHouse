-- Tags: zookeeper, no-replicated-database, no-shared-merge-tree, no-random-settings, no-random-merge-tree-settings
-- The block id of an insert is a hash of the inserted data, and replicas compare block ids written by
-- other replicas, possibly running another server version. The hash value of a block must therefore
-- stay the same; this pins it for String, Array, Variant, Nullable and JSON columns (including JSON
-- shared data) and checks that a retry of the same insert is deduplicated.

DROP TABLE IF EXISTS t_dedup_hash_value;

CREATE TABLE t_dedup_hash_value
(
    s String,
    a Array(String),
    v Variant(UInt64, String),
    n Nullable(String),
    j JSON(max_dynamic_paths = 2, x UInt32)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{database}/t_dedup_hash_value', 'r1')
ORDER BY tuple();

SET insert_deduplicate = 1, deduplicate_insert_select = 'enable_even_for_bad_queries', max_threads = 1, max_insert_threads = 1,
    max_block_size = 65505, max_insert_block_size = 1048449, min_insert_block_size_rows = 1048449, min_insert_block_size_bytes = 268402944;

INSERT INTO t_dedup_hash_value
SELECT
    repeat('s', number % 37),
    arrayMap(i -> toString(i * number), range(number % 5)),
    if(number % 3 = 0, number::Variant(UInt64, String), toString(number)::Variant(UInt64, String)),
    if(number % 4 = 0, NULL, toString(number % 11)),
    concat('{"x": ', toString(number), ', "p', toString(number % 6), '": "', repeat('v', number % 13), '", "q": [', toString(number % 3), ']}')::JSON(max_dynamic_paths = 2, x UInt32)
FROM numbers(3000);

INSERT INTO t_dedup_hash_value
SELECT
    repeat('s', number % 37),
    arrayMap(i -> toString(i * number), range(number % 5)),
    if(number % 3 = 0, number::Variant(UInt64, String), toString(number)::Variant(UInt64, String)),
    if(number % 4 = 0, NULL, toString(number % 11)),
    concat('{"x": ', toString(number), ', "p', toString(number % 6), '": "', repeat('v', number % 13), '", "q": [', toString(number % 3), ']}')::JSON(max_dynamic_paths = 2, x UInt32)
FROM numbers(3000);

INSERT INTO t_dedup_hash_value (s, a) VALUES ('a', ['b', 'cc']), ('', []), ('dddddddddd', ['', 'e']);
INSERT INTO t_dedup_hash_value (s, a) VALUES ('a', ['b', 'cc']), ('', []), ('dddddddddd', ['', 'e']);

SELECT count() FROM t_dedup_hash_value;

SELECT name FROM system.zookeeper
WHERE path = '/clickhouse/tables/' || currentDatabase() || '/t_dedup_hash_value/deduplication_hashes'
ORDER BY name;

DROP TABLE t_dedup_hash_value;
