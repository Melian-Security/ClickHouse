-- Tags: no-fasttest

SET enable_json_type = 1;
SET input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;

SELECT '-- objects with different keys, in different orders, with keys that come and go';
DROP TABLE IF EXISTS test_json_varying;
CREATE TABLE test_json_varying (json JSON(max_dynamic_paths = 4, a UInt32, `b.c` String, `d.e.f` Int64)) ENGINE = Memory;
INSERT INTO test_json_varying VALUES ('{"a" : 1, "b" : {"c" : "x", "g" : 1}, "h" : 2}'), ('{"a" : 2, "b" : {"g" : 2, "c" : "y"}, "i" : 3, "h" : 4}'), ('{"h" : 5, "a" : 3}'), ('{"b" : {"c" : "z"}, "d" : {"e" : {"f" : 6, "k" : 7}}, "j" : {"l" : 8}}'), ('{"a" : 4, "x1" : 1, "x2" : 2, "x3" : 3, "x4" : 4, "x5" : 5, "h" : 6}'), ('{"x5" : 5, "x4" : 4, "x3" : 3, "x2" : 2, "x1" : 1}'), ('{}'), ('{"a" : 5, "b" : {"c" : "w", "g" : null}, "h" : null}'), ('{"d" : {"e" : {"k" : 9}}, "j" : {"l" : 10, "m" : 11}, "a" : 6}');
INSERT INTO test_json_varying VALUES ('{"a" : 7, "b" : {"c" : "v"}, "h" : 12, "x3" : 13}'), ('{"j" : {"m" : 14}, "i" : 15}');
SELECT json, JSONDynamicPaths(json), JSONSharedDataPaths(json) FROM test_json_varying ORDER BY toString(json);
DROP TABLE test_json_varying;

SELECT '-- an object with many keys, then objects with some of them, in another order';
DROP TABLE IF EXISTS test_json_many_keys;
CREATE TABLE test_json_many_keys (json JSON(max_dynamic_paths = 8)) ENGINE = Memory;
INSERT INTO test_json_many_keys SELECT '{' || arrayStringConcat(arrayMap(i -> '"k' || toString((i * 7 + number) % 40) || '" : ' || toString(i), range(number % 40 + 1)), ', ') || '}' FROM numbers(100);
SELECT count(), sum(cityHash64(toString(json))), arraySort(groupUniqArrayArray(JSONDynamicPaths(json))) FROM test_json_many_keys;
SELECT arraySort(groupUniqArrayArray(JSONSharedDataPaths(json))) FROM test_json_many_keys;
DROP TABLE test_json_many_keys;

SELECT '-- the same path from a key with a dot and from a nested object';
SELECT CAST('{"a.b" : 1, "a" : {"b" : 2}}', 'JSON'); -- {serverError INCORRECT_DATA}
SELECT CAST('{"a.b" : 1, "a" : {"c" : 2}}', 'JSON') AS j, JSONAllPaths(j);
SELECT CAST('{"a" : {"b" : 2}, "a.b" : 1}', 'JSON(a.b UInt32)'); -- {serverError INCORRECT_DATA}
SELECT CAST('{"a.b" : 1, "a" : {"b" : 2}}', 'JSON') SETTINGS type_json_skip_duplicated_paths = 1;
SELECT CAST('{"a" : {"b" : 2}, "a.b" : 1}', 'JSON(a.b UInt32)') SETTINGS type_json_skip_duplicated_paths = 1;
SELECT CAST('{"c" : 0, "a.b" : 1, "a" : {"b" : 2}}', 'JSON(max_dynamic_paths = 1)') SETTINGS type_json_skip_duplicated_paths = 1;
SELECT CAST('{"a.b" : 1, "a" : {"b" : 2}}', 'JSON') AS j, JSONAllPaths(j) SETTINGS json_type_escape_dots_in_keys = 1;

SELECT '-- duplicated keys';
SELECT CAST('{"a" : 1, "b" : 2, "a" : 3}', 'JSON'); -- {serverError INCORRECT_DATA}
SELECT CAST('{"a" : 1, "b" : 2, "a" : 3}', 'JSON') SETTINGS type_json_skip_duplicated_paths = 1;
SELECT CAST('{"a" : 1, "b" : 2, "a" : 3}', 'JSON(a UInt32)') SETTINGS type_json_skip_duplicated_paths = 1;
SELECT CAST('{"a" : 1, "a" : {"b" : 2}}', 'JSON') SETTINGS type_json_allow_duplicated_key_with_literal_and_nested_object = 1;
SELECT CAST('{"a" : {"b" : 2}, "a" : 1}', 'JSON(a UInt32)') SETTINGS type_json_allow_duplicated_key_with_literal_and_nested_object = 1;

SELECT '-- invalid values of typed paths';
SELECT CAST(s, 'JSON(a UInt32, b UInt32)') FROM format(JSONEachRow, 's String', '{"s" : "{\\"a\\" : \\"x\\", \\"b\\" : 1, \\"c\\" : 2}"}\n{"s" : "{\\"b\\" : 2, \\"a\\" : 3}"}\n{"s" : "{\\"a\\" : \\"y\\", \\"a\\" : 4}"}') SETTINGS type_json_skip_invalid_typed_paths = 1, type_json_skip_duplicated_paths = 1;

SELECT '-- skipped paths';
SELECT CAST(s, 'JSON(SKIP b, SKIP REGEXP \'^x\')') FROM format(JSONEachRow, 's String', '{"s" : "{\\"a\\" : 1, \\"b\\" : {\\"c\\" : 2}, \\"x1\\" : 3}"}\n{"s" : "{\\"x2\\" : 4, \\"b\\" : 5, \\"a\\" : 6}"}');
SELECT CAST(s, 'JSON(SKIP REGEXP \'1\')') FROM format(JSONEachRow, 's String', '{"s" : "{\\"a1\\" : 1, \\"b\\" : 2}"}\n{"s" : "{\\"a1\\" : 3, \\"b\\" : 4}"}') SETTINGS type_json_use_partial_match_to_skip_paths_by_regexp = 0;
SELECT CAST(s, 'JSON(SKIP REGEXP \'1\')') FROM format(JSONEachRow, 's String', '{"s" : "{\\"a1\\" : 1, \\"b\\" : 2}"}\n{"s" : "{\\"a1\\" : 3, \\"b\\" : 4}"}') SETTINGS type_json_use_partial_match_to_skip_paths_by_regexp = 1;

SELECT '-- no dynamic paths';
SELECT CAST(s, 'JSON(max_dynamic_paths = 0)') AS j, JSONSharedDataPaths(j) FROM format(JSONEachRow, 's String', '{"s" : "{\\"a\\" : 1, \\"b\\" : {\\"c\\" : 2}}"}\n{"s" : "{\\"b\\" : {\\"c\\" : 3}, \\"a\\" : 4, \\"d\\" : 5}"}');

SELECT '-- arrays of objects with varying keys in shared data';
DROP TABLE IF EXISTS test_json_arrays;
CREATE TABLE test_json_arrays (id UInt64, json JSON(max_dynamic_paths = 8)) ENGINE = Memory;
INSERT INTO test_json_arrays SELECT number, '{"c1":0,"c2":0,"c3":0,"c4":0,"c5":0,"c6":0,"c7":0,"c8":0,"a":[' || arrayStringConcat(arrayMap(i -> '{"k' || toString((i + number) % 3) || '":' || toString(i) || ',"m' || toString(number % 2) || '":{"n":' || toString(i) || '}}', range(number % 4 + 1)), ',') || '],"b' || toString(number % 5) || '":' || toString(number) || '}' FROM numbers(1000);
SELECT count(), sum(cityHash64(toString(json))) FROM test_json_arrays;
SELECT arraySort(groupUniqArray(arrayJoin(JSONAllPathsWithTypes(json)))) FROM test_json_arrays;
SELECT id, json.a, arrayMap(x -> JSONDynamicPaths(x), json.a.:`Array(JSON(max_dynamic_types=16, max_dynamic_paths=2))`), arrayMap(x -> JSONSharedDataPaths(x), json.a.:`Array(JSON(max_dynamic_types=16, max_dynamic_paths=2))`)
FROM test_json_arrays ORDER BY id LIMIT 6;
DROP TABLE test_json_arrays;
