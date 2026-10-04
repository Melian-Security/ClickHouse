#!/usr/bin/env python3
"""Synthetic OCSF-like log rows for the `event` JSON column (JSONEachRow, one {"event": {...}} per line).

Each row carries the production typed paths plus 20-45 dynamic paths (~55-80 leaf paths per row in total) drawn from a pool of 240,
nested objects, arrays of objects and mixed value types, so dynamic paths overflow
max_dynamic_paths=64 into shared data. Deterministic for a given seed.
Usage: gen.py ROWS [SEED] > rows.ndjson
"""
import json
import random
import sys
import uuid

rows = int(sys.argv[1])
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 42
rnd = random.Random(seed)

GROUPS = ["unmapped", "raw_extra", "enrichments", "observables_meta", "vendor", "ext", "labels", "attrs"]
SUB = ["src", "dst", "net", "proc", "file", "auth", "geo", "tls", "http", "dns"]
LEAF = ["id", "name", "value", "count", "flag", "score", "ts", "tag", "kind", "ref", "uid", "path"]
POOL = [(g, s, l) for g in GROUPS for s in SUB for l in rnd.sample(LEAF, 3)]


def rstr(n):
    return "".join(rnd.choice("abcdefghijklmnopqrstuvwxyz0123456789-_.") for _ in range(n))


def rval(kind):
    if kind == 0:
        return rnd.randint(0, 10**9)
    if kind == 1:
        return rstr(rnd.randint(3, 12))
    if kind == 2:
        return rnd.random() * 1000
    if kind == 3:
        return rnd.random() < 0.5
    return [rstr(6) for _ in range(rnd.randint(1, 3))]


def setp(d, parts, v):
    for p in parts[:-1]:
        d = d.setdefault(p, {})
    d[parts[-1]] = v


def ip():
    return ".".join(str(rnd.randint(1, 254)) for _ in range(4))


out = sys.stdout
for _ in range(rows):
    e = {
        "action": rnd.choice(["Allowed", "Denied", "Unknown"]),
        "action_id": rnd.randint(0, 3),
        "activity_id": rnd.randint(0, 6),
        "activity_name": rnd.choice(["Logon", "Open", "Traffic", "Query"]),
        "actor": {
            "process": {"name": rstr(8), "file": {"name": rstr(8) + ".exe", "path": "/usr/bin/" + rstr(10)}},
            "user": {"name": rstr(7), "type": "User", "uid": rstr(12)},
        },
        "auth_protocol": "Kerberos",
        "category_name": "Network Activity",
        "category_uid": 4,
        "class_name": "Network Activity",
        "class_uid": 4001,
        "cloud": {"account": {"uid": str(rnd.randint(10**11, 10**12))}, "provider": "AWS", "region": "us-east-1"},
        "connection_info": {"direction_id": rnd.randint(0, 2), "protocol_name": rnd.choice(["tcp", "udp"])},
        "device": {"hostname": "host-" + rstr(6), "os": {"type": "Linux"}, "type": "Server"},
        "disposition": "Allowed",
        "disposition_id": 1,
        "dst_endpoint": {"hostname": rstr(10), "ip": ip(), "port": rnd.randint(1, 65535)},
        "http_request": {"http_method": "GET", "url": {"hostname": rstr(12) + ".com"}},
        "message": rstr(rnd.randint(20, 80)),
        "metadata": {
            "event_code": str(rnd.randint(1000, 9999)),
            "product": {"name": "Prod", "vendor_name": "Vendor"},
            "tenant_uid": rstr(8),
            "uid": str(uuid.UUID(int=rnd.getrandbits(128))),
        },
        "severity": "Informational",
        "severity_id": 1,
        "src_endpoint": {"hostname": rstr(10), "ip": ip(), "port": rnd.randint(1, 65535)},
        "status": "Success",
        "status_id": 1,
        "type_name": "Traffic",
        "type_uid": 400101,
        "time": rnd.randint(1_700_000_000_000, 1_800_000_000_000),
    }
    for g, s, l in rnd.sample(POOL, rnd.randint(20, 45)):
        setp(e, [g, s, l], rval(rnd.randint(0, 4)))
    e["observables"] = [
        {"name": rstr(6), "type_id": rnd.randint(1, 30), "value": rstr(10)} for _ in range(rnd.randint(1, 4))
    ]
    out.write(json.dumps({"event": e}, separators=(",", ":")) + "\n")
