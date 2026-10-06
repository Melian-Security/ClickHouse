-- Tags: no-fasttest
-- New types of a Dynamic column are added one by one at the start, in the middle and at the end
-- of the sorted list of variants. The values and their types must stay the same.

SET allow_experimental_dynamic_type = 1;
SET allow_suspicious_types_in_order_by = 1;

DROP TABLE IF EXISTS test_dynamic_add_variant;
CREATE TABLE test_dynamic_add_variant (id UInt64, d Dynamic) ENGINE = Memory;

INSERT INTO test_dynamic_add_variant SELECT 1, 'abc'::String;
INSERT INTO test_dynamic_add_variant VALUES
    (2, 'b'::String), (3, 42::Int64), (4, [1, 2]::Array(Int64)), (5, 'c'::String), (6, 3.5::Float64),
    (7, toDate('2020-01-01')), (8, true::Bool), (9, -1::Int8), (10, (1, 'x')::Tuple(a UInt8, b String)), (11, 7::UInt8),
    (12, ['x']::Array(String)), (13, 43::Int64), (14, toDateTime64('2020-01-01 00:00:00', 3, 'UTC')), (15, 'z'::String);

SELECT id, d, dynamicType(d) FROM test_dynamic_add_variant ORDER BY id;
SELECT id, d.String, d.Int64, d.`Array(Int64)`, d.Float64 FROM test_dynamic_add_variant ORDER BY id;
SELECT dynamicType(d) AS type, count() FROM test_dynamic_add_variant GROUP BY type ORDER BY type;

DROP TABLE test_dynamic_add_variant;

-- With a limit on the number of types, the types that do not fit go to the shared variant.
SELECT d, dynamicType(d), isDynamicElementInSharedData(d)
FROM format(JSONEachRow, 'd Dynamic(max_types=3)', '
{"d" : "a"}
{"d" : 1}
{"d" : [1, 2]}
{"d" : 1.5}
{"d" : true}
{"d" : "b"}
{"d" : ["x"]}
{"d" : 2}
');

-- Values of JSON paths in shared data are written through a temporary Dynamic column per row.
SELECT json, JSONAllPathsWithTypes(json), JSONSharedDataPaths(json)
FROM format(JSONEachRow, 'json JSON(max_dynamic_paths=1)', '
{"json" : {"a" : 1, "b" : [{"k" : "x"}], "c" : ["s"], "d" : [1, 2], "e" : {"f" : 1.5}, "g" : "str"}}
{"json" : {"a" : "x", "g" : [{"k" : 1}], "c" : [1], "b" : [[1]], "z" : null}}
');
