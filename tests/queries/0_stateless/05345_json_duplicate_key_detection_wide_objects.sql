-- Duplicate keys must be detected at every nesting level and wherever they sit in a wide object,
-- and the duplicate-key settings must keep their exact semantics.

set enable_analyzer = 1;
set type_json_allow_duplicated_key_with_literal_and_nested_object = 0;
set type_json_skip_duplicated_paths = 0;

-- Same-type duplicates: literal/literal and object/object, at the root and nested.
select '{"a" : 1, "a" : 2}'::JSON; -- {serverError INCORRECT_DATA}
select '{"a" : {"b" : 1}, "a" : {"c" : 2}}'::JSON; -- {serverError INCORRECT_DATA}
select '{"x" : {"a" : 1, "y" : 2, "a" : 3}}'::JSON; -- {serverError INCORRECT_DATA}
select '{"x" : {"y" : {"z" : {"a" : 1, "a" : "s"}}}}'::JSON; -- {serverError INCORRECT_DATA}

-- Literal/object duplicates are rejected without the allow setting, in both orders.
select '{"a" : 1, "a" : {"b" : 2}}'::JSON; -- {serverError INCORRECT_DATA}
select '{"a" : {"b" : 2}, "a" : 1}'::JSON; -- {serverError INCORRECT_DATA}

-- A duplicate far apart in a wide object, including inside array elements.
select concat('{', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(200)), ', '), ', "k0" : 7}')::JSON; -- {serverError INCORRECT_DATA}
select '{"arr" : [{"a" : 1}, {"a" : 1, "b" : 2, "a" : 3}]}'::JSON; -- {serverError INCORRECT_DATA}

-- Typed paths: a duplicate of a typed path is still rejected.
select '{"a" : 1, "a" : 2}'::JSON(a Int64); -- {serverError INCORRECT_DATA}

-- Wide object without duplicates parses and keeps every key.
select length(JSONAllPaths(concat('{', arrayStringConcat(arrayMap(i -> concat('"k', toString(i), '" : ', toString(i)), range(200)), ', '), '}')::JSON));

-- type_json_skip_duplicated_paths keeps the first value of each (key, kind).
select '{"a" : 1, "a" : 2}'::JSON settings type_json_skip_duplicated_paths = 1;
select '{"a" : {"b" : 1}, "a" : {"c" : 2}}'::JSON settings type_json_skip_duplicated_paths = 1;
select '{"a" : 1, "a" : {"b" : 2}}'::JSON settings type_json_skip_duplicated_paths = 1;
select '{"a" : {"b" : 2}, "a" : 1}'::JSON settings type_json_skip_duplicated_paths = 1;
select '{"x" : {"a" : 1, "y" : 2, "a" : 3}}'::JSON settings type_json_skip_duplicated_paths = 1;

-- Allowing literal+object keeps both, in both orders; a third occurrence of either kind is still a duplicate.
set type_json_allow_duplicated_key_with_literal_and_nested_object = 1;
select '{"a" : 1, "a" : {"b" : 2}}'::JSON as json, json.a, json.a.b;
select '{"a" : {"b" : 2}, "a" : 1}'::JSON as json, json.a, json.a.b;
select '{"a" : 1, "a" : {"b" : 2}, "a" : 3}'::JSON; -- {serverError INCORRECT_DATA}
select '{"a" : 1, "a" : {"b" : 2}, "a" : {"c" : 3}}'::JSON; -- {serverError INCORRECT_DATA}
select '{"a" : 1, "a" : {"b" : 2}, "a" : 3, "a" : {"c" : 4}}'::JSON settings type_json_skip_duplicated_paths = 1;
select '{"a" : 1, "a" : {"b" : 2}}'::JSON(a Int64) as json, json.a, json.^a;
select '{"a" : {"b" : 2}, "a" : 1}'::JSON(a Int64) as json, json.a, json.^a;
