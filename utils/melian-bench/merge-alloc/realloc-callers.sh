#!/usr/bin/env bash
# realloc-callers.sh PERF_DATA [REGEX]: merge-thread (MergeMutate) samples of a `perf record -g` file whose stack
# contains REGEX (default do_rallocx), grouped by the first 3 frames above the allocator. PERF: perf binary.
"${PERF:-perf}" script -i "$1" --comms MergeMutate -F ip,sym 2>/dev/null | python3 -c '
import sys, re, collections
pat = re.compile(sys.argv[1])
skip = re.compile(r"ralloc|^Allocator|PODArrayBase|^extent|^arena|^large|^je_|^tcache|^pages|^ehooks|^emap|^memcpy|^__memcpy|^\[unknown\]|^rtree")
total = 0; hit = collections.Counter(); n = 0
stack = []
def flush():
    global total, n
    if not stack: return
    total += 1
    if any(pat.search(f) for f in stack[:12]):
        n += 1
        k = [f for f in stack if not skip.search(f)][:3]
        hit[" <- ".join(re.sub(r"\(.*", "", x) for x in k)] += 1
for line in sys.stdin:
    line = line.strip()
    if not line:
        flush(); stack = []
    else:
        stack.append(line.split(" ", 1)[1] if " " in line else line)
flush()
print("total", total, "matching", n, "%.2f%%" % (100.0 * n / max(total, 1)))
for k, c in hit.most_common(25):
    print("%6d %5.2f%% %s" % (c, 100.0 * c / total, k[:230]))
' "${2:-do_rallocx}"
