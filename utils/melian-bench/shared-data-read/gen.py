#!/usr/bin/env python3
"""Synthetic OCSF-like JSON event generator for the shared-data read benchmark.

Writes one JSONEachRow file per insert. Rows carry the typed paths of the
production `event` column plus a skewed pick of 40-80 paths from a pool of
300 untyped paths (nested objects, arrays of objects, mixed value types), so
64 dynamic paths overflow and most untyped paths land in shared data.
Each row has a tenant key `k` and a timestamp spread over DAYS days, so a table
partitioned by day gets one large Wide part per day after OPTIMIZE FINAL.

Usage: gen.py OUT_DIR [NUM_FILES] [ROWS_PER_FILE] [SEED] [DAYS]
"""
import json
import os
import random
import sys
import uuid

OUT = sys.argv[1]
NUM_PARTS = int(sys.argv[2]) if len(sys.argv) > 2 else 80
ROWS = int(sys.argv[3]) if len(sys.argv) > 3 else 10500
SEED = int(sys.argv[4]) if len(sys.argv) > 4 else 42
DAYS = int(sys.argv[5]) if len(sys.argv) > 5 else 4

rng = random.Random(SEED)

WORDS = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
         "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
GROUPS = ["unmapped", "metadata.labels", "enrichments", "observables_ctx", "resources", "api",
          "actor.session", "device.agent", "network", "raw_extra"]


def word():
    return rng.choice(WORDS)


def text(lo, hi):
    n = rng.randint(lo, hi)
    out = []
    while sum(len(w) + 1 for w in out) < n:
        out.append(word())
    return " ".join(out)


def ip():
    return f"10.{rng.randint(0, 255)}.{rng.randint(0, 255)}.{rng.randint(1, 254)}"


# Pool of untyped paths. Each entry: (dotted path, value kind).
KINDS = ["str", "int", "float", "bool", "mixed", "arr_str", "arr_obj", "long_str"]
POOL = []
for i in range(300):
    group = GROUPS[i % len(GROUPS)]
    depth = 1 + (i % 3)
    parts = [group] + [f"{rng.choice(WORDS)}_{i % 7}" for _ in range(depth - 1)] + [f"f{i}"]
    POOL.append((".".join(parts), KINDS[i % len(KINDS)]))

# Zipf-like weights: a head of frequent paths (become dynamic paths), a long tail (shared data).
WEIGHTS = [1.0 / (1 + i) ** 0.7 for i in range(len(POOL))]


def value(kind):
    if kind == "str":
        return text(5, 30)
    if kind == "long_str":
        return text(40, 160)
    if kind == "int":
        return rng.randint(0, 10**9)
    if kind == "float":
        return round(rng.random() * 1000, 3)
    if kind == "bool":
        return rng.random() < 0.5
    if kind == "mixed":
        return rng.randint(0, 1000) if rng.random() < 0.5 else text(3, 15)
    if kind == "arr_str":
        return [word() for _ in range(rng.randint(1, 4))]
    if kind == "arr_obj":
        return [{"name": word(), "value": text(3, 20), "n": rng.randint(0, 100)} for _ in range(rng.randint(1, 3))]
    raise ValueError(kind)


def set_path(obj, path, v):
    keys = path.split(".")
    cur = obj
    for k in keys[:-1]:
        nxt = cur.get(k)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[k] = nxt
        cur = nxt
    cur[keys[-1]] = v


def typed(row_id):
    e = {}
    set_path(e, "class_uid", rng.choice([3002, 4001, 4003, 6003, 2004]))
    set_path(e, "class_name", rng.choice(["Authentication", "Network Activity", "DNS Activity", "API Activity"]))
    set_path(e, "category_uid", rng.randint(1, 6))
    set_path(e, "category_name", word())
    set_path(e, "activity_id", rng.randint(0, 6))
    set_path(e, "activity_name", word())
    set_path(e, "type_uid", rng.randint(100000, 999999))
    set_path(e, "type_name", text(5, 20))
    set_path(e, "severity", rng.choice(["Informational", "Low", "Medium", "High"]))
    set_path(e, "severity_id", rng.randint(0, 5))
    set_path(e, "status", rng.choice(["Success", "Failure"]))
    set_path(e, "status_id", rng.randint(0, 2))
    set_path(e, "message", text(20, 120))
    set_path(e, "metadata.uid", str(uuid.UUID(int=rng.getrandbits(128))))
    set_path(e, "metadata.product.name", rng.choice(["okta", "crowdstrike", "cloudtrail", "zscaler"]))
    set_path(e, "metadata.product.vendor_name", word())
    set_path(e, "metadata.tenant_uid", f"tenant-{rng.randint(1, 20)}")
    set_path(e, "metadata.event_code", str(rng.randint(1, 5000)))
    if rng.random() < 0.7:
        set_path(e, "src_endpoint.ip", ip())
        set_path(e, "src_endpoint.port", rng.randint(1, 65535))
        set_path(e, "src_endpoint.hostname", f"host-{rng.randint(1, 500)}")
    if rng.random() < 0.7:
        set_path(e, "dst_endpoint.ip", ip())
        set_path(e, "dst_endpoint.port", rng.randint(1, 65535))
        set_path(e, "dst_endpoint.hostname", f"srv-{rng.randint(1, 500)}")
    if rng.random() < 0.6:
        set_path(e, "actor.user.name", f"user{rng.randint(1, 2000)}")
        set_path(e, "actor.user.uid", str(rng.randint(1, 10**6)))
        set_path(e, "actor.user.type", word())
    if rng.random() < 0.5:
        set_path(e, "process.name", word() + ".exe")
        set_path(e, "process.pid", rng.randint(1, 65535))
        set_path(e, "process.cmd_line", text(20, 100))
        set_path(e, "process.file.path", "/usr/bin/" + word())
    if rng.random() < 0.4:
        set_path(e, "device.hostname", f"dev-{rng.randint(1, 900)}")
        set_path(e, "device.os.type", rng.choice(["linux", "windows", "macos"]))
        set_path(e, "device.type", word())
    if rng.random() < 0.3:
        set_path(e, "cloud.provider", rng.choice(["aws", "gcp", "azure"]))
        set_path(e, "cloud.region", rng.choice(["us-east-1", "eu-west-1"]))
        set_path(e, "cloud.account.uid", str(rng.randint(10**11, 10**12)))
    return e


def row(row_id):
    e = typed(row_id)
    for path, kind in rng.choices(POOL, weights=WEIGHTS, k=rng.randint(40, 80)):
        set_path(e, path, value(kind))
    day = rng.randrange(DAYS)
    ts = 1700006400 + day * 86400 + rng.randrange(86400)
    return {"k": e["metadata"]["tenant_uid"], "ts": ts, "id": row_id, "event": e}


os.makedirs(OUT, exist_ok=True)
rid = 0
for p in range(NUM_PARTS):
    with open(os.path.join(OUT, f"part_{p:03d}.jsonl"), "w") as f:
        for _ in range(ROWS):
            f.write(json.dumps(row(rid), separators=(",", ":")))
            f.write("\n")
            rid += 1
