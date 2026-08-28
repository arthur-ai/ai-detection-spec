#!/usr/bin/env bash
# Compares actual osquery output against a scenario's golden counts.
# Counts, not "did it parse" — every defect found so far returned plausible-looking
# output with the wrong number of rows, and none of them errored.
#
# Since D20 the query enumerates and holds no catalog, so these counts changed meaning.
# They used to assert "the query matched exactly these named things", and the ZEROS were
# the load-bearing half: a zero caught a glob that over-matched. Enumeration makes
# on-device over-matching impossible — the query selects nothing in particular — so most
# zeros became floors, and the over-matching risk moved to the collector.
#
# assert_classified is where that risk is now caught. Counts prove the ENUMERATION still
# works branch by branch; classification proves the catalog still resolves it to the right
# agent, and `forbid` proves it resolves to nothing else.
set -euo pipefail

assert_counts() {
  local actual_json="$1" expected_json="$2"
  python3 - "$actual_json" "$expected_json" <<'PY'
import json, sys, collections
doc = json.load(open(sys.argv[1]))
# discovery.sh wraps findings in a scan envelope; accept a bare array too so a raw
# osqueryi capture can still be checked by hand.
actual = doc["findings"] if isinstance(doc, dict) else doc
expected = json.load(open(sys.argv[2]))
got = collections.Counter(r["kind"] for r in actual)
want = expected["counts"]
fail = False
print(f"{'kind':10} {'want':>8} {'got':>8}")
for kind in sorted(set(want) | set(got)):
    w, g = want.get(kind), got.get(kind, 0)
    if w is None:
        print(f"{kind:10} {'-':>8} {g:>8}  UNEXPECTED KIND"); fail = True; continue
    if isinstance(w, str) and w.startswith(">="):
        ok = g >= int(w[2:])
    else:
        ok = g == w
    print(f"{kind:10} {str(w):>8} {g:>8}  {'ok' if ok else 'FAIL'}")
    fail |= not ok
for probe in expected.get("must_contain", []):
    hit = any(probe in json.dumps(r) for r in actual)
    print(f"  must_contain {probe!r}: {'ok' if hit else 'FAIL'}")
    fail |= not hit
sys.exit(1 if fail else 0)
PY
}

# The summary EA and the detail EA are produced by two osqueryi invocations over the same
# CTE. Nothing structurally forces them to agree, so assert it: a Smart Group matching on
# the summary must select the same Macs the collector sees in the detail.
assert_summary_agrees() {
  local actual_json="$1" summary="$2"
  python3 - "$actual_json" "$summary" <<'PY'
import collections, json, re, sys
doc = json.load(open(sys.argv[1]))
rows = doc["findings"] if isinstance(doc, dict) else doc
got = collections.Counter(r["kind"] for r in rows)
line = re.sub(r"</?result>", "", sys.argv[2])
pairs = re.findall(r"\b(app|npm|brew|daemon|port|ext|nmh|file|model)=(\d+)", line)
if not pairs:
    print("  FAIL: summary carried no counts to check"); sys.exit(1)
bad = False
for kind, n in pairs:
    if got.get(kind, 0) != int(n):
        print(f"  FAIL: summary says {kind}={n}, detail has {got.get(kind, 0)}"); bad = True
print("  summary counts agree with detail" if not bad else "  summary/detail MISMATCH")
sys.exit(1 if bad else 0)
PY
}

# Run the reference classifier over enumerated evidence and check what it concludes.
#
# This is the assertion that replaced the golden zeros. Before D20 a scenario could prove
# correctness by counting rows, because the query only returned rows it had matched. Now
# the query returns everything and the question "did we find OpenClaw" is answered one
# layer later, so the test has to ask there.
#
# `forbid` is the over-matching guard: naming an agent that must NOT appear is the only
# way to catch a signature that is too broad, and a too-broad signature is now the most
# likely defect in the system. `mcp` as an exact npm name is real signal; `mcp` as a
# substring also matches libxdmcp, an X11 library.
assert_classified() {
  local actual_json="$1" expected_json="$2" root="$3"
  python3 - "$actual_json" "$expected_json" "$root" <<'PY_INNER'
import json, subprocess, sys
actual, expected_path, root = sys.argv[1], sys.argv[2], sys.argv[3]
expected = json.load(open(expected_path))
want = expected.get("classified")
if want is None:
    print("  (no classified block in expected.json, skipping)")
    sys.exit(0)

doc = json.load(open(actual))
rows = doc["findings"] if isinstance(doc, dict) else doc
proc = subprocess.run(
    [sys.executable, root + "/bin/classify", "--json", "--show-unmatched"],
    input=json.dumps(rows), capture_output=True, text=True)
if proc.returncode != 0:
    print("  FAIL: classifier exited %d: %s" % (proc.returncode, proc.stderr.strip()[:200]))
    sys.exit(1)
result = json.loads(proc.stdout)
found = {f["id"] for f in result["findings"]}

fail = False
for agent in want.get("must_find", []):
    ok = agent in found
    print("  classified must_find %r: %s" % (agent, "ok" if ok else "FAIL"))
    fail |= not ok
for agent in want.get("forbid", []):
    ok = agent not in found
    print("  classified forbid    %r: %s" % (agent, "ok" if ok else "FAIL - over-matched"))
    fail |= not ok
if "unmatched_max" in want:
    n = len(result["unmatched"])
    ok = n <= want["unmatched_max"]
    print("  unmatched rows %d <= %d: %s" % (n, want["unmatched_max"], "ok" if ok else "FAIL"))
    fail |= not ok
sys.exit(1 if fail else 0)
PY_INNER
}
