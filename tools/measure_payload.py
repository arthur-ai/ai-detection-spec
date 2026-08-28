#!/usr/bin/env python3
"""Report the framed Extension Attribute size for a set of findings.

    tools/measure_payload.py /tmp/out.json

The EA carries arthur1.<base64(gzip(json))> and Jamf gives it roughly 30KB. Overrun and
the Mac reports nothing, which is indistinguishable from a Mac with nothing on it -- so
this number decides whether a device is seen, and it is worth printing on every run
rather than measuring once on a developer machine and hoping.
"""
import base64
import collections
import gzip
import json
import sys

CAP = 30 * 1024

doc = json.load(open(sys.argv[1]))
rows = doc["findings"] if isinstance(doc, dict) else doc
raw = json.dumps(rows, separators=(",", ":")).encode()
framed = b"arthur1." + base64.b64encode(gzip.compress(raw, 9))
pct = len(framed) / CAP * 100

by_kind = collections.Counter(r["kind"] for r in rows)
print(f"rows      {len(rows)}")
print(f"raw       {len(raw) / 1024:.1f} KB")
print(f"framed EA {len(framed) / 1024:.1f} KB  ({pct:.0f}% of the {CAP // 1024}KB cap)")
print("by kind   " + ", ".join(f"{k}={v}" for k, v in sorted(by_kind.items(), key=lambda x: -x[1])))

if pct > 100:
    sys.exit(f"FAIL: payload exceeds the EA cap by {len(framed) - CAP} bytes")
if pct > 80:
    print(f"WARNING: {pct:.0f}% of the cap. Headroom is thin for a more loaded machine.")
