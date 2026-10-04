#!/usr/bin/env python3
"""Synthetic OCSF-like log rows for JSON-type parsing benchmarks.

Each output line is one JSON object (JSONAsObject input). Rows carry ~40-80 leaf paths drawn from
~250 distinct paths: a part of them match the typed paths of the `event` column, the rest overflow
the 64 dynamic paths into shared data. Objects are nested 2-5 levels deep, some keys are arrays of
objects, and leaf types vary per path. Fully deterministic for a given seed.

Usage: gen.py ROWS [SEED] > data.jsonl
"""

import json
import random
import sys

TYPED_STRING = [
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
TYPED_INT = [
    "action_id", "activity_id", "category_uid", "class_uid", "connection_info.direction_id",
    "dst_endpoint.port", "logon_type_id", "process.pid", "severity_id", "src_endpoint.port", "status_id",
    "type_uid", "disposition_id",
]
TYPED_IP = ["dst_endpoint.ip", "src_endpoint.ip"]

PREFIXES = [
    "unmapped", "unmapped.raw_event", "unmapped.vendor_specific_details", "enrichments_context",
    "observables_context", "actor.session", "actor.authorizations_context", "device.network_interfaces_info",
    "metadata.extension_attributes", "api.request_parameters", "api.response_elements", "resources_context",
    "evidences_artifacts", "web_resources_details", "cloud.organization_details",
]
LEAVES = [
    "identifier", "display_name", "created_timestamp", "modified_timestamp", "description_text",
    "correlation_identifier", "source_reference", "classification", "confidence_score", "is_enabled",
    "region_name", "original_value", "normalized_value", "lookup_result", "external_reference_url",
    "count_of_items", "duration_milliseconds",
]


def build_untyped_paths(rng):
    paths = []
    for p in PREFIXES:
        for leaf in rng.sample(LEAVES, 12):
            paths.append(f"{p}.{leaf}")
    return paths  # 180 paths


def set_path(obj, path, value):
    parts = path.split(".")
    cur = obj
    for part in parts[:-1]:
        nxt = cur.get(part)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[part] = nxt
        cur = nxt
    cur[parts[-1]] = value


def rand_str(rng, n):
    return "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789-_/") for _ in range(n))


def leaf_value(rng, path, kind):
    if kind == 0:
        return rand_str(rng, rng.randint(4, 24))
    if kind == 1:
        return rng.randint(0, 1 << 40)
    if kind == 2:
        return rng.random() * 1000
    if kind == 3:
        return rng.random() < 0.5
    return [rand_str(rng, 6) for _ in range(rng.randint(1, 3))]


def main():
    rows = int(sys.argv[1])
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 42
    rng = random.Random(seed)
    untyped = build_untyped_paths(rng)
    kinds = {p: rng.randint(0, 4) for p in untyped}
    out = sys.stdout
    for i in range(rows):
        row = {}
        for p in rng.sample(TYPED_STRING, rng.randint(14, 24)):
            set_path(row, p, rand_str(rng, rng.randint(6, 40)))
        for p in rng.sample(TYPED_INT, rng.randint(5, 9)):
            set_path(row, p, rng.randint(0, 100000))
        for p in TYPED_IP:
            set_path(row, p, f"10.{rng.randint(0, 255)}.{rng.randint(0, 255)}.{rng.randint(0, 255)}")
        set_path(row, "metadata.uid", "%08x-%04x-4%03x-8%03x-%012x" % (
            rng.getrandbits(32), rng.getrandbits(16), rng.getrandbits(12), rng.getrandbits(12), rng.getrandbits(48)))
        for p in rng.sample(untyped, rng.randint(15, 40)):
            # Mixed types per path: mostly the path's own kind, sometimes another.
            kind = kinds[p] if rng.random() < 0.9 else rng.randint(0, 4)
            set_path(row, p, leaf_value(rng, p, kind))
        if rng.random() < 0.5:
            row["observables"] = [
                {"name": rand_str(rng, 10), "type_id": rng.randint(1, 30), "value": rand_str(rng, 16)}
                for _ in range(rng.randint(1, 4))
            ]
        out.write(json.dumps(row, separators=(",", ":")))
        out.write("\n")


if __name__ == "__main__":
    main()
