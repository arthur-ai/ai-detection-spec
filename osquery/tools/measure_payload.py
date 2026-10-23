#!/usr/bin/env python3
"""Report the size of a payload, raw and compressed.

    tools/measure_payload.py /tmp/out.json
    tools/measure_payload.py /tmp/out.json --cap-kb 30

Enumeration trades payload for not being wrong about the catalog: the queries hold no
identifiers, so adding a signature costs zero bytes, but every machine reports its whole
inventory whether or not anything AI is on it. That trade only holds if the payload fits
whatever channel carries it, so the number is printed on every Scenarios run rather than
measured once on a developer machine and hoped about.

WHAT --cap-kb MEANS, AND WHAT IT DOES NOT. It is a budget YOU choose, because a value
channel's real limit is a property of your management stack and not of this repo. The 30KB
default is a convention this project adopted, not a documented platform limit -- see
queries/COST.md. Overrun whatever your actual limit is and the machine reports nothing,
which is indistinguishable from a machine with nothing on it.

The compressed figure is gzip then base64, because a channel that takes a single text value
is what you will be squeezing this into, and base64 is what that costs.
"""
import argparse
import base64
import collections
import gzip
import json
import sys

ap = argparse.ArgumentParser()
ap.add_argument("payload", help="osquery JSON, or a scan envelope with a findings key")
ap.add_argument("--cap-kb", type=int, default=30,
                help="your channel's value budget in KB (default 30, a convention)")
args = ap.parse_args()

doc = json.load(open(args.payload))
rows = doc["findings"] if isinstance(doc, dict) else doc
cap = args.cap_kb * 1024

raw = json.dumps(rows, separators=(",", ":")).encode()
packed = gzip.compress(raw, 9)
encoded = base64.b64encode(packed)
pct = len(encoded) / cap * 100

by_kind = collections.Counter(r["kind"] for r in rows)
print(f"rows       {len(rows)}")
print(f"raw        {len(raw) / 1024:.1f} KB")
print(f"gzipped    {len(packed) / 1024:.1f} KB")
print(f"+ base64   {len(encoded) / 1024:.1f} KB  ({pct:.0f}% of the {args.cap_kb}KB budget)")
print("by kind    " + ", ".join(f"{k}={v}" for k, v in sorted(by_kind.items(),
                                                              key=lambda x: -x[1])))

if pct > 100:
    sys.exit(f"FAIL: payload exceeds the {args.cap_kb}KB budget by {len(encoded) - cap} bytes")
if pct > 80:
    print(f"WARNING: {pct:.0f}% of the budget. Headroom is thin for a more loaded machine.")
