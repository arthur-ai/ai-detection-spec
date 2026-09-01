#!/usr/bin/env bash
# Exercise the container query against every state a Docker daemon can be in, and assert
# that the guard admits exactly one of them -- and that the wall-clock bound kills the one
# the guard wrongly admits.
#
# Usage: test/docker_states.sh
#
# Runs in about twenty-five seconds and needs no Docker: osquery's --docker_socket flag is
# pointed at a fake daemon (test/lib/fake_docker.py). That matters because the states
# that break things cannot be produced on demand from a real install, and a hosted macOS
# runner has no Docker at all -- so a test that needed one would simply never run.
#
# TWO THINGS ARE UNDER TEST AND THE SECOND IS NEWER. The guard turns away four states of
# six. `wedge` -- 200 on /_ping, silence on /images/json -- is the fifth, it passes every
# probe there is, and only the wall-clock kill in bin/container-scan closes it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SOCK=/tmp/arthur-fake-docker.sock
OSQI="${OSQI:-/usr/local/bin/osqueryi}"
QUERY="SELECT tags FROM docker_images"
fail=0

# A CEILING ON THE WHOLE SUITE, because this file's subject is queries that never return and
# it must not become one. Found by mutation: break run_bounded so the bound never fires and
# every assertion that depends on it waits forever -- the suite hangs rather than failing,
# which is the failure mode this repo cares most about. The individual bounds cannot help
# there, since they are the thing that broke.
#
# 120s against a 25s healthy run. Wide enough that a slow hosted runner never trips it, tight
# enough that CI reports a red build in two minutes instead of burning a job timeout.
SUITE_TIMEOUT="${DOCKER_STATES_TIMEOUT:-120}"
(
  n=0
  while [ "$n" -lt "$SUITE_TIMEOUT" ]; do
    kill -0 $$ 2>/dev/null || exit 0
    sleep 1
    n=$(( n + 1 ))
  done
  kill -0 $$ 2>/dev/null || exit 0
  echo "" >&2
  echo "docker-states: FAIL -- the suite exceeded ${SUITE_TIMEOUT}s and was killed." >&2
  echo "  Something under test stopped returning. A hang here is a FAILURE, not a slow run:" >&2
  echo "  check the guard and the wall-clock bound in bin/container-scan first." >&2
  kill -TERM $$ 2>/dev/null
  sleep 2
  kill -KILL $$ 2>/dev/null
) >&2 &
SUITE_WATCHDOG=$!
# Disowned, so bash stops tracking it as a job. Without this, killing it in the trap made
# the shell announce "Terminated: 15" followed by the entire subshell source on stderr --
# on EVERY run, pass or fail. Same noise run_bounded suppresses for the same reason: an
# operator reading stderr for the reason a test failed should not have to scroll past it.
disown "$SUITE_WATCHDOG" 2>/dev/null
# Stand it down on every exit path, or a passing run leaves a sleeper behind for two
# minutes and whatever runs next inherits it.
trap '{ kill "$SUITE_WATCHDOG" 2>/dev/null; } 2>/dev/null; pkill -f "$SOCK" 2>/dev/null' EXIT

# The guard AND the bound under test, SOURCED from the script that ships them. This file
# used to carry its own copy of docker_healthy under a comment explaining why a copy is
# dangerous, while bin/container-scan's header claimed the copy did not exist. Both are now
# true: bin/container-scan stops before its argument parser when sourced, and that is the
# only reason the line is there.
#
# Sourcing brings ROOT, DEEP, TIMEOUT, SCAN_TIMEOUT, PRETTY, SOCKET, MARKER, DOCKER_CODE,
# BOUNDED_OUT and BOUNDED_SIGNAL into this shell, along with `set -uo pipefail`. TIMEOUT=1
# is exactly the ping budget this test wants, and it is inherited rather than restated so
# that a change to the shipped default shows up here.
. "$ROOT/bin/container-scan"

start_fake() {
  rm -f "$SOCK"
  [ "$1" = absent ] && return 0
  python3 "$HERE/lib/fake_docker.py" "$SOCK" "$1" >/dev/null 2>&1 &
  FAKE_PID=$!
  for _ in $(seq 1 40); do [ -e "$SOCK" ] && break; sleep 0.1; done
}

stop_fake() {
  [ -n "${FAKE_PID:-}" ] && { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
  FAKE_PID=""
  rm -f "$SOCK"
}

check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then printf "    ok    %s\n" "$label"
  else printf "    FAIL  %s  %s\n" "$label" "$detail"; fail=1; fi
}

# want_guard: 1 if the guard should admit this state. want_rows: expected row count when
# the guard admits. Only 'healthy' may ever produce rows.
run_state() {
  local state="$1" want_guard="$2" want_rows="$3"
  printf "  %s\n" "$state"
  start_fake "$state"

  if docker_healthy "$SOCK"; then guard=1; else guard=0; fi
  check "guard $( [ "$want_guard" = 1 ] && echo admits || echo skips ) it" \
        "$([ "$guard" = "$want_guard" ] && echo 1 || echo 0)" \
        "guard returned $guard, wanted $want_guard"

  # Time the query only where the guard admits it. Running it on a hung daemon is the
  # bug, not the test: it would not return.
  if [ "$guard" = 1 ]; then
    local start rows elapsed
    start=$(python3 -c 'import time;print(time.time())')
    # BOUNDED, and the bound is the test protecting itself. Found by mutation: weaken the
    # guard to `test -S` and this line admits the `hang` state, at which point an unbounded
    # osqueryi never returns and the SUITE HANGS instead of failing. A test that hangs on a
    # regression is worse than one that fails -- it trains people to re-run it, and then a
    # real stall gets re-run too. 4s is 8x the healthy 0.5s.
    if run_bounded 4 /dev/null "$OSQI" --docker_socket="$SOCK" --json "$QUERY"; then
      rows=$(printf '%s' "$BOUNDED_OUT" \
             | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo -1)
    else
      rows=-1
    fi
    elapsed=$(python3 -c "import time;print(f'{time.time()-$start:.2f}')")
    check "returns $want_rows rows" "$([ "$rows" = "$want_rows" ] && echo 1 || echo 0)" "got $rows"
    # 2s is the ticket's budget for the whole guarded path.
    check "completes under 2s (${elapsed}s)" \
          "$(python3 -c "print(1 if $elapsed < 2 else 0)")" "took ${elapsed}s"
  fi
  stop_fake
}

echo "container query against every daemon state"
run_state absent  0 0
run_state refuse  0 0
run_state hang    0 0
run_state error   0 0
run_state healthy 1 5

# The guard's whole purpose: prove the unguarded query really does stall on 'hang', so
# nobody concludes the guard is defending against nothing. Bounded, because it does not
# finish on its own.
echo "  hang, WITHOUT the guard"
start_fake hang
# 5s, not 12. The old figure came from real Docker Desktop giving up at 10.4s; this fake
# sleeps 300s, so anything an order of magnitude past the healthy 0.5s proves the point and
# 12s was seven seconds of nothing on every run.
stalled=$(python3 - "$OSQI" "$SOCK" <<'PY'
import subprocess, sys
try:
    subprocess.run([sys.argv[1], f"--docker_socket={sys.argv[2]}", "--json",
                    "SELECT tags FROM docker_images"], capture_output=True, timeout=5)
    print("returned")
except subprocess.TimeoutExpired:
    print("stalled")
PY
)
check "the unguarded query stalls past 5s, 10x the healthy time" \
      "$([ "$stalled" = stalled ] && echo 1 || echo 0)" \
      "got '$stalled' -- if this stops failing, the stall is gone and the guard may be removable"
stop_fake

# --- the bound ---------------------------------------------------------------------------
# Everything above proves a health check is NECESSARY. Everything below proves it is not
# SUFFICIENT, which is the half that was missing: `hang` never answers /_ping, so the guard
# turns it away and osqueryi is never started. No state in this file could reach the bound.

echo "  wedge: 200 on /_ping, then silence"
start_fake wedge
if docker_healthy "$SOCK"; then guard=1; else guard=0; fi
# The guard SHOULD admit this one. That is the finding, not a failure.
check "the guard admits it -- a 200 is necessary, not sufficient" \
      "$([ "$guard" = 1 ] && echo 1 || echo 0)" \
      "the guard rejected wedge, so the fake is not answering /_ping and the rest is vacuous"

# Stderr to a FILE, not through a command substitution. `noise=$(run_bounded ...)` runs
# the function in a subshell, so BOUNDED_OUT and BOUNDED_SIGNAL never come back and the
# two assertions that read them pass on an empty variable no matter what the bound did.
# They did, until this comment existed.
errf="$(mktemp "${TMPDIR:-/tmp}/docker-states.XXXXXX")"
t0=$(python3 -c 'import time;print(time.time())')
run_bounded 2 "$DEEP" "$OSQI" --docker_socket="$SOCK" --json 2>"$errf"; rc=$?
elapsed=$(python3 -c "import time;print(f'{time.time()-$t0:.2f}')")
noise="$(cat "$errf")"; rm -f "$errf"

check "the bound reports a timeout (124)" "$([ "$rc" = 124 ] && echo 1 || echo 0)" "got $rc"
check "bounded at 2s (${elapsed}s)" \
      "$(python3 -c "print(1 if $elapsed < 5 else 0)")" "took ${elapsed}s"
# THE KILL IS THE ASSERTION. A wrapper that merely stopped waiting passes both checks above
# and leaves an osqueryi holding the socket for the full 300s the fake sleeps.
sleep 0.3
check "no osqueryi survived the kill" \
      "$(pgrep -f "docker_socket=$SOCK" >/dev/null 2>&1 && echo 0 || echo 1)" \
      "$(pgrep -lf "docker_socket=$SOCK" 2>/dev/null)"
# Measured: an interrupted osqueryi exits 0 having printed "[\n\n]\n", a valid and EMPTY
# JSON array. Keeping that output would report a wedged daemon as a Mac with no containers.
check "the partial output was discarded" "$([ -z "$BOUNDED_OUT" ] && echo 1 || echo 0)" \
      "BOUNDED_OUT held: $BOUNDED_OUT"
# bash announces "Terminated: 15" for a background job it reaps, and in an Extension
# Attribute that line would be the only thing anyone saw.
check "no job-control noise on stderr" "$([ -z "$noise" ] && echo 1 || echo 0)" \
      "stderr said: $noise"

# NOT an assertion. A MEASUREMENT, printed every run, and the number that justifies the
# whole design: osqueryi INSTALLS A SIGTERM HANDLER and exits with status 0, so the wait
# status of a query we killed mid-stall is indistinguishable from one that succeeded. That
# is why run_bounded discards its output on the strength of having fired the kill and never
# on the child's exit code. An osquery upgrade that changes this shows up here.
case "$BOUNDED_SIGNAL" in
  0)   printf "    note  exited 0 after SIGTERM -- it reports SUCCESS on a query it never finished\n" ;;
  143) printf "    note  ended by SIGTERM (143) -- killed rather than exiting on its own\n" ;;
  137) printf "    note  ended by SIGKILL (137) -- SIGTERM did not interrupt the blocked read\n" ;;
  *)   printf "    note  ended with wait status %s -- unexpected, worth a look\n" "$BOUNDED_SIGNAL" ;;
esac
stop_fake

echo "  the bound stands down on a query that finishes"
# A watchdog that always fires would pass every assertion above.
t0=$(python3 -c 'import time;print(time.time())')
run_bounded 3 /dev/null "$OSQI" --json "SELECT 1 AS x"; rc=$?
elapsed=$(python3 -c "import time;print(f'{time.time()-$t0:.2f}')")
check "exit 0, not 124" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "got $rc"
check "the rows survived" "$(printf '%s' "$BOUNDED_OUT" | grep -q '"x"' && echo 1 || echo 0)" \
      "BOUNDED_OUT held: $BOUNDED_OUT"
check "returns well inside the bound (${elapsed}s)" \
      "$(python3 -c "print(1 if $elapsed < 2 else 0)")" "took ${elapsed}s"

echo "  inlining the branch is silent, which is why the split exists"
# THE EVIDENCE FOR THE ARCHITECTURE, and the reason nobody should fold containers back into
# dist/discovery.sql. Composed into one statement and killed, osqueryi does NOT lose the
# other branches' rows -- it returns them and exits 0, so the answer looks complete while
# the container half was never read. That is strictly worse than an error, and it is the
# thing a wall-clock bound on the COMPOSED file would buy you.
# ONE run, not two. An earlier version also ran this through run_bounded to assert the
# bound fires -- which the wedge case above already proves -- and paid three extra seconds
# for it. The naive run below establishes all three parts of the finding at once: that it
# blocked (it had to be killed), that it exits 0, and that the output looks complete.
start_fake wedge
inline="$(mktemp "${TMPDIR:-/tmp}/inline.XXXXXX")"
{ sed 's/;$//' "$ROOT/dist/discovery.sql"; printf '\nUNION ALL\n\n'
  awk '/^SELECT/,0' "$ROOT/queries/containers.sql"; echo ';'; } > "$inline"
naive="$(mktemp "${TMPDIR:-/tmp}/naive.XXXXXX")"
"$OSQI" --docker_socket="$SOCK" --json < "$inline" > "$naive" 2>/dev/null &
np=$!; nw=0
while [ "$nw" -lt 20 ]; do kill -0 "$np" 2>/dev/null || break; sleep 0.1; nw=$(( nw + 1 )); done
if kill -0 "$np" 2>/dev/null; then blocked=1; else blocked=0; fi
kill -TERM "$np" 2>/dev/null; { wait "$np"; nrc=$?; } 2>/dev/null
check "the composed query blocks and has to be killed" "$blocked" \
      "it finished on its own -- if the stall is gone, re-argue the split from scratch"
check "a naive wrapper sees exit 0 from a query it killed" \
      "$([ "$nrc" = 0 ] && echo 1 || echo 0)" "got $nrc"
check "...and a FULL-looking inventory, with the container half missing" \
      "$(python3 -c "
import json
try: rows = json.load(open('$naive'))
except Exception: print(0); raise SystemExit
kinds = {r['kind'] for r in rows}
# Every base kind present, no image row, and enough rows to look like a real answer.
print(1 if len(rows) > 100 and 'image' not in kinds and 'app' in kinds else 0)" 2>/dev/null)" \
      "rows=$(python3 -c "import json;print(len(json.load(open('$naive'))))" 2>/dev/null)"
rm -f "$inline" "$naive"
stop_fake

echo "  the real image fixture classifies to the right agents"
# The fixture is five REAL images captured from a real daemon (see test/lib/fake_docker.py).
# ONE is a catalogued agent and four are not, and BOTH halves are assertions: a matcher that
# claimed alpine, spicedb or an ECR python would be a confident wrong finding on a very large
# share of developer Macs.
#
# The LiteLLM image is the interesting one. It WAS catalogued and deliberately is not any
# more -- a gateway an agent calls through is not an agent -- and its row stays in the
# fixture precisely so this suite asserts it is DECLINED rather than absent. Deleting the row
# with the signature would have left nothing to tell "correctly not an agent" from "the image
# route silently stopped working".
start_fake healthy
scan_out=$("$ROOT/bin/container-scan" --socket "$SOCK" 2>/dev/null)
classified=$(printf '%s' "$scan_out" | "$ROOT/bin/classify" --json 2>/dev/null)
unmatched=$(printf '%s' "$scan_out" | "$ROOT/bin/classify" --json --show-unmatched 2>/dev/null)
for want in llama-cpp; do
  check "finds $want" \
        "$(printf '%s' "$classified" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(1 if any(f['id'] == '$want' for f in d['findings']) else 0)" 2>/dev/null)" \
        "findings were: $(printf '%s' "$classified" | python3 -c "
import json,sys;print([f['id'] for f in json.load(sys.stdin)['findings']])" 2>/dev/null)"
done
# Not merely "litellm is absent from findings" -- absent is what a dropped kind looks like
# too. It has to arrive, be looked at, and be turned down.
check "the LiteLLM image is DECLINED, not dropped" \
      "$(printf '%s' "$unmatched" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(1 if any('litellm' in r['id'] for r in d.get('unmatched', [])) else 0)" 2>/dev/null)" \
      "a gateway is not an agent, and it must be visibly unclaimed rather than invisible"
check "claims nothing else" \
      "$(printf '%s' "$classified" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(1 if sorted(f['id'] for f in d['findings']) == ['llama-cpp'] else 0)" 2>/dev/null)" \
      "alpine, spicedb, the ECR python image and the LiteLLM gateway must stay unmatched"
# A multi-tagged image is one comma-joined row, and matching the field whole finds neither
# tag. The fixture's alpine carries two tags precisely so this cannot regress unnoticed.
check "a comma-joined multi-tag row is still parsed" \
      "$(printf '%s' "$scan_out" | python3 -c "
import json,sys
rows = json.load(sys.stdin)
print(1 if any(',' in r['id'] for r in rows) else 0)" 2>/dev/null)" \
      "the fixture no longer contains a multi-tag image, so this rule is untested"
stop_fake

echo "  bin/container-scan end to end against wedge"
# The string a consumer would record, which is what any grouping is built on. A consumer that
# keeps stdout and discards the exit status sees [] here as the same value a machine with no
# containers reports -- and every guard above would have worked for nothing.
start_fake wedge
out=$(OSQI="$OSQI" "$ROOT/bin/container-scan" --socket "$SOCK" --scan-timeout 2 2>/dev/null)
rc=$?
check "exits 3 (asked, and gave up)" "$([ "$rc" = 3 ] && echo 1 || echo 0)" "got $rc"
check "stdout carries a scan marker, not an empty array" \
      "$(printf '%s' "$out" | python3 -c 'import json,sys
try: r = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(r) == 1 and r[0]["kind"] == "scan"
      and r[0]["extra"].startswith("timeout:") else 0)' 2>/dev/null)" \
      "got: $out"
stop_fake

# --- the cache pattern -------------------------------------------------------------------
# The recommended deployment: a scheduled job writes the payload, the endpoint runs `cat`.
# What has to hold is that the file IS the payload and that it never lies about itself.

echo "  the cache file is the payload"
CACHE="$(mktemp "${TMPDIR:-/tmp}/cache.XXXXXX")"
start_fake healthy
"$ROOT/bin/container-scan" --socket "$SOCK" --cache "$CACHE" >/dev/null 2>&1
check "cat gives complete, valid JSON" \
      "$(cat "$CACHE" | python3 -c "
import json,sys
try: r = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if isinstance(r, list) and r else 0)" 2>/dev/null)" \
      "cat produced: $(head -c 80 "$CACHE")"
# The whole payload, not a prefix, and with the same flags on both sides. An earlier
# version compared 40 characters across two different flag sets and would have passed on
# almost any divergence.
stdout_now="$("$ROOT/bin/container-scan" --socket "$SOCK" 2>/dev/null)"
check "stdout and the file agree, image rows and all" \
      "$(CS_A="$stdout_now" CS_B="$(cat "$CACHE")" python3 -c "
import json, os
def rows(v):
    return sorted(json.dumps(r, sort_keys=True) for r in json.loads(v) if r['kind'] != 'scan')
print(1 if rows(os.environ['CS_A']) == rows(os.environ['CS_B']) else 0)" 2>/dev/null)" \
      "the file must be what a human sees when running the scan by hand"
check "every payload dates itself" \
      "$(python3 -c "
import json
s = [r for r in json.load(open('$CACHE')) if r['kind'] == 'scan']
print(1 if len(s) == 1 and s[0]['extra'] == 'ok' and s[0]['ver'].isdigit() else 0)" 2>/dev/null)" \
      "a reader that can only cat cannot check an mtime, so the rows must carry the time"
stop_fake

echo "  a wedged daemon is recorded, not hidden"
start_fake wedge
"$ROOT/bin/container-scan" --socket "$SOCK" --scan-timeout 2 --cache "$CACHE" >/dev/null 2>&1
check "the cache says timeout, not []" \
      "$(python3 -c "
import json
r = json.load(open('$CACHE'))
s = [x for x in r if x['kind'] == 'scan']
print(1 if len(r) == 1 and s and s[0]['extra'].startswith('timeout:') else 0)" 2>/dev/null)" \
      "cache holds: $(cat "$CACHE")"
stop_fake

echo "  a run that never happened must not overwrite a good cache"
start_fake healthy
"$ROOT/bin/container-scan" --socket "$SOCK" --cache "$CACHE" >/dev/null 2>&1
before="$(cat "$CACHE")"
# Exit 1 is "could not run at all" and says nothing about this Mac's containers.
"$ROOT/bin/container-scan" --cache "$CACHE" --scan-timeout notanumber >/dev/null 2>&1
check "exit 1 leaves the cache alone" \
      "$([ "$before" = "$(cat "$CACHE")" ] && echo 1 || echo 0)" \
      "a verdict it did not earn replaced one it did"
stop_fake

# What bin/classify DOES with a scan row -- provenance, staleness, per-outcome wording --
# is pure Python and lives in test/test_matcher.py, which needs no daemon and runs on every
# push. This file's job is the daemon states that PRODUCE those rows.
rm -f "$CACHE"

# --- three properties that mutation testing found unprotected ----------------------------

echo "  the bound escalates to SIGKILL when SIGTERM is ignored"
# Nothing else covers the escalation: osqueryi honours SIGTERM, so deleting `kill -KILL`
# changed no observable behaviour and every assertion still passed. A process that ignores
# SIGTERM is the only way to exercise it, and it is two lines of python.
ignorer='import signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
print("[]", flush=True)
time.sleep(300)'
t0=$(python3 -c 'import time;print(time.time())')
run_bounded 1 /dev/null python3 -c "$ignorer"; rc=$?
elapsed=$(python3 -c "import time;print(f'{time.time()-$t0:.2f}')")
check "a SIGTERM-proof process is still killed (124)" "$([ "$rc" = 124 ] && echo 1 || echo 0)" \
      "got $rc -- without the SIGKILL escalation this hangs, which is why the bound has one"
check "and killed promptly (${elapsed}s)" \
      "$(python3 -c "print(1 if $elapsed < 4 else 0)")" "took ${elapsed}s"

echo "  the cache is replaced by rename, not written in place"
# A torn read is a race and a race is a bad test. The inode is a deterministic proxy for the
# same property: mv gives a new one, an in-place write keeps it. Mutation testing found this
# entirely unprotected, and a half-written cache is exactly the truncated JSON that reads to
# a collector as a Mac reporting nothing.
CACHE="$(mktemp "${TMPDIR:-/tmp}/cache.XXXXXX")"
start_fake healthy
"$ROOT/bin/container-scan" --socket "$SOCK" --cache "$CACHE" >/dev/null 2>&1
ino1=$(stat -f %i "$CACHE")
"$ROOT/bin/container-scan" --socket "$SOCK" --cache "$CACHE" >/dev/null 2>&1
ino2=$(stat -f %i "$CACHE")
check "a rewrite produces a new inode" "$([ "$ino1" != "$ino2" ] && echo 1 || echo 0)" \
      "inode unchanged ($ino1), so the file was written in place and a reader can tear it"
stop_fake
rm -f "$CACHE"

echo "  a stripped environment does not turn into a wrong answer"
# FOUND BY SIMULATING launchd, WHICH IS THE PATH THIS DEPLOYS ON. A LaunchDaemon is not
# guaranteed to set HOME, and docker_socket_path expanded $HOME and ${DOCKER_HOST#unix://}
# unguarded -- fatal under `set -u`. The failure was not visible as a crash: the function
# runs inside a command substitution, so the unbound variable killed only the subshell, the
# `||` branch ran, and the scan reported `absent` on a Mac that HAD a socket.
#
# DOCKER_SOCKET rather than --socket, deliberately: --socket bypasses docker_socket_path
# entirely and would not exercise the bug at all.
start_fake healthy
stripped=$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin OSQI="$OSQI" DOCKER_SOCKET="$SOCK" \
           /bin/bash "$ROOT/bin/container-scan" 2>/dev/null); rc=$?
check "exit 0 with no HOME in the environment" "$([ "$rc" = 0 ] && echo 1 || echo 0)" \
      "got $rc -- an unguarded \$HOME reports 'absent' here instead of scanning"
check "the images are found, not reported absent" \
      "$(printf '%s' "$stripped" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
imgs = [r for r in rows if r['kind'] == 'image']
gaps = [r for r in rows if r['kind'] == 'scan' and r['extra'] != 'ok']
print(1 if imgs and not gaps else 0)" 2>/dev/null)" \
      "got: $(printf '%s' "$stripped" | head -c 120)"
stop_fake

echo "  one broken branch costs one branch"
# THE RELIABILITY CLAIM the independent writer exists for. Composed, one unavailable table
# returns zero rows for the WHOLE inventory; run apart, it costs its own branch and nothing
# else. One python call computes every verdict and prints them as shell-readable lines --
# five separate inline snippets was fragile and, in this shell, silently produced nothing.
PACKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pack.XXXXXX")"
python3 - "$ROOT/dist/ai-discovery.conf" "$PACKDIR/pack.conf" <<'MKPACK'
import json, sys
full = json.load(open(sys.argv[1]))
# Three branches, not all six: two good ones plus a broken one prove the claim, and the
# other four would add three seconds of re-measuring what the suite already measures.
pack = {"queries": {k: full["queries"][k] for k in ("apps", "packages")}}
# A table that cannot exist, which is what an older osquery presents for a real one.
pack["queries"]["broken"] = {
    "query": "SELECT 1 AS kind, 2 AS id, 3 AS ver, 4 AS loc, 5 AS extra, 6 AS perms "
             "FROM table_that_does_not_exist;",
    "interval": 3600, "platform": "darwin", "description": "deliberately broken"}
json.dump(pack, open(sys.argv[2], "w"))
MKPACK
DISCOVER_PACK="$PACKDIR/pack.conf" OSQI="$OSQI" "$ROOT/bin/discover" \
  --write "$PACKDIR/out.json" >/dev/null 2>/dev/null
eval "$(python3 - "$PACKDIR/out.json" <<'VERDICT'
import json, sys
valid = good = attributed = 0
detail = "unreadable"
try:
    rows = json.load(open(sys.argv[1]))
    valid = 1
    kinds = {r.get("kind") for r in rows}
    scans = {r.get("id"): r.get("extra") for r in rows if r.get("kind") == "scan"}
    good = 1 if {"app", "brew"} <= kinds and len(rows) > 100 else 0
    attributed = 1 if scans.get("broken") == "error" else 0
    detail = f"{len(rows)} rows, kinds={sorted(k for k in kinds if k)}, scans={scans}"
except Exception as e:
    detail = f"{type(e).__name__}: {e}"
print(f"V_VALID={valid}")
print(f"V_GOOD={good}")
print(f"V_ATTR={attributed}")
print(f"V_DETAIL={detail!r}")
VERDICT
)"
check "the payload is still valid JSON" "$V_VALID" "$V_DETAIL"
check "the good branches still reported" "$V_GOOD" "$V_DETAIL"
check "the broken branch reports its own failure, not silence" "$V_ATTR" "$V_DETAIL"
rm -rf "$PACKDIR"

echo
[ "$fail" -eq 0 ] && echo "docker-states: PASS" || echo "docker-states: FAIL"
exit "$fail"
