#!/usr/bin/env python3
"""Synthetic OCSF-like log rows for the `event` JSON column, as JSONEachRow {"event": {...}}.

Rows carry ~40-80 paths each, drawn from ~250 distinct paths overall (so more than 64 dynamic
paths overflow into shared data), with nested objects, arrays of objects and mixed types.
String values include valid escaped surrogate pairs, other escapes and raw UTF-8, so the clean
path exercises escape decoding. `--surrogate-rate` makes that fraction of rows carry an unpaired
surrogate escape, the way vendors cut text mid-emoji.

Usage: gen.py ROWS [--seed N] [--surrogate-rate F] > out.jsonl
"""

import argparse
import json
import random
import uuid

TYPED_STRINGS = [
    "action", "activity_name", "actor.process.file.name", "actor.process.file.path", "actor.process.name",
    "actor.user.name", "actor.user.type", "actor.user.uid", "auth_protocol", "category_name", "class_name",
    "cloud.account.uid", "cloud.provider", "cloud.region", "connection_info.protocol_name", "device.hostname",
    "device.os.type", "device.type", "disposition", "dst_endpoint.hostname", "file.name", "file.path",
    "finding.title", "finding.uid", "http_request.http_method", "http_request.url.hostname", "message",
    "metadata.event_code", "metadata.product.name", "metadata.product.vendor_name", "metadata.tenant_uid",
    "process.cmd_line", "process.file.name", "process.file.path", "process.name", "query.hostname",
    "query.type", "service.name", "severity", "src_endpoint.hostname", "status", "type_name", "user.name",
    "user.uid",
]
TYPED_INTS = [
    "action_id", "activity_id", "category_uid", "class_uid", "connection_info.direction_id", "disposition_id",
    "dst_endpoint.port", "logon_type_id", "process.pid", "severity_id", "src_endpoint.port", "status_id",
    "type_uid",
]
TYPED_IPS = ["dst_endpoint.ip", "src_endpoint.ip"]

WORDS = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
         "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
UNICODE_BITS = ["\U0001F31E", "caf\u00e9", "\u65e5\u672c", "na\u00efve", "\u0436\u0443\u043a", "tab\tquote\"slash\\"]


def make_dynamic_paths():
    paths = []
    for vendor in range(10):
        for field in range(14):
            paths.append((f"unmapped.v{vendor}.field_{field}", ["str", "int", "float", "bool"][field % 4]))
    for i in range(30):
        paths.append((f"metadata.labels.l{i}", "str"))
    for i in range(30):
        paths.append((f"enrichments.e{i}.value", "str" if i % 3 else "int"))
    for i in range(20):
        paths.append((f"observables_meta.o{i}", "arr_str"))
    for i in range(20):
        paths.append((f"raw_extra.k{i}", "mixed"))
    return paths


DYNAMIC_PATHS = make_dynamic_paths()  # 240 paths


def text(rng, n_words):
    parts = [rng.choice(WORDS) for _ in range(n_words)]
    if rng.random() < 0.3:
        parts.insert(rng.randrange(len(parts) + 1), rng.choice(UNICODE_BITS))
    return " ".join(parts)


def value(rng, kind):
    if kind == "str":
        return text(rng, rng.randint(1, 4))
    if kind == "int":
        return rng.randint(0, 10**9)
    if kind == "float":
        return round(rng.random() * 1000, 3)
    if kind == "bool":
        return rng.random() < 0.5
    if kind == "arr_str":
        return [text(rng, 1) for _ in range(rng.randint(1, 4))]
    return rng.choice([rng.randint(0, 100), text(rng, 2), None, [1, 2, 3]])


def set_path(obj, path, v):
    keys = path.split(".")
    for k in keys[:-1]:
        obj = obj.setdefault(k, {})
        if not isinstance(obj, dict):
            return
    obj[keys[-1]] = v


def row(rng):
    event = {}
    for p in rng.sample(TYPED_STRINGS, rng.randint(18, 30)):
        set_path(event, p, text(rng, rng.randint(1, 12 if p in ("message", "process.cmd_line") else 3)))
    for p in rng.sample(TYPED_INTS, rng.randint(6, 13)):
        set_path(event, p, rng.randint(0, 65535))
    for p in TYPED_IPS:
        set_path(event, p, f"10.{rng.randint(0, 255)}.{rng.randint(0, 255)}.{rng.randint(1, 254)}" if rng.random() < 0.8 else None)
    set_path(event, "metadata.uid", str(uuid.UUID(int=rng.getrandbits(128))))
    for p, kind in rng.sample(DYNAMIC_PATHS, rng.randint(12, 36)):
        set_path(event, p, value(rng, kind))
    event["observables"] = [
        {"name": rng.choice(WORDS), "type_id": rng.randint(1, 30), "value": text(rng, 1)}
        for _ in range(rng.randint(1, 5))
    ]
    return event


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rows", type=int)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--surrogate-rate", type=float, default=0.0)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    for _ in range(args.rows):
        line = json.dumps({"event": row(rng)}, ensure_ascii=bool(rng.random() < 0.5), separators=(",", ":"))
        if args.surrogate_rate and rng.random() < args.surrogate_rate:
            cut = rng.choice(["\\ud83c", "\\udf1e x", "\\ud83c\\ud83c"])
            line = line[:-2] + ',"DetectedValues":["' + cut + '"]}}'
        print(line)


if __name__ == "__main__":
    main()
