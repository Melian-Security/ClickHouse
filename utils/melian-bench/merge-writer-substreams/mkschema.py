#!/usr/bin/env python3
"""Writes schema-typed.sql: the schema-wide.sql table with ~55 more typed paths (115 in all).

The extra typed paths are the first 88 paths of gen.py's untyped pool whose values have one type
(str/long_str -> String, int -> Int64, bool -> Bool, arr_str -> Array(Nullable(String))), so the
JSON column has as many typed paths as the production-shaped table it models.

Usage: mkschema.py > schema-typed.sql   (run next to schema-wide.sql)
"""
import os
import random

rng = random.Random(42)
WORDS = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
         "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
GROUPS = ["unmapped", "metadata.labels", "enrichments", "observables_ctx", "resources", "api",
          "actor.session", "device.agent", "network", "raw_extra"]
KINDS = ["str", "int", "float", "bool", "mixed", "arr_str", "arr_obj", "long_str"]
POOL = []
for i in range(250):
    group = GROUPS[i % len(GROUPS)]
    depth = 1 + (i % 3)
    parts = [group] + [f"{rng.choice(WORDS)}_{i % 7}" for _ in range(depth - 1)] + [f"f{i}"]
    POOL.append((".".join(parts), KINDS[i % len(KINDS)]))

TYPES = {"str": "String", "long_str": "String", "int": "Int64", "bool": "Bool", "arr_str": "Array(Nullable(String))"}
extra = [f"`{p}` {TYPES[k]}" for p, k in POOL[:88] if k in TYPES]

src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema-wide.sql")).read()
marker = "`user.uid` String)"
assert marker in src
print(src.replace(marker, "`user.uid` String, " + ", ".join(extra) + ")"), end="")
