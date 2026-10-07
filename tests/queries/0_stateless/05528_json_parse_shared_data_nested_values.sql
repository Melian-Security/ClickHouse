-- Values that go to the shared data of a JSON column and are not of a simple type: arrays, arrays of objects,
-- several values of the same type in one object, and values of different types in one object.

SET enable_json_type = 1;
SET input_format_json_infer_incomplete_types_as_strings = 0;

DROP TABLE IF EXISTS test_json_shared_nested;
CREATE TABLE test_json_shared_nested (id UInt64, json JSON(max_dynamic_paths = 1)) ENGINE = MergeTree ORDER BY id;

INSERT INTO test_json_shared_nested VALUES
    (1, '{"a" : 1, "b" : [{"x" : 1, "y" : "s1"}, {"x" : 2, "z" : [1, 2]}], "c" : [{"y" : "s2", "w" : {"q" : 3}}], "d" : ["t1", "t2"], "e" : [1, 2, 3]}'),
    (2, '{"a" : 2, "b" : [{"k" : "v"}], "c" : [{"k" : "u", "m" : 1.5}, {"n" : true}], "d" : [1, "s", 2.5], "f" : [[1, 2], [3]]}'),
    (3, '{"a" : 3, "b" : [{"x" : 3}], "c" : [{"p1" : 1, "p2" : 2, "p3" : 3, "p4" : 4}], "g" : {"h" : [{"i" : [{"j" : 1}]}]}}'),
    (4, '{"a" : 4, "b" : [{"x" : null, "y" : "s4"}], "c" : [{"x" : 5}], "d" : [null, "s"], "e" : [[], [1]]}'),
    (5, '{"a" : 5, "b" : "2020-01-01", "c" : [{"t" : "2020-01-01 00:00:00"}], "d" : ["2020-01-01"]}');

SELECT id, json FROM test_json_shared_nested ORDER BY id FORMAT JSONEachRow;
SELECT id, JSONSharedDataPaths(json) FROM test_json_shared_nested ORDER BY id;
SELECT id, json.b, dynamicType(json.b), json.c, dynamicType(json.c), json.d, dynamicType(json.d) FROM test_json_shared_nested ORDER BY id;
SELECT id, json.b[].x, json.c[].y, json.g.h[].i FROM test_json_shared_nested ORDER BY id;

-- A value whose type cannot be inferred fails the insert.
INSERT INTO test_json_shared_nested VALUES (6, '{"a" : 6, "b" : [{"x" : 1}], "c" : [null, null]}'); -- { error INCORRECT_DATA }
SELECT count() FROM test_json_shared_nested;

SELECT '{"a" : 1, "b" : [{"x" : 1, "y" : "s1"}, {"x" : 2, "z" : [1, 2]}], "c" : [{"y" : "s2"}], "d" : ["t1"]}'::JSON(max_dynamic_paths = 0) AS json, JSONSharedDataPaths(json), json.b, json.c FORMAT JSONEachRow;

DROP TABLE test_json_shared_nested;
