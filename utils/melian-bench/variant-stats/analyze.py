#!/usr/bin/env python3
"""Split merge-thread CPU samples (system.trace_log stacks, root first, ';'-joined, TSV with count) by frame.

Usage: analyze.py stacks.tsv
"""
import re
import sys
from collections import Counter

stacks = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    stack, _, n = line.rstrip("\n").rpartition("\t")
    frames = stack.split(";")
    if any("MergeTask" in f for f in frames):
        stacks.append((frames, int(n)))
total = sum(n for _, n in stacks)
print(f"merge samples: {total}")


def incl(pred):
    return sum(n for fr, n in stacks if any(pred(f) for f in fr))


def pct(x):
    return f"{100.0 * x / total:5.1f}%"


for name, pat in [
    ("writeColumn", r"MergeTreeDataPartWriterWide::writeColumn"),
    ("SerializationObject::serializeBinaryBulkWithMultipleStreams", r"SerializationObject::serializeBinaryBulkWithMultipleStreams"),
    ("SerializationObjectSharedData::serializeBinaryBulkWithMultipleStreams", r"SerializationObjectSharedData::serializeBinaryBulkWithMultipleStreams"),
    ("SerializationDynamic::serializeBinaryBulkWithMultipleStreams*", r"SerializationDynamic::serializeBinaryBulkWithMultipleStreams"),
    ("SerializationDynamic::serializeBinaryBulkStatePrefix", r"SerializationDynamic::serializeBinaryBulkStatePrefix"),
    ("SerializationDynamic::serializeBinaryBulkStateSuffix", r"SerializationDynamic::serializeBinaryBulkStateSuffix"),
    ("SerializationVariant::...UpdateVariantStatistics", r"UpdateVariantStatistics"),
    ("chooseDynamicStructureForMerge", r"chooseDynamicStructureForMerge"),
    ("takeOrCalculateStatisticsFrom/getOrCalculateStatistics", r"CalculateStatistics"),
]:
    print(f"{pct(incl(lambda f, p=pat: re.search(p, f)))}  {name}")


def classify_child(child):
    if child is None:
        return "self"
    if re.search(r"hash_table|unordered_map|__murmur|CityHash|std::hash|StringHashForHeterogeneousLookup|HashTable|HashMap", child):
        return "statistics hash map"
    if re.search(r"operator new|operator delete|malloc|free|je_|basic_string", child):
        return "allocation/string"
    if re.search(r"__policy_func|function<|__func", child):
        return "stream getter std::function"
    if re.search(r"serializeBinaryBulk|serializeBinary|Serialization", child):
        return "nested serialization (data)"
    if re.search(r"WriteBuffer|writeVarUInt|writeBinary|memcpy|Compressed", child):
        return "write to stream"
    if re.search(r"addVariantElementToPath|SubstreamPath|Substream|push_back|pop_back|vector", child):
        return "substream path"
    return "other: " + child[:110]


def split(target):
    c = Counter()
    for fr, n in stacks:
        idx = [i for i, f in enumerate(fr) if re.search(target, f)]
        if not idx:
            continue
        i = idx[0]  # outermost occurrence: inclusive share counted once
        c[classify_child(fr[i + 1] if i + 1 < len(fr) else None)] += n
    return c


for target in [r"UpdateVariantStatistics", r"SerializationObject::serializeBinaryBulkWithMultipleStreams", r"SerializationDynamic::serializeBinaryBulkWithMultipleStreamsAndCount"]:
    c = split(target)
    print(f"\n== children of {target} (outermost frame), share of all merge samples")
    for k, v in c.most_common(15):
        print(f"{pct(v)}  {k}")

# Leaf-level view: samples whose leaf is a hash-map/statistics frame and whose stack contains a statistics site.
print("\n== self frames under UpdateVariantStatistics (leaf), top 15")
c = Counter()
for fr, n in stacks:
    if any("UpdateVariantStatistics" in f for f in fr):
        c[fr[-1][:120]] += n
for k, v in c.most_common(15):
    print(f"{pct(v)}  {k}")

print("\n== top self frames overall")
c = Counter()
for fr, n in stacks:
    c[fr[-1][:120]] += n
for k, v in c.most_common(20):
    print(f"{pct(v)}  {k}")
