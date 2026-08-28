#!/usr/bin/env bash
# Compares actual osquery output against a scenario's golden counts.
# Counts, not "did it parse" — every defect found so far returned plausible-looking
# output with the wrong number of rows, and none of them errored.
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
