-- Tags: no-fasttest
-- Objects inserted one after another often share their keys. Check that where a path goes (typed path,
-- dynamic path or shared data) does not depend on the keys and the order of keys of the previous objects.

SET enable_json_type = 1;

DROP TABLE IF EXISTS test_json_path_cache;
CREATE TABLE test_json_path_cache (id UInt32, json JSON(max_dynamic_paths = 3, a.b UInt32, c String)) ENGINE = Memory;

-- Same keys in the same order, a missing key, an extra key, another order of keys, a nested object
-- instead of a literal, and new paths after the limit on dynamic paths is reached.
INSERT INTO test_json_path_cache FORMAT JSONEachRow
{"id" : 1, "json" : {"a" : {"b" : 1}, "c" : "x", "d" : 1, "e" : 1}}
{"id" : 2, "json" : {"a" : {"b" : 2}, "c" : "y", "d" : 2, "e" : 2}}
{"id" : 3, "json" : {"a" : {"b" : 3}, "d" : 3, "e" : 3}}
{"id" : 4, "json" : {"a" : {"b" : 4}, "c" : "z", "f" : 4, "d" : 4, "e" : 4}}
{"id" : 5, "json" : {"e" : 5, "d" : 5, "c" : "w", "a" : {"b" : 5}}}
{"id" : 6, "json" : {"a" : {"b" : 6}, "c" : "v", "d" : {"x" : 6}, "e" : 6}}
{"id" : 7, "json" : {"a" : {"b" : 7}, "c" : "u", "g" : 7, "h" : 7, "d" : 7, "e" : 7}}
{"id" : 8, "json" : {"a" : {"b" : 8}, "c" : "t", "g" : 8, "h" : 8, "d" : 8, "e" : 8}}
{"id" : 9, "json" : {"a" : {"b" : 9}, "c" : "s", "d" : null, "e" : 9, "g" : null}}
{"id" : 10, "json" : {"a" : {"b" : 10}, "c" : "r", "d" : 10, "e" : 10, "d.x" : 10}}

SELECT id, json, JSONDynamicPaths(json), JSONSharedDataPaths(json) FROM test_json_path_cache ORDER BY id;
TRUNCATE TABLE test_json_path_cache;

SELECT 'duplicated paths';
SET type_json_skip_duplicated_paths = 1;
INSERT INTO test_json_path_cache FORMAT JSONEachRow
{"id" : 1, "json" : {"d" : 1, "e" : 1, "f" : 1, "g" : 1}}
{"id" : 2, "json" : {"d" : 2, "d" : 3, "e" : 2, "g" : 2, "g" : 3}}
{"id" : 3, "json" : {"d" : 4, "e" : 4, "f" : 4, "g" : 4, "a.b" : 4, "a" : {"b" : 5}}}

SELECT id, json, JSONDynamicPaths(json), JSONSharedDataPaths(json) FROM test_json_path_cache ORDER BY id;
TRUNCATE TABLE test_json_path_cache;
SET type_json_skip_duplicated_paths = 0;

SELECT 'rows with errors';
SET input_format_allow_errors_num = 10;
INSERT INTO test_json_path_cache FORMAT JSONEachRow
{"id" : 1, "json" : {"a" : {"b" : 1}, "d" : 1}}
{"id" : 2, "json" : {"d" : 2, "e" : 2, "f" : 2, "a" : {"b" : "not a number"}}}
{"id" : 3, "json" : {"a" : {"b" : 3}, "d" : 3, "e" : 3, "f" : 3, "g" : 3}}
{"id" : 4, "json" : {"d" : 4, "d" : 5}}
{"id" : 5, "json" : {"a" : {"b" : 5}, "d" : 5, "e" : 5, "f" : 5, "g" : 5}}

SELECT id, json, JSONDynamicPaths(json), JSONSharedDataPaths(json) FROM test_json_path_cache ORDER BY id;
TRUNCATE TABLE test_json_path_cache;
SET input_format_allow_errors_num = 0;

SELECT 'arrays of objects';
INSERT INTO test_json_path_cache FORMAT JSONEachRow
{"id" : 1, "json" : {"d" : [{"x" : 1, "y" : 1}, {"y" : 2, "x" : 2}], "e" : [{"x" : 3}, {"z" : 3}]}}
{"id" : 2, "json" : {"d" : [{"x" : 4}, {"x" : 5, "y" : 5}], "e" : [{"z" : 6, "x" : 6}]}}

SELECT id, json, JSONDynamicPaths(json), JSONSharedDataPaths(json), JSONAllPathsWithTypes(json) FROM test_json_path_cache ORDER BY id;

DROP TABLE test_json_path_cache;
