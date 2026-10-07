#!/usr/bin/env python3
"""Synthetic OCSF-like log rows for the `event` JSON column.

Rows come from a fixed set of sources. Each source has its own key template (typed
paths plus source-specific dynamic paths, nested objects, arrays of objects) and emits
rows in runs, so consecutive rows usually share a key order, as in real ingestion.
~250 distinct paths overall, ~40-80 per row: more than 64 dynamic paths, so some
paths overflow into shared data.

Usage: gen.py ROWS SEED > out.jsonl
"""
import json
import random
import sys

TYPED = {
    "action": "s", "action_id": "i", "activity_id": "i", "activity_name": "s",
    "actor.process.file.name": "s", "actor.process.file.path": "s", "actor.process.name": "s",
    "actor.user.name": "s", "actor.user.type": "s", "actor.user.uid": "s", "auth_protocol": "s",
    "category_name": "s", "category_uid": "i", "class_name": "s", "class_uid": "i",
    "cloud.account.uid": "s", "cloud.provider": "s", "cloud.region": "s",
    "connection_info.direction_id": "i", "connection_info.protocol_name": "s",
    "device.hostname": "s", "device.os.type": "s", "device.type": "s", "disposition": "s",
    "disposition_id": "i", "dst_endpoint.hostname": "s", "dst_endpoint.ip": "ip",
    "dst_endpoint.port": "i", "file.name": "s", "file.path": "s", "finding.title": "s",
    "finding.uid": "s", "http_request.http_method": "s", "http_request.url.hostname": "s",
    "logon_type_id": "i", "message": "msg", "metadata.event_code": "s",
    "metadata.product.name": "s", "metadata.product.vendor_name": "s", "metadata.tenant_uid": "s",
    "metadata.uid": "uuid", "process.cmd_line": "s", "process.file.name": "s",
    "process.file.path": "s", "process.name": "s", "process.pid": "i", "query.hostname": "s",
    "query.type": "s", "service.name": "s", "severity": "s", "severity_id": "i",
    "src_endpoint.hostname": "s", "src_endpoint.ip": "ip", "src_endpoint.port": "i",
    "status": "s", "status_id": "i", "type_name": "s", "type_uid": "i", "user.name": "s",
    "user.uid": "s",
}
ALWAYS = ["metadata.uid", "metadata.product.name", "metadata.product.vendor_name",
          "metadata.tenant_uid", "class_uid", "class_name", "category_uid", "category_name",
          "activity_id", "type_uid", "severity_id", "severity", "message", "time"]

SECTIONS = ["unmapped", "metadata.labels", "enrichments", "observables_ext", "raw", "src_endpoint.ext",
            "dst_endpoint.ext", "actor.session", "api", "resources_ext"]
LEAVES = ["id", "name", "code", "count", "flag", "ratio", "tag", "ref", "kind", "zone",
          "region", "owner", "trace", "span", "bytes", "duration_ms", "agent", "rule"]
KINDS = ["s", "i", "b", "f", "as", "ao"]


def build_dynamic_pool(rng):
    pool = []
    for sec in SECTIONS:
        for leaf in LEAVES:
            for sub in ["", "detail.", "info."]:
                if rng.random() < 0.45:
                    pool.append((f"{sec}.{sub}{leaf}", rng.choice(KINDS)))
    return pool


def value(rng, kind, n):
    if kind == "s":
        return f"v{rng.randrange(5000)}-{n % 997}"
    if kind == "i":
        return rng.randrange(1 << 20)
    if kind == "b":
        return rng.random() < 0.5
    if kind == "f":
        return round(rng.random() * 1000, 3)
    if kind == "as":
        return [f"t{rng.randrange(300)}" for _ in range(rng.randrange(1, 4))]
    if kind == "ao":
        return [{"k": f"k{rng.randrange(50)}", "v": rng.randrange(1000)} for _ in range(rng.randrange(1, 3))]
    if kind == "ip":
        return f"10.{rng.randrange(256)}.{rng.randrange(256)}.{rng.randrange(256)}"
    if kind == "uuid":
        return "%08x-%04x-%04x-%04x-%012x" % (
            rng.getrandbits(32), rng.getrandbits(16), rng.getrandbits(16), rng.getrandbits(16), rng.getrandbits(48))
    if kind == "msg":
        return " ".join(f"w{rng.randrange(20000)}" for _ in range(rng.randrange(8, 20)))
    raise ValueError(kind)


def set_path(obj, path, v):
    parts = path.split(".")
    for p in parts[:-1]:
        obj = obj.setdefault(p, {})
    obj[parts[-1]] = v


def main():
    rows = int(sys.argv[1])
    rng = random.Random(int(sys.argv[2]))
    pool = build_dynamic_pool(rng)
    typed_rest = [p for p in TYPED if p not in ALWAYS]
    sources = []
    for _ in range(40):
        typed = ALWAYS + rng.sample(typed_rest, rng.randrange(12, 30))
        dyn = rng.sample(pool, rng.randrange(15, 40))
        optional = set(rng.sample(range(len(dyn)), max(1, len(dyn) // 8)))
        sources.append((typed, dyn, optional))
    out = sys.stdout
    n = 0
    while n < rows:
        typed, dyn, optional = sources[rng.randrange(len(sources))]
        for _ in range(min(rows - n, rng.randrange(1, 300))):
            ev = {}
            for p in typed:
                set_path(ev, p, value(rng, TYPED.get(p, "i"), n))
            for i, (p, kind) in enumerate(dyn):
                if i in optional and rng.random() < 0.3:
                    continue
                set_path(ev, p, value(rng, kind, n))
            out.write(json.dumps({"event": ev}, separators=(",", ":")))
            out.write("\n")
            n += 1


if __name__ == "__main__":
    main()
