#!/usr/bin/env python3
"""Median / min / max of insert and merge CPU per label from a run.sh results file."""
import statistics
import sys

rows = {}
hashes = {}
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) < 9:
        continue
    rows.setdefault(f[0], []).append((float(f[1]), float(f[2])))
    hashes.setdefault(f[0], set()).add((f[5], f[7], f[8]))

med = {}
for label, vals in rows.items():
    for idx, name in ((0, "insert_cpu_s"), (1, "merge_cpu_s")):
        xs = [v[idx] for v in vals]
        med[(label, name)] = statistics.median(xs)
        print(f"{label} {name} n={len(xs)} median={statistics.median(xs):.2f} min={min(xs):.2f} max={max(xs):.2f}")
    print(f"{label} rows/hash/paths_hash: {sorted(hashes[label])}")
labels = sorted(rows)
if len(labels) == 2:
    a, b = labels
    for name in ("insert_cpu_s", "merge_cpu_s"):
        print(f"{name} {b} vs {a}: {100 * (med[(b, name)] / med[(a, name)] - 1):+.1f}%")
