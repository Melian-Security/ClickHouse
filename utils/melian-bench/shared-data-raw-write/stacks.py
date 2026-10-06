#!/usr/bin/env python3
"""Reads `perf script -F comm,tid,ip,sym` output on stdin; for samples of the merge thread containing a frame
matching ANCHOR, classifies them by the first matching category among the frames above (leaf side of) the anchor."""
import collections, re, sys
anchor = sys.argv[1]
cats = [(c, re.compile(p)) for c, p in [
    ("zstd", r"ZSTD_"), ("array", r"SerializationArray::"), ("object", r"SerializationObject::|ColumnObject::insert|ColumnObject::tryToAdd"),
    ("getFileName", r"getFileNameForStream|getNameForSubstreamPath"), ("mark_getter", r"getCurrentMarksForColumn|MarkInCompressedFile"),
    ("tryCopy", r"tryCopyValues"), ("variant_ser", r"SerializationVariant::"), ("string_ser", r"SerializationString::"),
    ("dyn_deser", r"SerializationDynamic::deserializeBinary|addNewVariant|getVariantSerialization"),
    ("defaults", r"insertManyDefaults"), ("alloc", r"je_|malloc|free|Allocator|MemoryTracker"),
]]
leafs = collections.Counter(); total = 0; hit = 0; c = collections.Counter(); comm_count = collections.Counter(); samples = []
cur = []; head = None
def flush():
    global total, hit
    if head is None: return
    samples.append((head, cur[:]))
for line in sys.stdin:
    if not line.strip():
        flush(); head = None; cur = []; continue
    if not line.startswith((" ", "\t")):
        flush(); head = line.split()[0]; cur = []; continue
    parts = line.strip().split(None, 1)
    cur.append(parts[1] if len(parts) > 1 else "?")
flush()
for h, _ in samples: comm_count[h] += 1
merge_comm = max((k for k in comm_count if k not in ("AsyncLogger",)), key=lambda k: comm_count[k])
for h, frames in samples:
    if h != merge_comm: continue
    total += 1
    idx = next((i for i, f in enumerate(frames) if anchor in f), None)
    if idx is None: continue
    hit += 1
    inner = frames[:idx]
    got = "self/other"
    for name, rx in cats:
        if any(rx.search(f) for f in inner): got = name; break
    c[got] += 1
    if got == "self/other":
        leafs[(frames[0][:90], frames[1][:60] if len(frames) > 1 else "")] += 1
print(f"merge thread {merge_comm}: {total} samples; {anchor}: {100*hit/max(total,1):.2f}%")
for k, v in c.most_common(): print(f"{100*v/max(total,1):6.2f}%  {k}")
print("-- self/other leafs")
for k, v in leafs.most_common(15): print(f"{100*v/max(total,1):6.2f}%  {k[0]}  <- {k[1]}")
