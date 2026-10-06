#!/usr/bin/env python3
"""Summarizes ab.sh results: per (binary, mode) median/min/max of insert CPU and hash CPU."""
import statistics
import sys
from collections import defaultdict

groups = defaultdict(list)
checks = defaultdict(set)
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) < 11:
        continue
    label, mode, n, cpu, hash_ms, samples, wall, hashes = f[:8]
    key = (label.split("/")[0], mode)
    groups[key].append((int(n), float(cpu), float(hash_ms), int(samples), float(wall), int(hashes)))
    checks[key].add(" ".join(f[8:]))


def fmt(xs):
    return f"median {statistics.median(xs):9.1f}  min {min(xs):9.1f}  max {max(xs):9.1f}"


for key in sorted(groups):
    rows = groups[key]
    n = rows[0][0]
    print(f"{key[0]:5s} {key[1]:8s} runs={len(rows)} inserts={n}")
    print(f"   insert CPU ms/insert  {fmt([r[1] / n for r in rows])}")
    print(f"   hash CPU ms/insert    {fmt([r[2] / n for r in rows])}")
    print(f"   hash share of CPU %   {fmt([100 * r[2] / r[3] for r in rows if r[3]])}")
    print(f"   wall ms/insert        {fmt([r[4] / n for r in rows])}")
    print(f"   hash computations     {sorted({r[5] for r in rows})}")
    for c in sorted(checks[key]):
        print(f"   {c}")

base = groups.get(("base", "dedup"))
for other in (("fix", "dedup"), ("base", "nodedup"), ("base", "token")):
    if base and other in groups:
        b = statistics.median([r[1] / r[0] for r in base])
        o = statistics.median([r[1] / r[0] for r in groups[other]])
        bh = statistics.median([r[2] / r[0] for r in base])
        oh = statistics.median([r[2] / r[0] for r in groups[other]])
        print(f"{other[0]}/{other[1]} vs base/dedup: insert CPU {100 * (o - b) / b:+.2f}%  hash CPU {oh - bh:+.1f} ms/insert"
              + (f" ({100 * (oh - bh) / bh:+.1f}%)" if bh else ""))
