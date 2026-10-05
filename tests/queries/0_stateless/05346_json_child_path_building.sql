-- Paths of nested keys are built in one buffer that each object level appends to and truncates back.
-- These cases check that sibling and nested paths, escaped dots, shared data and error messages
-- all see the right path.

SET json_type_escape_dots_in_keys = 1;

-- A key holding more than one dot below a parent: every dot in the key is escaped, the separator is not.
SELECT '{"x" : {"a.b.c" : 42}}'::JSON(max_dynamic_paths = 0) AS json, JSONSharedDataPaths(json);
-- Empty keys carry no dot, so escaping leaves the separator-only paths untouched.
SELECT '{"" : {"" : 42}}'::JSON(max_dynamic_paths = 0) AS json, JSONSharedDataPaths(json);
-- Dotted keys at several levels, split between dynamic paths and shared data.
SELECT '{"a.b" : {"c.d" : 1, "e" : {"f.g.h" : 2}}, "i" : 3, "j.k" : [{"l.m" : 4}]}'::JSON(max_dynamic_paths = 2) AS json,
    JSONDynamicPaths(json), JSONSharedDataPaths(json);

SET json_type_escape_dots_in_keys = 0;

-- Long sibling keys after a deep object: the path must be truncated back to the parent before each sibling.
SELECT '{"first_long_key_name_beyond_sso" : {"deeply_nested_key_name_number_one" : {"x" : 1}}, "second_long_key_name_beyond_sso" : 2, "t" : {"u" : 3, "v_long_key_name_beyond_sso_buffer" : {"w" : 4}, "z" : 5}}'::JSON(max_dynamic_paths = 1) AS json,
    JSONDynamicPaths(json), JSONSharedDataPaths(json);
-- Typed paths mixed with dynamic paths and shared data.
SELECT '{"a" : {"b" : 1, "c" : "s", "d" : {"e" : 2}}, "f" : 3, "g" : {"h" : 4}}'::JSON(max_dynamic_paths = 1, `a.c` String, `g.h` Int64) AS json,
    json.a.c, json.g.h, JSONDynamicPaths(json), JSONSharedDataPaths(json);
-- Shared data paths are stored sorted regardless of key order.
SELECT '{"zz" : 1, "y" : {"b" : 2, "a" : 3}, "aa" : 4}'::JSON(max_dynamic_paths = 0) AS json, JSONSharedDataPaths(json);

-- Without escaping, a dotted key and a nested object collapse onto one shared-data path.
SELECT '{"a.b" : 1, "a" : {"b" : 2}}'::JSON(max_dynamic_paths = 0); -- { serverError INCORRECT_DATA }
SELECT '{"a.b" : 1, "a" : {"b" : 2}}'::JSON(max_dynamic_paths = 0) AS json, JSONSharedDataPaths(json)
    SETTINGS type_json_skip_duplicated_paths = 1;
-- The duplicate is reported under its full nested path.
SELECT '{"p" : {"q" : {"r" : 1}, "s" : 1, "s" : 2}}'::JSON; -- { serverError INCORRECT_DATA }
