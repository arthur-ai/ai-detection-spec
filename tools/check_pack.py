#!/usr/bin/env python3
"""Execute every query in the osquery pack and assert it actually runs.

The pack is a SEPARATE ARTIFACT from dist/discovery.sql, built by a different code path,
and until now nothing ran it. It shipped with four of its five queries returning zero
rows: the builder flattened SQL to one line without stripping `--` comments, so each
query commented itself out after its first branch.

Nothing errored. Zero rows is exactly what a clean Mac returns, so a customer deploying
the pack would have concluded they had no AI tooling. Testing dist/discovery.sql told us
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
OSQI = next((c for c in ("/usr/local/bin/osqueryi",
                         "/opt/osquery/lib/osquery.app/Contents/MacOS/osqueryi")
             if pathlib.Path(c).exists()), None)
if OSQI is None:
    sys.exit("osqueryi not found")

pack = json.loads((ROOT / "dist" / "ai-discovery.conf").read_text())
COLUMNS = ["kind", "id", "ver", "loc", "extra", "perms"]
failed, total_rows = False, 0

for name, spec in sorted(pack["queries"].items()):
    sql = spec["query"]
    if "--" in sql:
        print(f"FAIL: {name} still contains a -- comment after flattening, which "
              f"comments out the rest of the one-line query")
        failed = True
        continue
    # A timeout, because the pack now carries the container query and docker_images has
    # no timeout of its own. Against a daemon that accepts and never answers it runs
    # indefinitely -- this check would hang the build rather than fail it. Point it at a
    # socket path that cannot exist so the pack test never depends on local Docker state.
    try:
        proc = subprocess.run([OSQI, "--docker_socket", "/nonexistent/docker.sock",
                               "--json", sql],
                              capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        print(f"FAIL: {name} did not finish in 30s")
        failed = True
        continue
    # The COLUMN NAMES, not just the row count. The pack shipped a browser query returning
    # 74 correctly-counted rows keyed 'ext' and "permissions || CASE WHEN ..." because its
    # first UNION ALL arm carried no aliases -- well-formed only inside dist/discovery.sql,
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

print("pack: FAIL" if failed else f"pack: ok, {len(pack['queries'])} queries run")
sys.exit(1 if failed else 0)
