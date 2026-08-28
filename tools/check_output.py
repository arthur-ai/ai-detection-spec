#!/usr/bin/env python3
"""Assert every query returned parseable JSON.

A query that errors out returns no rows, and no rows is exactly what a clean machine
returns. Without this check a broken query and a machine with nothing installed are
the same observation.
"""
import json
import sys

rows = json.load(open(sys.argv[1]))
broken = [r["query"] for r in rows if r["rows"] == -1]
if broken:
    sys.exit("produced no valid JSON: " + ", ".join(broken))
print(f"all {len(rows)} queries returned parseable output")
