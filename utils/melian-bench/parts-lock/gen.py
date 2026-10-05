#!/usr/bin/env python3
"""Insert files for the parts-lock benchmark.

Writes `--files` JSONEachRow files of `--rows` rows. Every row of a file has the same
partition key `p`, chosen with a skew (low partitions are much more frequent), so that
each insert creates one part and a few partitions accumulate most of the parts, as in
the production tables. `event` reuses the synthetic OCSF-like generator of the
insert-collapse kit (typed paths of the production `event` column plus 40-80 dynamic
paths out of 250).
"""
import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "insert-collapse"))
from gen import event  # noqa: E402

PARTITIONS = 12


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--files", type=int, default=64)
    ap.add_argument("--rows", type=int, default=10500)
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rnd = random.Random(a.seed)
    rid = 0
    for f in range(a.files):
        p = min(int(rnd.expovariate(1 / 2.5)), PARTITIONS - 1)
        with open(os.path.join(a.out, f"ins_{f:03d}.jsonl"), "w") as out:
            for _ in range(a.rows):
                rid += 1
                row = {"ts": 1700000000 + rid // 7, "id": rid, "p": p, "event": event(rnd)}
                out.write(json.dumps(row, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
