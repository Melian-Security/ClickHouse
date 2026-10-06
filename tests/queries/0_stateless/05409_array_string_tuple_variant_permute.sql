-- Permutation and index of Array(String), Array(Tuple(...)), Map, Variant and JSON shared data,
-- through the sort of an INSERT block and through ORDER BY with and without LIMIT.

SET allow_experimental_variant_type = 1, allow_experimental_dynamic_type = 1, enable_json_type = 1;
SET optimize_on_insert = 0;

DROP TABLE IF EXISTS t_permute;

CREATE TABLE t_permute
(
    key UInt64,
    s Array(String),
    t Array(Tuple(String, String)),
    m Map(String, String),
    n Array(Tuple(String, Array(String))),
    v Variant(String, UInt64),
    j JSON(max_dynamic_paths = 1)
)
ENGINE = MergeTree ORDER BY key
SETTINGS min_bytes_for_wide_part = 0;

INSERT INTO t_permute
SELECT
    number AS key,
    arrayMap(x -> repeat(toString(key), x), range(key % 5)) AS s,
    arrayMap(x -> (concat('p', toString(x)), toString(key + x)), range(key % 4)) AS t,
    mapFromArrays(arrayMap(x -> concat('k', toString(x)), range(key % 3)), arrayMap(x -> toString(key * x), range(key % 3))) AS m,
    arrayMap(x -> (toString(x), arrayMap(y -> toString(key + y), range(x))), range(key % 3)) AS n,
    multiIf(key % 3 = 0, NULL, key % 3 = 1, toString(key)::Variant(String, UInt64), key::Variant(String, UInt64)) AS v,
    toJSONString(map('a', toString(key), concat('b', toString(key % 7)), toString(key * 2), concat('c', toString(key % 5)), toString(key * 3)))::JSON(max_dynamic_paths = 1) AS j
FROM numbers(10000)
ORDER BY cityHash64(number);

SELECT 'insert';
SELECT count(),
    countIf(s != arrayMap(x -> repeat(toString(key), x), range(key % 5))),
    countIf(t != arrayMap(x -> (concat('p', toString(x)), toString(key + x)), range(key % 4))),
    countIf(m != mapFromArrays(arrayMap(x -> concat('k', toString(x)), range(key % 3)), arrayMap(x -> toString(key * x), range(key % 3)))),
    countIf(n != arrayMap(x -> (toString(x), arrayMap(y -> toString(key + y), range(x))), range(key % 3))),
    countIf(NOT (key % 3 = 0 AND v IS NULL OR key % 3 = 1 AND v.String = toString(key) OR key % 3 = 2 AND v.UInt64 = key)),
    countIf(JSONExtractString(toString(j), 'a') != toString(key)
        OR JSONExtractString(toString(j), concat('b', toString(key % 7))) != toString(key * 2)
        OR JSONExtractString(toString(j), concat('c', toString(key % 5))) != toString(key * 3))
FROM t_permute;

SELECT 'order by';
SELECT key, s, t, m, n, v, j FROM (SELECT * FROM t_permute ORDER BY cityHash64(key) LIMIT 100) ORDER BY key LIMIT 6;

SELECT 'order by limit';
SELECT key, s, t, m, n, v, toString(j) FROM t_permute ORDER BY key DESC LIMIT 3;

DROP TABLE t_permute;
