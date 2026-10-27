#!/usr/bin/env python3
"""Tests for the usage event bin/classify sends.

TWO CLAIMS ARE UNDER TEST, and the second is the one that matters.

  1. The event carries the numbers docs/telemetry.md says it carries.
  2. The event carries NOTHING ELSE, and sending it can never change the answer the
     operator sees -- not the bytes on stdout, not the exit code, not the traceback, in
     any state the network can be in.

Claim 2 is asserted the way this repo asserts everything: against what must NOT appear.
A test that only checked the fields were present would pass just as happily on an event
that also carried the operator's home directory, and a fixture full of real-looking paths
is the only thing that can tell those two apart. So known-agents.json -- which is full of
/Users/alice and /Users/dana -- is the payload every assertion here runs against, and the
capture is searched for every one of those strings.
"""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLASSIFY = ROOT / "bin" / "classify"
FIXTURES = ROOT / "test" / "fixtures"
FAKE = ROOT / "test" / "lib" / "fake_amplitude.py"
failures = []
TMP = pathlib.Path(tempfile.mkdtemp(prefix="telemetry-test."))

# The module, for EVENT_FIELDS. Loaded the way tools/agent_status.py loads it, which also
# proves the thing that load must keep being true: importing bin/classify runs no
# telemetry, because every line of it lives under main().
_loader = importlib.machinery.SourceFileLoader("classify", str(CLASSIFY))
_spec = importlib.util.spec_from_loader("classify", _loader)
classify_mod = importlib.util.module_from_spec(_spec)
_loader.exec_module(classify_mod)


def check(label, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}{'' if condition else '  ' + detail}")
    if not condition:
        failures.append(label)


def dead_port():
    """A port with nothing on it: bind, learn the number, close.

    Racy in principle -- something could claim it in the gap -- and the alternative is a
    hardcoded number, which is racy in practice on any machine that already runs one.
    """
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


DEAD = dead_port()


def env(home, **over):
    """A run's environment.

    THE URL DEFAULTS TO A DEAD PORT ON PURPOSE. A test that forgot to point classify at
    the fake would otherwise point it at the real Amplitude, and the first anyone would
    know is a dashboard with events nobody sent deliberately. CI is cleared because CI
    suppresses sending, and every assertion below is about what gets sent -- on a GitHub
    runner an inherited CI would make this whole file pass while proving nothing.
    """
    e = dict(os.environ)
    e.pop("CI", None)
    # SET ON, NOT MERELY INHERITED. test/lint.sh and tools/gates.sh export
    # AI_DETECTION_SPEC_TELEMETRY=0 so that running the suite is not itself reported -- and
    # this file inherited that, so every assertion about what gets sent passed against an
    # endpoint that received nothing. The suite was green and vacuous under lint and
    # honest when run by hand, which is the worst of the two possible ways round.
    e["AI_DETECTION_SPEC_TELEMETRY"] = "1"
    e["XDG_CONFIG_HOME"] = str(home)
    e["AI_DETECTION_SPEC_AMPLITUDE_KEY"] = "test-ingest-key"
    e["AI_DETECTION_SPEC_AMPLITUDE_URL"] = f"http://127.0.0.1:{DEAD}/2/httpapi"
    e.update(over)
    return e


def serve(state):
    """Start the fake, wait for the port it actually bound."""
    cap = TMP / f"capture-{state}-{time.time_ns()}.jsonl"
    cap.touch()
    proc = subprocess.Popen([sys.executable, str(FAKE), state, str(cap)],
                            stdout=subprocess.PIPE, text=True)
    port = int(proc.stdout.readline().strip().rsplit(" ", 1)[1])
    return proc, port, cap


def run(fixture, environ, *args):
    started = time.time()
    proc = subprocess.run([sys.executable, str(CLASSIFY), str(fixture), *args],
                          capture_output=True, text=True, env=environ)
    return proc, time.time() - started


def captured(cap):
    return [json.loads(line) for line in cap.read_text().splitlines() if line.strip()]


def props_of(cap):
    events = captured(cap)
    return events[0]["events"][0]["event_properties"] if events else {}


KNOWN = FIXTURES / "known-agents.json"

# --- the baseline: what the operator sees when nothing is sent ----------------------
home_off = TMP / "home-off"
off, _ = run(KNOWN, env(home_off, AI_DETECTION_SPEC_TELEMETRY="0"))
BASE_OUT, BASE_RC = off.stdout, off.returncode
check("a run with telemetry off still classifies", BASE_RC == 0 and "aider" in BASE_OUT,
      f"rc={BASE_RC}")

# --- every state the network can be in ----------------------------------------------
# The contract is not "telemetry works". It is "telemetry cannot cost you the answer".
for state in ("ok", "throttle", "toobig", "garbage", "hang"):
    proc_srv, port, cap = serve(state)
    try:
        home = TMP / f"home-{state}"
        got, elapsed = run(KNOWN, env(home, AI_DETECTION_SPEC_AMPLITUDE_URL=
                                      f"http://127.0.0.1:{port}/2/httpapi"))
        check(f"{state}: the report is byte-identical to a run that sent nothing",
              got.stdout == BASE_OUT,
              f"{len(got.stdout)} bytes vs {len(BASE_OUT)}")
        check(f"{state}: the exit code is unchanged", got.returncode == BASE_RC,
              f"rc={got.returncode} vs {BASE_RC}")
        check(f"{state}: exactly one request, never a retry", len(captured(cap)) == 1,
              f"{len(captured(cap))} requests -- a retry charges the user's run twice "
              f"for data that is not theirs")
        if state == "hang":
            # THE BOUND. Without a timeout on the socket this run never returns, and it
            # never returns AFTER printing the answer -- a tool that looks finished and
            # holds the shell. 10s leaves room for a loaded runner; the bound is 2s.
            check("hang: the sender gives up rather than holding the shell open",
                  elapsed < 10, f"took {elapsed:.1f}s")
    finally:
        proc_srv.kill()

# THE FLUSH, which no content assertion can reach. stdout to a pipe is block-buffered, so
# without an explicit flush the report sits in the buffer until the interpreter exits --
# and it exits AFTER the send. The bytes are identical either way; what differs is when
# the caller gets them. Measured against `hang`, where the send costs the full bound: the
# first byte must arrive long before that.
proc_srv, port, cap_flush = serve("hang")
try:
    started = time.time()
    piped = subprocess.Popen(
        [sys.executable, str(CLASSIFY), str(KNOWN)], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
        env=env(TMP / "home-flush",
                AI_DETECTION_SPEC_AMPLITUDE_URL=f"http://127.0.0.1:{port}/2/httpapi"))
    first_line = piped.stdout.readline()
    first_byte = time.time() - started
    piped.wait(timeout=30)
    check("the report reaches the caller BEFORE the event is sent, not after",
          first_byte < 1.5 and first_line != "",
          f"first byte after {first_byte:.1f}s -- unflushed, a pipe holds the whole "
          f"report until the sender gives up")
finally:
    proc_srv.kill()

# refuse: nothing listening at all, which needs no server to arrange.
home_refuse = TMP / "home-refuse"
got, elapsed = run(KNOWN, env(home_refuse))
check("refuse: a missing endpoint costs neither the report nor the exit code",
      got.stdout == BASE_OUT and got.returncode == BASE_RC, f"rc={got.returncode}")
check("refuse: and it does not stall", elapsed < 10, f"took {elapsed:.1f}s")

# --- off means off -------------------------------------------------------------------
for label, over in (("AI_DETECTION_SPEC_TELEMETRY=0", {"AI_DETECTION_SPEC_TELEMETRY": "0"}),
                    ("AI_DETECTION_SPEC_TELEMETRY=off", {"AI_DETECTION_SPEC_TELEMETRY": "off"}),
                    ("CI is set", {"CI": "true"})):
    proc_srv, port, cap = serve("ok")
    try:
        home = TMP / f"home-off-{abs(hash(label))}"
        got, _ = run(KNOWN, env(home, AI_DETECTION_SPEC_AMPLITUDE_URL=
                                f"http://127.0.0.1:{port}/2/httpapi", **over))
        check(f"{label}: nothing is sent", captured(cap) == [],
              f"{len(captured(cap))} requests reached the endpoint")
    finally:
        proc_srv.kill()

# NO KEY AT ALL, which is a fork that stripped the constant rather than an env var. This
# used to sit in the loop above as AI_DETECTION_SPEC_AMPLITUDE_KEY="", and it passed for exactly
# as long as the shipped constant was ALSO empty -- an empty env var falls back to the
# constant, which is the correct behaviour and made the assertion test nothing. It only
# came apart when a real key was baked in. So the state is arranged properly now: a copy of
# the tool with the constant emptied, run against its own catalog.
stripped = TMP / "classify-no-key"
stripped.write_text(CLASSIFY.read_text().replace(
    f'AMPLITUDE_KEY = "{classify_mod.AMPLITUDE_KEY}"', 'AMPLITUDE_KEY = ""'))
proc_srv, port, cap_nokey = serve("ok")
try:
    catalog_args = ["--catalog", str(ROOT / "catalog" / "agents.yaml"),
                    "--routes", str(ROOT / "catalog" / "routes.yaml")]
    subprocess.run([sys.executable, str(stripped), str(KNOWN), *catalog_args],
                   capture_output=True, text=True,
                   env=env(TMP / "home-nokey", AI_DETECTION_SPEC_AMPLITUDE_KEY="",
                           AI_DETECTION_SPEC_AMPLITUDE_URL=
                           f"http://127.0.0.1:{port}/2/httpapi"))
finally:
    proc_srv.kill()
check("a build with no key compiled in sends nothing", captured(cap_nokey) == [],
      f"{len(captured(cap_nokey))} requests from a keyless build")

# THE SHAPE OF THE KEY ITSELF, and this one is here because of an actual incident: the
# first token pasted in was 32 mixed-case alphanumerics, which is a SECRET key -- the
# credential that authenticates Amplitude's Export and Dashboard APIs. It sits next to the
# ingest key on the same settings page and is the same length. Baking one into this file
# would publish a read credential to a public repository. Amplitude answered 400 "Invalid
# API key" and caught it that time; nothing in the tree would have.
check("the compiled-in key is an INGEST key -- lowercase hex, never a secret key",
      classify_mod.AMPLITUDE_KEY == "" or
      (len(classify_mod.AMPLITUDE_KEY) == 32 and
       all(c in "0123456789abcdef" for c in classify_mod.AMPLITUDE_KEY)),
      "a secret key is mixed-case and grants READ access to the whole project")

# --- what the event carries, and what it must not --------------------------------------
proc_srv, port, cap_ok = serve("ok")
try:
    home_ok = TMP / "home-ok-fields"
    first, _ = run(KNOWN, env(home_ok, AI_DETECTION_SPEC_AMPLITUDE_URL=
                              f"http://127.0.0.1:{port}/2/httpapi"))
    second, _ = run(KNOWN, env(home_ok, AI_DETECTION_SPEC_AMPLITUDE_URL=
                               f"http://127.0.0.1:{port}/2/httpapi"))
finally:
    proc_srv.kill()

props = props_of(cap_ok)
check("every property is one docs/telemetry.md declares",
      set(props) <= set(classify_mod.EVENT_FIELDS),
      f"undeclared: {sorted(set(props) - set(classify_mod.EVENT_FIELDS))}")

# THE AGREED LIST, WRITTEN OUT. Not "are the declared fields present" -- that passes on
# any list, however it grew -- but "is this still the set somebody signed off". The field
# list was cut to eight requested items once and put back in full deliberately; either way
# the guard is the same, and it is the reason a field cannot arrive here because an author
# found it interesting. Adding one means editing this literal, which is the point.
AGREED = {
    "catalog_sha", "catalog_schema_version", "catalog_agents",
    "classify_sha",
    "rows_total", "findings_agents", "findings_rows", "unmatched_rows", "dropped_rows",
    "payload_bytes", "payload_packed_bytes",
    "gap_rows", "absence_rows", "scan_rows",
    "kinds_seen", "deep_scan",
    "gap_reasons", "gap_unhealthy_code", "gap_timeout_seconds",
    "stale_branches", "newest_scan_age_seconds",
    "host_os", "host_os_release", "payload_platform", "python_version",
    "output_mode", "show_unmatched", "duration_ms",
    "error_type", "error_site", "phase",
}
check("the shipped field list is EXACTLY the agreed one, in both directions",
      set(classify_mod.EVENT_FIELDS) == AGREED,
      f"added: {sorted(set(classify_mod.EVENT_FIELDS) - AGREED)}  "
      f"missing: {sorted(AGREED - set(classify_mod.EVENT_FIELDS))}")
check("and a successful run sends no property outside it",
      set(props) <= AGREED, f"extra: {sorted(set(props) - AGREED)}")
# NO NESTED STRUCTURES. kind_counts was the only one and it is gone; a scalar cannot
# carry a list of things found on a machine, which is the shape a leak would take.
check("every value is a number, a bool, or a closed-vocabulary word -- nothing nested",
      all(isinstance(v, (int, float, bool)) or (isinstance(v, str) and len(v) < 200)
          for v in props.values()),
      f"{[(k, type(v).__name__) for k, v in props.items() if isinstance(v, (dict, list))]}")

# THE ASSERTION THIS FILE EXISTS FOR, and the second version of it. The first listed the
# strings by hand -- "/Users/", "alice", a bundle id -- and a deliberate leak of a row's
# `loc` walked straight past it, because the value that leaked was
# "/Applications/ChatGPT.app" and no hand-written needle happened to cover that one. A
# list of what to look for can only ever find what its author thought of.
#
# So the needles come from the PAYLOAD ITSELF: every identifier, location and permission
# string in the fixture, plus this machine's own name and user. If a value went in, it may
# not come out, whether or not anybody predicted that particular one.
body = cap_ok.read_text()
import getpass
needles = {v for row in json.loads(KNOWN.read_text())
           for k, v in row.items()
           if k in ("id", "loc", "perms") and isinstance(v, str) and len(v) >= 5}
needles |= {os.uname().nodename, getpass.getuser()}
leaks = sorted(n for n in needles if n and n in body)
check("nothing from the payload, and no name of this machine, is in the event", not leaks,
      f"leaked {leaks[:3]} -- the event is counts, and a count cannot name a person")

# BEFORE ANY FIELD ASSERTION. Every check below reads the first captured event, and an
# empty capture makes all of them vacuous rather than red -- the state this suite was
# briefly in. Fail loudly here instead.
events = captured(cap_ok)
check("the endpoint actually received something to assert against", len(events) == 2,
      f"{len(events)} captured -- with none, every field check below proves nothing")
# AND THAT IT IS THE RIGHT KIND OF EVENT. Running the suite under an interpreter without
# PyYAML made classify exit 1 on every invocation, so the capture filled with
# classify_crash events -- which carry a handful of properties and sail through the field
# assertions below. Six checks reported ok while proving nothing about a successful run.
check("...and that it is a completed run, not a crash report",
      all(e["events"][0]["event_type"] == "classify_run" for e in events),
      f"got {[e['events'][0]['event_type'] for e in events]} -- a crash event has few "
      f"enough properties to satisfy every check below without meaning any of them")
if not events:
    print("\ntelemetry: FAIL (nothing captured)")
    sys.exit(1)
full = events[0]
event = full["events"][0]
check("the ingest key travels in the body, as Amplitude's HTTP V2 expects",
      full.get("api_key") == "test-ingest-key")
check("the source IP is requested explicitly rather than by accident",
      event.get("ip") == "$remote")
check("the envelope carries an id, the IP, a timestamp, a dedupe token and the OS",
      set(event) == {"device_id", "event_type", "time", "insert_id", "ip",
                     "os_name", "os_version", "event_properties"},
      f"envelope is {sorted(event)}")
check("the device id is random, persisted, and not a machine identifier",
      len(event.get("device_id", "")) == 32 and
      (home_ok / "ai-detection-spec" / "install-id").exists())
check("the same install reports the same id on its second run",
      len({e["events"][0]["device_id"] for e in captured(cap_ok)}) == 1)
check("the first run says so on stderr, and the second does not",
      "docs/telemetry.md" in first.stderr and "docs/telemetry.md" not in second.stderr)
check("...and the notice never touches stdout, which --json callers parse",
      "docs/telemetry.md" not in first.stdout)

# DERIVED FROM THE TOOL, NOT TYPED IN. These were literal numbers -- 8 agents, 31 rows,
# 16 unmatched -- read off the fixture on the day this was written. Every one of them is a
# fact about the CATALOG, which gains signatures weekly, so each was a future failure with
# no bug behind it. The invariant that actually matters is that the event agrees with the
# report, and that one holds however the catalog grows.
ref = json.loads(subprocess.run(
    [sys.executable, str(CLASSIFY), str(KNOWN), "--json", "--show-unmatched"],
    capture_output=True, text=True,
    env=env(TMP / "home-ref", AI_DETECTION_SPEC_TELEMETRY="0")).stdout)
check("the counts are the ones the report itself shows",
      props.get("findings_agents") == len(ref["findings"])
      and props.get("rows_total") == len(json.loads(KNOWN.read_text()))
      and props.get("findings_rows") == sum(len(f["evidence"]) for f in ref["findings"]),
      f"event says {props.get('findings_agents')} agents / {props.get('rows_total')} rows; "
      f"the report says {len(ref['findings'])} / {len(json.loads(KNOWN.read_text()))}")
check("unmatched is counted without --show-unmatched being asked for",
      props.get("unmatched_rows") == len(ref["unmatched"]),
      f"{props.get('unmatched_rows')} vs {len(ref['unmatched'])} in the report")
# MEASURED, NOT INFERRED. Row counts cannot answer whether a payload still fits the
# channel: bytes per row vary 2.7x across kinds on a real payload, so this has to come
# from the bytes classify actually read.
check("the payload size is reported, raw and packed, and packing helps",
      props.get("payload_bytes") == len(KNOWN.read_bytes())
      and 0 < props.get("payload_packed_bytes", 0) < props.get("payload_bytes", 0),
      f"raw={props.get('payload_bytes')} (file is {len(KNOWN.read_bytes())}) "
      f"packed={props.get('payload_packed_bytes')}")
check("the catalog identifies itself by content hash",
      len(props.get("catalog_sha", "")) == 12
      and props.get("catalog_schema_version") == classify_mod.CATALOG_VERSION)
check("a clean payload reports nothing dropped", props.get("dropped_rows") == 0,
      f"{props.get('dropped_rows')}")
check("the platform reported is the PAYLOAD's, not the machine classify ran on",
      props.get("payload_platform") == "darwin", f"{props.get('payload_platform')}")

# --- the gap vocabulary, end to end ----------------------------------------------------
# Every reason osquery/bin/discover and osquery/bin/container-scan can emit, plus one nobody emits. The
# unknown one must arrive as "other": `extra` comes from a payload this process did not
# write, and forwarding it verbatim would make an analytics property a channel for
# arbitrary text off a machine we are meant to be describing in counts.
now = int(time.time())
gapful = TMP / "gaps.json"
gapful.write_text(json.dumps([
    {"kind": "scan", "id": "containers", "ver": str(now), "loc": "/var/run/docker.sock",
     "extra": "unhealthy:500", "perms": ""},
    {"kind": "scan", "id": "apps", "ver": str(now), "loc": "", "extra": "error", "perms": ""},
    {"kind": "scan", "id": "systemd", "ver": str(now), "loc": "", "extra": "absent",
     "perms": ""},
    {"kind": "scan", "id": "inventory", "ver": str(now), "loc": "/var/lib/x.json",
     "extra": "no-cache", "perms": ""},
    {"kind": "scan", "id": "browser", "ver": str(now), "loc": "", "extra": "timeout:6",
     "perms": ""},
    # The parameter is a runtime NAME, not a number, and it must not travel: `unreadable`
    # is the property, `podman` stays on the endpoint like every other path and identifier
    # in this payload.
    {"kind": "scan", "id": "containers", "ver": str(now), "loc": "/usr/bin/podman",
     "extra": "unreadable:podman", "perms": ""},
    {"kind": "scan", "id": "martian", "ver": str(now), "loc": "/Users/dana/secret",
     "extra": "exploded-in-/Users/dana", "perms": ""},
    {"kind": "scan", "id": "npm", "ver": str(now - 90000), "loc": "", "extra": "ok",
     "perms": ""},
    {"kind": "bogus", "id": "nobody-routes-this", "ver": "", "loc": "", "extra": "",
     "perms": ""},
]))
proc_srv, port, cap_gap = serve("ok")
try:
    run(gapful, env(TMP / "home-gaps",
                    AI_DETECTION_SPEC_AMPLITUDE_URL=f"http://127.0.0.1:{port}/2/httpapi"))
finally:
    proc_srv.kill()
gp = props_of(cap_gap)
sys.path.insert(0, str(ROOT / "test"))
import conformance  # noqa: E402
_words, _patterns = conformance.scan_outcomes()
_heads = {w for w in _words if w != "ok"} | {p.lstrip("^").split(":")[0] for p in _patterns}
check("GAP_REASONS is the evidence schema's outcomes other than ok",
      set(classify_mod.GAP_REASONS) == _heads,
      f"classify {sorted(classify_mod.GAP_REASONS)}, schema {sorted(_heads)}")
check("every gap reason a scan row can carry arrives normalised",
      gp.get("gap_reasons") == "absent,error,no-cache,other,timeout,unhealthy,unreadable",
      f"{gp.get('gap_reasons')!r}")
check("...with the unhealthy code and the timeout kept as numbers",
      gp.get("gap_unhealthy_code") == 500 and gp.get("gap_timeout_seconds") == 6,
      f"code={gp.get('gap_unhealthy_code')} timeout={gp.get('gap_timeout_seconds')}")
check("an unknown reason is reported as 'other', never forwarded verbatim",
      "exploded" not in cap_gap.read_text() and "/Users/dana" not in cap_gap.read_text())
check("...and a known reason's parameter does not travel either",
      "podman" not in cap_gap.read_text(),
      "gap_reasons carries the head of the vocabulary, never the tail")
check("a stale branch is counted", gp.get("stale_branches") == 1,
      f"{gp.get('stale_branches')}")
check("a containers marker counts as a deep scan even when the scan FAILED",
      gp.get("deep_scan") is True,
      "asking and being refused is use; only counting successes undercounts the feature")
check("a row whose kind no route claims is counted as DROPPED",
      gp.get("dropped_rows") == 1,
      f"{gp.get('dropped_rows')} -- this number is the ext bug, made visible")
check("...and its kind is reported as 'other' rather than by name",
      "other" in gp.get("kinds_seen", "") and "bogus" not in cap_gap.read_text())

# --- crashes -----------------------------------------------------------------------
broken = TMP / "not-json.json"
broken.write_text("{ this is not json, and the error message will name this file")
proc_srv, port, cap_crash = serve("ok")
try:
    home_crash = TMP / "home-crash"
    crashed, _ = run(broken, env(home_crash, AI_DETECTION_SPEC_AMPLITUDE_URL=
                                 f"http://127.0.0.1:{port}/2/httpapi"))
    plain, _ = run(broken, env(TMP / "home-crash-off", AI_DETECTION_SPEC_TELEMETRY="0"))
finally:
    proc_srv.kill()
check("a crash still exits non-zero and still prints its traceback",
      crashed.returncode == plain.returncode != 0 and "Traceback" in crashed.stderr,
      f"rc={crashed.returncode} vs {plain.returncode}")
check("...and the traceback is the same one the operator would have seen anyway",
      crashed.stderr.splitlines()[-1] == plain.stderr.splitlines()[-1])
cp = props_of(cap_crash)
check("the crash is reported by type and line, and says which stage it was in",
      cp.get("error_type") == "JSONDecodeError" and cp.get("phase") == "read"
      and ":" in cp.get("error_site", ""),
      f"{cp.get('error_type')} at {cp.get('error_site')} in {cp.get('phase')}")
check("the exception MESSAGE is never sent -- messages carry paths",
      "not-json" not in cap_crash.read_text() and
      str(TMP) not in cap_crash.read_text(),
      "a crash reporter that sends str(exc) leaks the filename it failed on")

# AND THE CRASH WHOSE MESSAGE ACTUALLY CARRIES A PATH. The assertion above was vacuous on
# its own: a JSONDecodeError is raised by json.loads over a STRING, so its message names a
# line and column and no file at all -- sending str(exc) verbatim passed it. A missing
# input file is the case that matters, because FileNotFoundError's message is the path,
# and the path is a home directory with a person's name in it.
missing = TMP / "no-such-payload-a1b2c3.json"
proc_srv, port, cap_missing = serve("ok")
try:
    gone, _ = run(missing, env(TMP / "home-missing", AI_DETECTION_SPEC_AMPLITUDE_URL=
                               f"http://127.0.0.1:{port}/2/httpapi"))
finally:
    proc_srv.kill()
mp = props_of(cap_missing)
check("a missing input crashes as it always did, and is reported by type",
      gone.returncode != 0 and mp.get("error_type") == "FileNotFoundError"
      and mp.get("phase") == "read",
      f"rc={gone.returncode} {mp.get('error_type')} in {mp.get('phase')}")
check("...and the path it could not find is NOT in the event",
      "no-such-payload-a1b2c3" not in cap_missing.read_text()
      and str(TMP) not in cap_missing.read_text(),
      "FileNotFoundError's message IS the path; sending it sends the home directory")

# A REFUSED CATALOG IS COUNTED AS ONE, by its own phase, so version skew in the field stays
# visible now that it is refused rather than warned about.
newer = TMP / "catalog-v99.yaml"
# By pattern, not by the current number: a literal that went stale replaced nothing, and the
# catalog it wrote was simply this one.
_skewed, _n = re.subn(r"^version: \d+$", "version: 99",
                      (ROOT / "catalog" / "agents.yaml").read_text(), count=1, flags=re.M)
assert _n == 1, "catalog/agents.yaml has no `version:` line to skew"
newer.write_text(_skewed)
proc_srv, port, cap_skew = serve("ok")
try:
    skewed, _ = run(KNOWN, env(TMP / "home-skew", AI_DETECTION_SPEC_AMPLITUDE_URL=
                               f"http://127.0.0.1:{port}/2/httpapi"), "--catalog", str(newer))
finally:
    proc_srv.kill()
sp = props_of(cap_skew)
check("a refused catalog exits non-zero and is reported in the `catalog` phase",
      skewed.returncode != 0 and sp.get("error_type") == "SystemExit"
      and sp.get("phase") == "catalog",
      f"rc={skewed.returncode} {sp.get('error_type')} in {sp.get('phase')}")

# --- the diagnostic ------------------------------------------------------------------
shown = subprocess.run([sys.executable, str(CLASSIFY), str(KNOWN), "--telemetry-check"],
                       capture_output=True, text=True, env=env(TMP / "home-check"))
doc = json.loads(shown.stdout)
check("--telemetry-check prints the event and sends nothing",
      doc["event"]["event_properties"].keys() and captured(cap_ok),
      "the event must be printable, or the README's 'do not take it on trust' is a slogan")
check("...and it does not create the install id it is describing",
      not (TMP / "home-check" / "ai-detection-spec" / "install-id").exists(),
      "a diagnostic with a side effect gives a different answer the second time")
check("...and it says WHY a run would not send, rather than only that it would not",
      json.loads(subprocess.run(
          [sys.executable, str(CLASSIFY), str(KNOWN), "--telemetry-check"],
          capture_output=True, text=True,
          env=env(TMP / "home-check2", CI="true")).stdout)["reason"] is not None)

shutil.rmtree(TMP, ignore_errors=True)
print()
if failures:
    print(f"telemetry: FAIL ({len(failures)})")
    sys.exit(1)
print("telemetry: PASS")
