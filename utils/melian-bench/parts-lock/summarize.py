#!/usr/bin/env python3
"""Median, min and max per label of the key=value result lines written by run.sh."""
import statistics
import sys
from collections import defaultdict

METRICS = ["prefill_wall", "prefill_cpu", "inserts", "inserts_per_s", "rows_per_s", "p50_ms", "p95_ms", "p99_ms", "max_ms", "load_cpu", "zk_txn", "zk_create", "zk_remove", "zk_exists", "parts_after"]

runs = defaultdict(list)
for line in open(sys.argv[1]):
    label, *kvs = line.split()
    d = dict(kv.split("=", 1) for kv in kvs if "=" in kv)
    runs[label].append(d)

labels = list(runs)
print("metric\t" + "\t".join(f"{l} median [min-max]" for l in labels) + ("\tchange" if len(labels) == 2 else ""))
for m in METRICS:
    row, medians = [m], []
    for l in labels:
        vals = [float(d[m]) for d in runs[l] if m in d]
        if not vals:
            row.append("-")
            medians.append(None)
            continue
        med = statistics.median(vals)
        medians.append(med)
        row.append(f"{med:.6g} [{min(vals):.6g}-{max(vals):.6g}] n={len(vals)}")
    if len(labels) == 2 and medians[0]:
        row.append(f"{100 * (medians[1] - medians[0]) / medians[0]:+.1f}%")
    print("\t".join(row))
