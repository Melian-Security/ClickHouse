-- Tags: no-fasttest

SET enable_json_type = 1;
SET input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;

SELECT '-- the first value of a new dynamic path, of each simple type, then values of other types';
DROP TABLE IF EXISTS test_json_new_paths;
CREATE TABLE test_json_new_paths (json JSON(max_dynamic_paths = 8)) ENGINE = Memory;
INSERT INTO test_json_new_paths VALUES ('{"a" : true, "b" : -1, "c" : 18446744073709551615, "d" : 1.5, "e" : "s"}'), ('{"a" : 1, "b" : "x", "c" : false, "d" : 2, "e" : 2.5}'), ('{"a" : "y", "b" : 0.25, "c" : -3, "d" : true, "e" : 18446744073709551615}');
SELECT json, JSONDynamicPathsWithTypes(json), JSONSharedDataPathsWithTypes(json) FROM test_json_new_paths;
SELECT dynamicType(json.a), dynamicType(json.b), dynamicType(json.c), dynamicType(json.d), dynamicType(json.e) FROM test_json_new_paths;
DROP TABLE test_json_new_paths;

SELECT '-- arrays of objects in shared data: every object gets new dynamic paths';
DROP TABLE IF EXISTS test_json_arrays_of_objects;
CREATE TABLE test_json_arrays_of_objects (json JSON(max_dynamic_paths = 8)) ENGINE = Memory;
INSERT INTO test_json_arrays_of_objects VALUES ('{"c1" : 1, "c2" : 2, "c3" : 3, "c4" : 4, "c5" : 5, "c6" : 6, "c7" : 7, "c8" : 8, "a" : [{"k" : true, "l" : -1, "m" : 18446744073709551615, "n" : 0.5, "o" : "t"}, {"k" : 1, "l" : "u", "p" : {"q" : false}}]}'), ('{"c1" : 1, "c2" : 2, "c3" : 3, "c4" : 4, "c5" : 5, "c6" : 6, "c7" : 7, "c8" : 8, "a" : [{"o" : 2, "k" : "v"}], "b" : [{"k" : 1.5}, {"k" : true}]}'), ('{"c1" : 1, "c2" : 2, "c3" : 3, "c4" : 4, "c5" : 5, "c6" : 6, "c7" : 7, "c8" : 8, "b" : [{"x" : [1, 2], "y" : [{"z" : "w"}]}]}');
SELECT json, JSONSharedDataPathsWithTypes(json) FROM test_json_arrays_of_objects;
SELECT dynamicType(json.a), arrayMap(x -> JSONDynamicPathsWithTypes(x), json.a.:`Array(JSON(max_dynamic_types=16, max_dynamic_paths=2))`) FROM test_json_arrays_of_objects;
SELECT arrayJoin(json.a.:`Array(JSON(max_dynamic_types=16, max_dynamic_paths=2))`) AS o, dynamicType(o.k), dynamicType(o.l), dynamicType(o.m), dynamicType(o.n), dynamicType(o.o) FROM test_json_arrays_of_objects;
DROP TABLE test_json_arrays_of_objects;

SELECT '-- many objects, read back after the insert';
SELECT count(), sum(cityHash64(toString(j))), arraySort(groupUniqArray(arrayJoin(JSONAllPathsWithTypes(j))))
FROM
(
    SELECT CAST('{"b3":0,"b4":0,"b5":0,"b6":0,"a":[' || arrayStringConcat(arrayMap(i -> '{"k' || toString(i % 3) || '":' || multiIf(i % 4 = 0, 'true', i % 4 = 1, toString(i), i % 4 = 2, '"s' || toString(i) || '"', '0.5') || '}', range(number % 5 + 1)), ',') || '], "b' || toString(number % 3) || '":' || toString(number) || '}', 'JSON(max_dynamic_paths = 4)') AS j
    FROM numbers(1000)
);

SELECT '-- date inference: Date is a simple type, DateTime64 is not';
SET input_format_try_infer_dates = 1, input_format_try_infer_datetimes = 1;
SELECT j, JSONSharedDataPathsWithTypes(j), arrayMap(x -> JSONDynamicPathsWithTypes(x), j.a.:`Array(JSON(max_dynamic_types=16, max_dynamic_paths=1))`)
FROM (SELECT CAST('{"c1":0,"c2":0,"c3":0,"c4":0,"a":[{"d":"2020-01-01","t":"2020-01-01 00:00:00.123","s":"x"}],"b":"2020-01-02"}', 'JSON(max_dynamic_paths = 4)') AS j);
