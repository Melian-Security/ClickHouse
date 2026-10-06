-- Objects with distinct keys and objects with a repeated key, below and above 8 keys and above 128 keys,
-- and values of every simple type written to dynamic paths and to shared data.

set enable_analyzer = 1;
set type_json_allow_duplicated_key_with_literal_and_nested_object = 0;
set type_json_skip_duplicated_paths = 0;

-- Distinct keys, nested objects of several sizes.
select concat('{"o' || toString(n) || '" : {', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(n)), ', '), '}}')::JSON as json, length(JSONAllPaths(json))
from (select arrayJoin([1, 2, 7, 8, 9, 16]) as n);
select length(JSONAllPaths(concat('{', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : {"a" : ', toString(i), '}'), range(130)), ', '), '}')::JSON));

-- A repeated key is found wherever it is in objects of every size.
select concat('{', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(n)), ', '), ', "k', toString(n - 1), '" : 7}')::JSON
from (select arrayJoin([2, 7, 8, 9, 16, 128, 129]) as n); -- {serverError INCORRECT_DATA}
select concat('{"k0" : 7, ', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(n)), ', '), '}')::JSON
from (select arrayJoin([8, 9]) as n); -- {serverError INCORRECT_DATA}
select concat('{', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(n)), ', '), ', "k0" : 7}')::JSON as json
from (select arrayJoin([2, 8, 9, 16, 129]) as n) settings type_json_skip_duplicated_paths = 1;
select concat('{', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(12)), ', '), ', "k3" : {"x" : 1}}')::JSON as json, json.k3, json.k3.x
settings type_json_allow_duplicated_key_with_literal_and_nested_object = 1;

-- Values of every simple type in dynamic paths: the variant is added on first use and reused afterwards.
select json.b, dynamicType(json.b), json.i, dynamicType(json.i), json.u, dynamicType(json.u), json.f, dynamicType(json.f)
from format(JSONEachRow, 'json JSON(max_dynamic_paths = 8)', $$
{"json" : {"b" : true, "i" : -1, "u" : 18446744073709551615, "f" : 0.5, "s" : "str", "d" : "2024-01-01", "dt" : "2024-01-01 00:00:00", "dt64" : "2024-01-01 00:00:00.123"}}
{"json" : {"b" : false, "i" : -2, "u" : 18446744073709551614, "f" : 1.5, "s" : "2024-01-02", "d" : "2024-01-02", "dt" : "2024-01-02 00:00:00", "dt64" : "2024-01-02 00:00:00.456"}}
{"json" : {"b" : 1, "i" : "x", "u" : 1, "f" : "y", "s" : 1, "d" : "z", "dt" : "2024-01-03", "dt64" : "w"}}
$$);
select json.s, dynamicType(json.s), json.d, dynamicType(json.d), json.dt, dynamicType(json.dt), json.dt64, dynamicType(json.dt64)
from format(JSONEachRow, 'json JSON(max_dynamic_paths = 8)', $$
{"json" : {"b" : true, "i" : -1, "u" : 18446744073709551615, "f" : 0.5, "s" : "str", "d" : "2024-01-01", "dt" : "2024-01-01 00:00:00", "dt64" : "2024-01-01 00:00:00.123"}}
{"json" : {"b" : false, "i" : -2, "u" : 18446744073709551614, "f" : 1.5, "s" : "2024-01-02", "d" : "2024-01-02", "dt" : "2024-01-02 00:00:00", "dt64" : "2024-01-02 00:00:00.456"}}
{"json" : {"b" : 1, "i" : "x", "u" : 1, "f" : "y", "s" : 1, "d" : "z", "dt" : "2024-01-03", "dt64" : "w"}}
$$);
select json.s, dynamicType(json.s), json.b, dynamicType(json.b)
from format(JSONEachRow, 'json JSON(max_dynamic_paths = 8)', $$
{"json" : {"s" : "2024-01-01", "b" : true}}
{"json" : {"s" : "x", "b" : "2024-01-01"}}
$$) settings input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;

-- The same values in shared data.
select json, JSONSharedDataPaths(json), dynamicType(json.b), dynamicType(json.i), dynamicType(json.u), dynamicType(json.f), dynamicType(json.s), dynamicType(json.d), dynamicType(json.dt), dynamicType(json.dt64), dynamicType(json.a)
from format(JSONEachRow, 'json JSON(max_dynamic_paths = 0)', '{"json" : {"b" : true, "i" : -1, "u" : 18446744073709551615, "f" : 0.5, "s" : "str", "d" : "2024-01-01", "dt" : "2024-01-01 00:00:00", "dt64" : "2024-01-01 00:00:00.123", "a" : [1, 2]}}');
select json, dynamicType(json.s), dynamicType(json.d)
from format(JSONEachRow, 'json JSON(max_dynamic_paths = 0)', '{"json" : {"s" : "str", "d" : "2024-01-01"}}') settings input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;
