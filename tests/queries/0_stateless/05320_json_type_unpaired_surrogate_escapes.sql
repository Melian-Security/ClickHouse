-- The JSON type replaces escapes of unpaired UTF-16 surrogates with U+FFFD (EF BF BD)
-- when input_format_json_throw_on_bad_escape_sequence = 0, and rejects them otherwise.

SET input_format_json_throw_on_bad_escape_sequence = 1;
SELECT '{"a":"\\udf1e x"}'::JSON; -- { serverError INCORRECT_DATA }
SELECT '{"a":"\\ud83c"}'::JSON; -- { serverError INCORRECT_DATA }
SELECT * FROM format(JSONEachRow, 'j JSON', '{"j":{"a":"\\ud83c"}}'); -- { serverError INCORRECT_DATA }
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c\\udf1e"}'::JSON AS j);

SET input_format_json_throw_on_bad_escape_sequence = 0;

SELECT 'simdjson';
SET allow_simdjson = 1;
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\udf1e x"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c\\udf1e"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c\\ud83c\\udf1e"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\udc00\\ud800"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\uD83C x \\uDF1E"}'::JSON AS j);
SELECT hex(j.a::String), hex(j.b::String) FROM (SELECT '{"a":"\\\\ud83c","b":"\\ud83c"}'::JSON AS j);
SELECT hex(arrayJoin(JSONAllPaths(j))) FROM (SELECT '{"\\ud83c":1}'::JSON AS j);
SELECT replaceAll(toString(j), unhex('EFBFBD'), '<U+FFFD>') FROM (SELECT '{"a":{"b":[{"c":"x\\ud83c"}]}}'::JSON AS j);
SELECT '{"a":"\\ud83c"'::JSON; -- { serverError INCORRECT_DATA }
SELECT '{"a":"\\ud83c", b}'::JSON; -- { serverError INCORRECT_DATA }
SELECT '{"a":"\\ud83"}'::JSON; -- { serverError INCORRECT_DATA }

SELECT 'rapidjson';
SET allow_simdjson = 0;
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\udf1e x"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c\\udf1e"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\ud83c\\ud83c\\udf1e"}'::JSON AS j);
SELECT hex(j.a::String) FROM (SELECT '{"a":"\\udc00\\ud800"}'::JSON AS j);
SELECT hex(j.a::String), hex(j.b::String) FROM (SELECT '{"a":"\\\\ud83c","b":"\\ud83c"}'::JSON AS j);
SELECT '{"a":"\\ud83c"'::JSON; -- { serverError INCORRECT_DATA }
SET allow_simdjson = 1;

SELECT 'input formats';
SELECT hex(j.a::String) FROM format(JSONEachRow, 'j JSON', '{"j":{"a":"\\udf1e x"}}\n{"j":{"a":"ok"}}');
SELECT hex(json.a::String) FROM format(JSONAsObject, '{"a":"\\ud83c"}');

DROP TABLE IF EXISTS t_json_surrogates;
CREATE TABLE t_json_surrogates (id UInt32, event JSON(max_dynamic_paths = 2, message String, `user.name` String)) ENGINE = MergeTree ORDER BY id;
INSERT INTO t_json_surrogates FORMAT JSONEachRow {"id":1,"event":{"message":"ok \ud83c\udf1e","user":{"name":"n"}}} {"id":2,"event":{"message":"cut \ud83c","DetectedValues":["a\udf1e","b"],"x":1,"y":2,"z":3}} {"id":3,"event":{"message":"plain","user":{"name":"\udfff"}}}

SELECT id, hex(event.message), hex(event.user.name), replaceAll(toString(event.DetectedValues), unhex('EFBFBD'), '<U+FFFD>') FROM t_json_surrogates ORDER BY id;
DROP TABLE t_json_surrogates;
