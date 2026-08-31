#!/usr/bin/env python3
"""Time each query and enforce its declared cost band.

    tools/measure.py            measure and print
    tools/measure.py --check    fail if any query exceeds its declared band

A query must be fast in its WORST state, not its typical one. An Extension Attribute
gets roughly ten seconds and 30KB; overrun either and the machine reports nothing,
which is indistinguishable from a machine with nothing on it. Performance decides
whether a device is seen at all.

The failure this exists to catch is a query that blocks on an external dependency.
A `docker_images` branch cost 0.35s with Docker absent and 10.4s with Docker
installed-but-stopped, returning zero rows either way, and took the whole query from
1.0s to 11.2s. It measured fine on a machine that had no Docker at all, which is
precisely the state that hides it.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
BANDS = {"fast": 1.0, "slow": 5.0, "expensive": float("inf")}

# The gate fires at band * TOLERANCE, not at the band itself.
#
# A band is a declaration of intent that a reader can trust; the gate exists to catch a
# query that *blocks*, which is an order-of-magnitude event. Enforcing the two at the same
# number conflates them, and the boundary case flaps: apps.sql measured 0.81s and 1.14s on
# consecutive runs of the same commit on the same runner image. A gate that fails randomly
# trains people to re-run it, and then a real stall gets re-run too.
#
# 2.0 is wide enough to absorb hosted-runner variance and still an order of magnitude below
# the 10.24s docker_images stall this exists to catch.
TOLERANCE = 2.0
RUNS = 3
# Well above any band, and there only so a blocking query fails the gate instead of
# hanging it. A run that hits this is reported as inf seconds, which no band tolerates.
TIMEOUT = 60
# bin/container-scan's default CONTAINER_SCAN_TIMEOUT. Kept in step by hand; the two live
# in different languages and there is no shared config file to put it in.
DEEP_BOUND = 6.0
OSQI_CANDIDATES = ["/usr/local/bin/osqueryi",
                   "/opt/osquery/lib/osquery.app/Contents/MacOS/osqueryi", "osqueryi"]


def osqueryi():
    for c in OSQI_CANDIDATES:
        if pathlib.Path(c).exists() or subprocess.run(["which", c], capture_output=True).returncode == 0:
            return c
    sys.exit("osqueryi not found")


def body(text):
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if l.strip() and not l.lstrip().startswith("--")), 0)
    return "\n".join(lines[start:]).strip().rstrip(";")


def measure(binary, sql):
    """Best of N. The floor is the honest number: anything above it is scheduler
    noise, and we are looking for queries that block, not for microbenchmarks.

    BOUNDED, AND POINTED AWAY FROM LOCAL DOCKER, for the same two reasons
    tools/check_pack.py is. This function is handed every file in queries/, containers.sql
    included, and `docker_images` has no timeout of its own -- so on a Mac with Docker
    Desktop mid-startup this hung indefinitely instead of failing, and `measure.py --check`
    is step 5 of the release checklist. A hang there reads as a broken machine rather than
    as the finding it is. The socket path cannot exist, so the number this reports is the
    absent case on every machine, which is at least the same number everywhere; the states
    that block are measured by test/docker_states.sh, which can produce them on demand.
    """
    best, rows = float("inf"), 0
    for _ in range(RUNS):
        start = time.time()
        try:
            out = subprocess.run([binary, "--docker_socket", "/nonexistent/docker.sock",
                                  "--json", sql],
                                 capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return float("inf"), -1
        best = min(best, time.time() - start)
        try:
            rows = len(json.loads(out.stdout))
        except (json.JSONDecodeError, ValueError):
            rows = -1
    return best, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail on an overrun")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    binary = osqueryi()
    results, failures = [], []

    for path in sorted((ROOT / "queries").glob("*.sql")):
        text = path.read_text()
        band = (re.search(r"^--\s*cost:\s*(\w+)", text, re.M) or [None, "fast"])[1]
        seconds, rows = measure(binary, body(text))
        budget = BANDS[band]
        ceiling = budget * TOLERANCE
        over = seconds > ceiling
        results.append({"query": path.name, "band": band, "seconds": round(seconds, 2),
                        "rows": rows, "over_budget": over,
                        "over_declared": seconds > budget})
        if over:
            failures.append(f"{path.name}: {seconds:.2f}s exceeds the '{band}' band "
                            f"({budget}s) even allowing {TOLERANCE}x for runner variance")

    total, total_rows = measure(binary, body((ROOT / "dist" / "discovery.sql").read_text()))
    results.append({"query": "dist/discovery.sql", "band": "composed",
                    "seconds": round(total, 2), "rows": total_rows,
                    "over_budget": total > 10.0})
    if total > 10.0:
        failures.append(f"dist/discovery.sql: {total:.2f}s exceeds the 10s Extension Attribute budget")

    # The deep artifact, measured against the bound bin/container-scan gives it rather than
    # against the EA budget. It is a separate process and a separate Extension Attribute,
    # so 10s is not its ceiling -- the wall clock is, and a deep artifact that cannot
    # finish inside its own bound on the ABSENT case is broken for a different reason than
    # a slow one.
    deep = ROOT / "dist" / "discovery-deep.sql"
    if deep.exists():
        secs, rows = measure(binary, body(deep.read_text()))
        results.append({"query": "dist/discovery-deep.sql", "band": "deep",
                        "seconds": round(secs, 2), "rows": rows,
                        "over_budget": secs > DEEP_BOUND})
        if secs > DEEP_BOUND:
            failures.append(f"dist/discovery-deep.sql: {secs:.2f}s exceeds the {DEEP_BOUND}s "
                            f"wall clock bin/container-scan allows it, with no daemon to "
                            f"answer -- so it would time out on every Mac")

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print(f"  {'query':22} {'band':10} {'seconds':>8} {'rows':>6}")
        for r in results:
            flag = "  OVER" if r["over_budget"] else (
                "  over declared band, within tolerance" if r.get("over_declared") else "")
            print(f"  {r['query']:22} {r['band']:10} {r['seconds']:8.2f} {r['rows']:6}{flag}")

    if args.check and failures:
        print("\nperformance: FAIL")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    if args.check:
        print("\nperformance: PASS")


if __name__ == "__main__":
    main()
