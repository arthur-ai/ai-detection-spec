#!/usr/bin/env python3
"""Execute every query in the osquery pack and assert it actually runs.

The pack is a SEPARATE ARTIFACT from the composed dist/discovery-<platform>.sql files,
built by a different code path,
and until now nothing ran it. It shipped with four of its five queries returning zero
rows: the builder flattened SQL to one line without stripping `--` comments, so each
query commented itself out after its first branch.

Nothing errored. Zero rows is exactly what a clean Mac returns, so a customer deploying
the pack would have concluded they had no AI tooling. Testing the composed artifact told us
nothing about it, because they are built differently.

Rows are not asserted -- a runner legitimately has none of some kinds -- but a query that
errors, or that returns zero rows for EVERY query, is a build defect rather than a clean
machine.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
import os
import platform as _platform

import build
import measure

# $OSQI, then measure.py's candidate list: one list, not a copy per tool.
OSQI = os.environ.get("OSQI") or measure.osqueryi()

# THE PACK CARRIES EVERY PLATFORM'S QUERIES -- that is what osqueryd's per-query
# `platform` field is for -- so running all of them here fails on whichever platform this
# is not. `apps` on Linux and `packages-linux` on macOS both die on a missing table, and
# the all-zero-rows check below would then call a correct pack a build defect.
PLATFORM = build.HOST_PLATFORM
if PLATFORM is None:
    sys.exit(f"check_pack: unsupported platform {_platform.system()}")

pack = json.loads((ROOT / "dist" / "ai-detection-spec.conf").read_text())
COLUMNS = ["kind", "id", "ver", "loc", "extra", "perms"]
failed, total_rows = False, 0

skipped = []
for name, spec in sorted(pack["queries"].items()):
    if not build.runs_on(spec.get("platform"), PLATFORM):
        skipped.append(f"{name}({spec.get('platform')})")
        continue
    sql = spec["query"]
    if "--" in sql:
        print(f"FAIL: {name} still contains a -- comment after flattening, which "
              f"comments out the rest of the one-line query")
        failed = True
        continue
    # A timeout, because the pack now carries the container query and docker_images has
    # no timeout of its own. Against a daemon that accepts and never answers it runs
    # indefinitely -- this check would hang the build rather than fail it. Point it at a
    # socket path that cannot exist so the pack test never depends on local Docker state;
    # measure.py says where that flag exists. On stdin, as measure.py runs a query.
    try:
        proc = subprocess.run([OSQI, *measure.DOCKER_FLAGS, "--json"], input=sql + "\n",
                              capture_output=True, text=True, encoding="utf-8", timeout=30)
    except subprocess.TimeoutExpired:
        print(f"FAIL: {name} did not finish in 30s")
        failed = True
        continue
    # The COLUMN NAMES, not just the row count. The pack shipped a browser query returning
    # 74 correctly-counted rows keyed 'ext' and "permissions || CASE WHEN ..." because its
    # first UNION ALL arm carried no aliases -- well-formed only inside a composed artifact,
    # where apps.sql donated the names. Counting rows passed it every time.
    try:
        parsed = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        parsed = None
    if parsed:
        got = set(parsed[0])
        if got != set(COLUMNS):
            print(f"FAIL: {name} returns columns {sorted(got)}, not the six-column "
                  f"contract. Alias the first UNION ALL arm.")
            failed = True
            continue
    try:
        rows = len(json.loads(proc.stdout))
    except (json.JSONDecodeError, ValueError):
        err = (proc.stderr.strip() or proc.stdout.strip())[:160]
        print(f"FAIL: {name} did not return JSON: {err}")
        failed = True
        continue
    total_rows += rows
    print(f"  {name:14} {rows:5} rows")

if not failed and total_rows == 0:
    print("FAIL: every pack query returned zero rows. On a machine with any software "
          "installed that is a build defect, not a clean machine.")
    failed = True

# NAME WHAT WAS SKIPPED. A silently shortened run is how a platform's whole set of pack
# queries could stop being checked without anything saying so -- and this file exists
# because four of five pack queries shipped broken and nothing ran them.
if skipped:
    print(f"  skipped (other platform): {', '.join(skipped)}")
print("pack: FAIL" if failed else
      f"pack: ok, {len(pack['queries']) - len(skipped)} of {len(pack['queries'])} "
      f"queries run on {PLATFORM}")
sys.exit(1 if failed else 0)
