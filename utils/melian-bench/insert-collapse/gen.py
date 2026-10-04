#!/usr/bin/env python3
"""Synthetic OCSF-like JSON events for the insert-collapse benchmark.

Writes `files` JSONEachRow files of `rows` rows each. Each row has `ts`, `id` and an
`event` object with the typed paths of the production `event` column plus ~40-80
dynamic paths drawn from a pool of 250 (nested objects, arrays of objects, mixed
types), enough to overflow 64 dynamic paths into shared data.

`--dup-ratio` makes that fraction of rows repeat the sorting key of an earlier row
of the same file, so that the ReplacingMergeTree insert-time merge drops rows.
"""
import argparse
import json
import os
import random
import uuid

TYPED_STR = ["action", "activity_name", "actor.process.file.name", "actor.process.file.path", "actor.process.name",
             "actor.user.name", "actor.user.type", "actor.user.uid", "auth_protocol", "category_name", "class_name",
             "cloud.account.uid", "cloud.provider", "cloud.region", "connection_info.protocol_name", "device.hostname",
             "device.os.type", "device.type", "disposition", "dst_endpoint.hostname", "file.name", "file.path",
             "finding.title", "finding.uid", "http_request.http_method", "http_request.url.hostname", "message",
             "metadata.event_code", "metadata.product.name", "metadata.product.vendor_name", "metadata.tenant_uid",
             "process.cmd_line", "process.file.name", "process.file.path", "process.name", "query.hostname",
             "query.type", "service.name", "severity", "src_endpoint.hostname", "status", "type_name", "user.name",
             "user.uid"]
TYPED_INT = ["action_id", "activity_id", "category_uid", "class_uid", "connection_info.direction_id", "disposition_id",
             "dst_endpoint.port", "logon_type_id", "process.pid", "severity_id", "src_endpoint.port", "status_id",
             "type_uid"]

KINDS = ["s", "i", "f", "b", "arr", "obj"]
POOL = [(f"unmapped.g{g}.f{k}" if k % 3 else f"raw.grp{g}.attr_{k}", KINDS[(g + k) % len(KINDS)])
        for g in range(25) for k in range(10)]


def set_path(obj, path, value):
    parts = path.split(".")
    for p in parts[:-1]:
        obj = obj.setdefault(p, {})
    obj[parts[-1]] = value


def value(kind, rnd):
    if kind == "s":
        return "v" + str(rnd.randrange(5000)) + "-" + "x" * rnd.randrange(4, 40)
    if kind == "i":
        return rnd.randrange(1 << 31)
    if kind == "f":
        return rnd.random() * 1000
    if kind == "b":
        return rnd.random() < 0.5
    if kind == "arr":
        return [{"name": "n" + str(rnd.randrange(100)), "value": rnd.randrange(1000), "tags": ["a", "b"][: rnd.randrange(3)]}
                for _ in range(rnd.randrange(1, 4))]
    return {"k1": rnd.randrange(100), "k2": "s" + str(rnd.randrange(100))}


def event(rnd):
    e = {}
    for p in TYPED_STR:
        if rnd.random() < 0.7:
            tail = "-" + "y" * rnd.randrange(0, 400) if p in ("message", "process.cmd_line") else ""
            set_path(e, p, "val-" + str(rnd.randrange(2000)) + tail)
    for p in TYPED_INT:
        if rnd.random() < 0.7:
            set_path(e, p, rnd.randrange(65536))
    set_path(e, "metadata.uid", str(uuid.UUID(int=rnd.getrandbits(128))))
    for ip in ("src_endpoint.ip", "dst_endpoint.ip"):
        set_path(e, ip, ".".join(str(rnd.randrange(256)) for _ in range(4)))
    # Skewed choice: low pool indexes are frequent, so many paths compete for 64 dynamic slots.
    n = rnd.randrange(40, 81)
    chosen = set()
    while len(chosen) < n:
        chosen.add(min(int(rnd.expovariate(1 / 90)), len(POOL) - 1))
    for i in chosen:
        path, kind = POOL[i]
        set_path(e, path, value(kind, rnd))
    return e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--files", type=int, default=10)
    ap.add_argument("--rows", type=int, default=10500)
    ap.add_argument("--dup-ratio", type=float, default=0.0)
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rnd = random.Random(a.seed)
    rid = 0
    for f in range(a.files):
        keys = []
        with open(os.path.join(a.out, f"part_{f:03d}.jsonl"), "w") as out:
            for _ in range(a.rows):
                if keys and rnd.random() < a.dup_ratio:
                    key = rnd.choice(keys)
                else:
                    rid += 1
                    key = (1700000000 + rid // 7, rid)
                    keys.append(key)
                row = {"ts": key[0], "id": key[1], "event": event(rnd)}
                out.write(json.dumps(row, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
