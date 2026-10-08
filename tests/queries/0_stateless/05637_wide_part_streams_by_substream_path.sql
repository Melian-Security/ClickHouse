-- Tags: no-random-settings, no-random-merge-tree-settings
-- The Wide part writer finds the stream of a substream by its substream path, and the advanced JSON shared data
-- serialization lists the substream names of every path. Write parts with many granules through both (an INSERT and a
-- Vertical merge into a Wide part) and read the data back as a whole and by subcolumns: typed, dynamic and shared data
-- paths of different types, arrays of objects in shared data, a Nested column whose columns share the offsets stream
-- (written once in a Vertical merge) and a Map column.

DROP TABLE IF EXISTS t_streams_by_substream_path;

CREATE TABLE t_streams_by_substream_path
(
    id UInt64,
    json JSON(max_dynamic_paths = 2, a UInt64, `b.c` String, arr Array(Nullable(String))),
    n Nested(x UInt64, y String),
    m Map(String, UInt64)
)
ENGINE = MergeTree ORDER BY id
SETTINGS
    min_bytes_for_wide_part = 0,
    index_granularity = 128,
    index_granularity_bytes = '10Mi',
    object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'advanced',
    object_shared_data_buckets_for_wide_part = 4,
    vertical_merge_algorithm_min_rows_to_activate = 1,
    vertical_merge_algorithm_min_columns_to_activate = 1;

INSERT INTO t_streams_by_substream_path
SELECT
    number * 2 + parity AS id,
    concat(
        '{"a":', toString(id),
        ',"b":{"c":"s', toString(id % 13), '"}',
        ',"arr":["x', toString(id), '",null]',
        ',"k', toString(id % 7), '":', toString(id),
        ',"v', toString(id % 5), '":"str', toString(id), '"',
        ',"o":{"arr":[{"p', toString(id % 3), '":', toString(id), ',"q":"w', toString(id % 4), '"}]}',
        ',"mix":', if(id % 2 = 1, toString(id), concat('"m', toString(id), '"')),
        if(id % 11 = 0, concat(',"f":', toString(id / 4)), ''),
        '}')::JSON,
    range(id % 4),
    arrayMap(x -> concat('y', toString(x)), range(id % 4)),
    map(concat('key', toString(id % 9)), id, 'k', id % 3)
FROM numbers(2000) AS numbers_2000, (SELECT arrayJoin([0, 1]) AS parity) AS parities
ORDER BY parity, number
SETTINGS max_block_size = 1000, max_insert_block_size = 2000, min_insert_block_size_rows = 0, min_insert_block_size_bytes = 0;

SELECT 'parts', count(), groupUniqArray(part_type) FROM system.parts WHERE database = currentDatabase() AND table = 't_streams_by_substream_path' AND active;

SELECT
    count(),
    sum(cityHash64(toString(json))),
    sum(cityHash64(toString(n.x), toString(n.y))),
    sum(length(n.x)),
    sum(cityHash64(toString(m)))
FROM t_streams_by_substream_path;
SELECT
    sum(json.a),
    sum(cityHash64(json.`b.c`)),
    sum(cityHash64(toString(json.arr))),
    sum(cityHash64(toString(json.k3))),
    sum(cityHash64(toString(json.v2))),
    sum(cityHash64(toString(json.o.arr[].p1))),
    sum(cityHash64(toString(json.mix))),
    sum(cityHash64(toString(json.f)))
FROM t_streams_by_substream_path;
SELECT id, json.k3, json.v2, json.o.arr[].p1, json.o.arr[].q, json.mix, json.f, n.y, m['k'] FROM t_streams_by_substream_path WHERE id IN (3, 17, 1012, 2310, 3997) ORDER BY id;

OPTIMIZE TABLE t_streams_by_substream_path FINAL;

SELECT 'parts', count(), groupUniqArray(part_type) FROM system.parts WHERE database = currentDatabase() AND table = 't_streams_by_substream_path' AND active;

SELECT
    count(),
    sum(cityHash64(toString(json))),
    sum(cityHash64(toString(n.x), toString(n.y))),
    sum(length(n.x)),
    sum(cityHash64(toString(m)))
FROM t_streams_by_substream_path;
SELECT
    sum(json.a),
    sum(cityHash64(json.`b.c`)),
    sum(cityHash64(toString(json.arr))),
    sum(cityHash64(toString(json.k3))),
    sum(cityHash64(toString(json.v2))),
    sum(cityHash64(toString(json.o.arr[].p1))),
    sum(cityHash64(toString(json.mix))),
    sum(cityHash64(toString(json.f)))
FROM t_streams_by_substream_path;
SELECT id, json.k3, json.v2, json.o.arr[].p1, json.o.arr[].q, json.mix, json.f, n.y, m['k'] FROM t_streams_by_substream_path WHERE id IN (3, 17, 1012, 2310, 3997) ORDER BY id;

DROP TABLE t_streams_by_substream_path;
