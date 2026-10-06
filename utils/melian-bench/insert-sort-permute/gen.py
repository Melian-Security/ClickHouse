#!/usr/bin/env python3
"""Insert files (events from ../json-key-lookup/gen.py) for a table ORDER BY (org_id, event_time, id) with the `event` JSON column.

Every file is one INSERT of FILE_ROWS rows of one org_id and one week, so one block and one
partition per insert. event_time is spread over FILE_ROWS / 2 seconds (about two rows per second,
so ties are broken by the random id), and the rows arrive in random order. `sort.sh` writes the
same files sorted by the table's ORDER BY.

Usage: gen.py ROWS SEED FILE_ROWS OUT_DIR
"""
import datetime
import json
import os
import random
import sys

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "event_gen", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "json-key-lookup", "gen.py"))
event_gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(event_gen)


class Capture:
    def __init__(self):
        self.lines = []
        self.buf = ""

    def write(self, s):
        self.buf += s
        if s == "\n":
            self.lines.append(self.buf)
            self.buf = ""


def main():
    rows, seed, file_rows, out_dir = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    cap = Capture()
    saved = sys.stdout, sys.argv
    sys.stdout, sys.argv = cap, ["event_gen.py", str(rows), str(seed)]
    try:
        event_gen.main()
    finally:
        sys.stdout, sys.argv = saved
    rng = random.Random(seed + 1)
    os.makedirs(out_dir, exist_ok=True)
    # A Tuesday, so a window of a few hours never crosses a week boundary.
    base = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
    for f, start in enumerate(range(0, rows, file_rows)):
        org = f"org-{f % 7}"
        t0 = base + datetime.timedelta(days=f % 4, hours=rng.randrange(6))
        span = max(1, file_rows // 2)
        out = []
        for line in cap.lines[start:start + file_rows]:
            ev = json.loads(line)["event"]
            t = t0 + datetime.timedelta(seconds=rng.randrange(span))
            uid = "%08x-%04x-%04x-%04x-%012x" % (
                rng.getrandbits(32), rng.getrandbits(16), rng.getrandbits(16), rng.getrandbits(16), rng.getrandbits(48))
            out.append(json.dumps({"org_id": org, "event_time": t.strftime("%Y-%m-%d %H:%M:%S"), "id": uid,
                                   "event": ev}, separators=(",", ":")))
        rng.shuffle(out)
        with open(os.path.join(out_dir, f"insert_{f:03d}.jsonl"), "w") as fh:
            fh.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
