#!/usr/bin/env bash
# dynamic-add-variant-sub.sh base|fix [symbol]: breakdown of samples under a symbol in the saved perf.data.
set -uo pipefail
PERF=$(ls /usr/lib/linux-tools/*/perf | head -1)
SYM=${2:-ColumnDynamic::addNewVariant}
D=/work/dav/run/prof-$1
$PERF script -i $D/perf.data -F ip,sym 2>/dev/null > $D/script.txt
python3 - "$D/script.txt" "$SYM" <<'EOF'
import sys, collections, re
path, sym = sys.argv[1], sys.argv[2]
stacks, cur = [], []
for line in open(path, errors="replace"):
    line = line.strip()
    if not line:
        if cur: stacks.append(cur); cur = []
        continue
    parts = line.split(None, 1)
    name = parts[1] if len(parts) > 1 else "?"
    name = re.sub(r"\(.*", "", name.replace("(anonymous namespace)", "{anon}"))
    cur.append(name)
if cur: stacks.append(cur)
tot = len(stacks); hit = 0
child = collections.Counter(); leaf = collections.Counter(); caller = collections.Counter(); incl = collections.Counter()
for s in stacks:
    idx = [i for i, f in enumerate(s) if sym in f]
    if not idx: continue
    hit += 1; top = max(idx)
    child[s[top - 1] if top > 0 else "<self>"] += 1
    leaf[s[0]] += 1
    caller[" <- ".join(s[top + 1: top + 3])] += 1
    for f in set(s[:top]): incl[f] += 1
print(f"{sym}: {hit}/{tot} = {100*hit/max(tot,1):.2f}%")
for title, c, n in (("child", child, 15), ("inclusive below", incl, 25), ("leaf", leaf, 15), ("caller", caller, 6)):
    print("--", title)
    for k, v in c.most_common(n): print(f"{100*v/hit:6.1f}%  {k[:150]}")
EOF
