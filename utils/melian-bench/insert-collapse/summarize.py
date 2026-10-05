#!/usr/bin/env python3
"""Summarize bench.sh result lines: median/min/max of insert CPU, collapse and wall time
per (binary, dataset, optimize_on_insert), the fix-vs-base change, and hash agreement."""
import statistics
import sys
from collections import defaultdict

runs = defaultdict(list)
hashes = defaultdict(set)
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) < 9:
        continue
    binary, ds, _ = f[0].split("/")
    ooi = f[1]
    cpu, collapse, wall = float(f[3]), float(f[4]), float(f[5])
    runs[(binary, ds, ooi)].append((cpu, collapse, wall))
    hashes[(ds, ooi)].add(tuple(f[6:9]))


def stat(values):
    return statistics.median(values), min(values), max(values)


for ds in ("uniq", "dup"):
    for ooi in ("ooi=1", "ooi=0"):
        print(f"== {ds} {ooi}  (hash sets across binaries/runs: {len(hashes[(ds, ooi)])}: {sorted(hashes[(ds, ooi)])})")
        meds = {}
        for binary in ("base", "fix"):
            r = runs.get((binary, ds, ooi), [])
            if not r:
                continue
            out = []
            for idx, name in enumerate(("cpu_ms", "collapse_ms", "wall_ms")):
                med, lo, hi = stat([x[idx] for x in r])
                meds[(binary, name)] = med
                out.append(f"{name} {med:.0f} [{lo:.0f}..{hi:.0f}]")
            print(f"  {binary:4} n={len(r)}  " + "  ".join(out))
        for name in ("cpu_ms", "collapse_ms", "wall_ms"):
            b, x = meds.get(("base", name)), meds.get(("fix", name))
            if b:
                print(f"  {name} change: {100 * (x - b) / b:+.1f}%")
