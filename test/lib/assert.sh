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

# A TEST RUN IS NOT A USE, and bin/classify sends one usage event per run. `CI` already
# suppresses it on a runner, but a scenario guest is a fresh VM or container that inherits
# nothing, and a maintainer's own machine has no CI set at all -- so the suite would post
# an event for every fixture it classifies and the field data would be mostly us. Set
# explicitly rather than relied upon: see docs/telemetry.md.
export AI_DISCOVERY_TELEMETRY=0

assert_counts() {
  local actual_json="$1" expected_json="$2"
  python3 - "$actual_json" "$expected_json" <<'PY'
import json, sys, collections
# A BARE ARRAY IS THE ONLY SHAPE ANY PRODUCER EMITS -- `osqueryi --json`, bin/discover and
# bin/container-scan alike. This used to unwrap a `findings` envelope as well, from an
# endpoint script that predates this repo: nothing in the tree could produce a dict, and
# the unwrap would have raised on bin/classify's findings anyway, which carry no `kind`.
actual = json.load(open(sys.argv[1]))
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
# A LIST ELEMENT MEANS "ANY OF THESE", and it exists because the OS axis produced the
# first identifier that legitimately differs by platform. The `chatgpt` cask resolved to
# 26.721.41059 on macos-15 and to 1.2026.160 on macos-14 in run 33511815638, and those two
# builds carry DIFFERENT bundle ids -- com.openai.codex and com.openai.chat. Both are real.
#
# The alternative was to drop the bundle-id probe and lean on the classifier, and that is
# the wrong trade: `chatgpt` matches on the brew route too, so must_find still passes with
# every bundle id in the catalog broken. This probe is the only thing that reads the raw
# row, which is exactly why it must be able to say "one of these two" instead of being
# weakened to nothing.
blobs = [json.dumps(r) for r in actual]
for probe in expected.get("must_contain", []):
    alts = probe if isinstance(probe, list) else [probe]
    hit = any(any(p in blob for p in alts) for blob in blobs)
    label = " | ".join(alts)
    print(f"  must_contain {label!r}: {'ok' if hit else 'FAIL'}")
    fail |= not hit

# forbid_rows: NO ROW MAY MATCH ALL THE NAMED FIELDS. Exact per field, never a substring,
# because what is being asserted is that a QUERY excluded something -- and a substring
# probe would be satisfied or defeated by whatever else happened to be installed.
#
# This exists for queries/packages-linux.sql's dpkg status filter. A package removed
# without --purge stays in dpkg's database as `deinstall ok config-files`, WITH ITS
# VERSION, so an unfiltered query reports software nobody has as installed. Asserting the
# absence of {kind: deb, id: nano} is the only way to see that the filter works: row
# counts, must_find and the classifier all look identical either way.
for spec in expected.get("forbid_rows", []):
    hits = [r for r in actual if all(str(r.get(k, "")) == str(v) for k, v in spec.items())]
    label = ", ".join(f"{k}={v}" for k, v in spec.items())
    print(f"  forbid_rows {label}: {'FAIL' if hits else 'ok'}"
          + (f"  found {len(hits)}" if hits else ""))
    fail |= bool(hits)
sys.exit(1 if fail else 0)
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

rows = json.load(open(actual))  # a bare array -- see assert_counts
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
# forbid_evidence: A STRING THAT MUST NOT APPEAR IN ANY FINDING'S EVIDENCE.
#
# `forbid` above asks whether an AGENT was claimed, which cannot express the assertion
# Linux needs most: a stock Ubuntu ships libxcursor1 and libwayland-cursor0, both real
# deb packages whose names contain `cursor`. Those rows are legitimately in the payload,
# so a raw must_not_contain would always fail; what must be true is that neither is
# EVIDENCE FOR Cursor. Same shape as `libxdmcp` versus `mcp`, and the same reason: without
# it, "correctly declined" and "the route never ran" are indistinguishable.
for probe in want.get("forbid_evidence", []):
    claimed = [(f["id"], json.dumps(e)) for f in result["findings"]
               for e in f.get("evidence", []) if probe in json.dumps(e)]
    print("  forbid_evidence %r: %s" % (probe, "ok" if not claimed
          else "FAIL - claimed by " + ", ".join(sorted({c[0] for c in claimed}))))
    fail |= bool(claimed)
if "unmatched_max" in want:
    n = len(result["unmatched"])
    ok = n <= want["unmatched_max"]
    print("  unmatched rows %d <= %d: %s" % (n, want["unmatched_max"], "ok" if ok else "FAIL"))
    fail |= not ok
sys.exit(1 if fail else 0)
PY_INNER
}
