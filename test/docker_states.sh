#!/usr/bin/env bash
# Exercise the container query against every state a Docker daemon can be in, and assert
# that the guard admits exactly one of them -- and that the wall-clock bound kills the one
# the guard wrongly admits.
#
# Usage: test/docker_states.sh
#
# Runs in about forty-seven seconds and needs no Docker: osquery's --docker_socket flag is
# pointed at a fake daemon (test/lib/fake_docker.py). That matters because the states
# that break things cannot be produced on demand from a real install, and a hosted macOS
# runner has no Docker at all -- so a test that needed one would simply never run.
#
# THREE THINGS ARE UNDER TEST AND THE THIRD IS NEWEST. The guard turns away four states of
# seven. `wedge` -- 200 on /_ping, then silence -- is the fifth, and only the wall-clock kill
# closes it. `nap` is the sixth, and it tests the guard's BUDGET rather than its rule: it is
# `hang` for three seconds and healthy after, so too impatient a guard reports a sleeping Mac
# as an unreachable one.
set -uo pipefail

# A TEST RUN IS NOT A USE, and bin/classify sends one usage event per run. `CI` already
# suppresses it on a runner, but a scenario guest is a fresh VM or container that inherits
# nothing, and a maintainer's own machine has no CI set at all -- so the suite would post
# an event for every fixture it classifies and the field data would be mostly us. Set
# explicitly rather than relied upon: see docs/telemetry.md.
export AI_DISCOVERY_TELEMETRY=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SOCK=/tmp/arthur-fake-docker.sock
# The macOS path first so a Mac's behaviour does not change, then whatever is on PATH --
# which is how the Linux deb and rpm both present it, at /usr/bin/osqueryi. This suite is
# platform-portable by design: it needs NO Docker at all (test/lib/fake_docker.py serves
# every daemon state), so the only thing that was macOS-specific about it was this default
# and one BSD-only stat below.
OSQI="${OSQI:-$([ -x /usr/local/bin/osqueryi ] && echo /usr/local/bin/osqueryi \
      || command -v osqueryi || echo /usr/local/bin/osqueryi)}"

# THE COMPOSED ARTIFACT FOR THIS PLATFORM. There is no unqualified one, and reaching for
# the wrong platform's is not a soft failure: it dies on its first missing table and
# returns in milliseconds, which made the "inlining the branch is silent" test below
# report that the stall had gone away rather than that it had run the wrong file.
case "$(uname -s)" in
  Darwin) PLATFORM=darwin ;;
  Linux)  PLATFORM=linux ;;
  *) echo "docker_states: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac
COMPOSED="$ROOT/dist/discovery-$PLATFORM.sql"
QUERY="SELECT tags FROM docker_images"
fail=0

# A CEILING ON THE WHOLE SUITE, because this file's subject is queries that never return and
# it must not become one. Found by mutation: break run_bounded so the bound never fires and
# every assertion that depends on it waits forever -- the suite hangs rather than failing,
# which is the failure mode this repo cares most about. The individual bounds cannot help
# there, since they are the thing that broke.
#
# 120s against a 47s healthy run. This line claimed 25s and the suite measured 38s before
# `nap`, so the margin was always thinner than it read. Wide enough that a slow runner never
# trips it, tight enough that CI goes red in two minutes instead of burning a job timeout.
# If a runner flaps, raise DOCKER_STATES_TIMEOUT -- a state dropped for time covers nothing.
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
# Sourcing brings ROOT, DEEP, TIMEOUT, SCAN_TIMEOUT, SOCKET, MARKER, CACHE, DOCKER_CODE,
# DOCKER_SECS, BOUNDED_OUT, BOUNDED_SIGNAL, RUNTIME_NAME and RUNTIME_AT into this shell,
# along with `set -uo pipefail`, and the helpers json_str, json_row, osq_run, json_concat,
# merge_*, _runtime_seen and other_runtime. The ping
# budget is INHERITED rather than restated, so that a change to the shipped default shows up
# here -- and the `nap` checks below are where it shows up, because they are the ones whose
# answer it changes. Two rows override it deliberately and say why.
. "$ROOT/bin/container-scan"

start_fake() {
  rm -f "$SOCK"
  [ "$1" = absent ] && return 0
  python3 "$HERE/lib/fake_docker.py" "$SOCK" "$1" >/dev/null 2>&1 &
  FAKE_PID=$!
  # THE SOCKET FILE IS NECESSARY AND NOT SUFFICIENT, which is the same sentence this suite
  # exists to prove about Docker itself: the path appears at bind(), before anything is
  # accepting on it. Waiting for the file alone let the query run against a socket that was
  # not serving yet, and the healthy state returned 0 rows where 6 were expected -- a flake
  # on a loaded runner, and one that reads exactly like the wedged-daemon bug this file was
  # written for.
  #
  # So for `healthy`, wait until it actually ANSWERS. The other states are designed not to,
  # and for them the file is the only readiness signal there can be.
  for _ in $(seq 1 40); do [ -e "$SOCK" ] && break; sleep 0.1; done
  if [ "$1" = healthy ]; then
    for _ in $(seq 1 50); do
      if curl -s --max-time 2 --unix-socket "$SOCK" \
              "http://localhost/images/json" 2>/dev/null | grep -q RepoTags; then
        return 0
      fi
      sleep 0.1
    done
    echo "  WARN: fake daemon never served /images/json; assertions below will say so" >&2
  fi
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

# How many images the fake daemon serves, read from the fake itself. Hardcoding it meant
# adding an image to fake_docker.py silently broke this suite -- and because it needs sudo
# it does not run in the fast loop, so the failure surfaced in CI minutes later rather than
# on the machine that made the change. Adding paulgauthier/aider did exactly that.
FAKE_IMAGE_COUNT=$(python3 -c "
import importlib.util, importlib.machinery, sys
s = importlib.util.spec_from_loader('fd', importlib.machinery.SourceFileLoader(
    'fd', '$HERE/lib/fake_docker.py'))
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(len(m.IMAGES))")

# want_guard: 1 if the guard should admit this state. want_rows: expected row count when
# the guard admits. Only 'healthy' may ever produce rows.
run_state() {
  # A fourth argument overrides the ping budget, and only `hang` passes one: these rows test
  # the guard's RULE, which holds at any budget, and `hang` is the one state that waits out
  # the whole of it -- seven seconds of nothing per run at the shipped 8s. The budget is
  # tested on `nap`, the state whose answer it changes.
  #
  # `local TIMEOUT` shadows the value sourced from bin/container-scan; docker_healthy reads
  # it from there.
  local state="$1" want_guard="$2" want_rows="$3"
  local TIMEOUT="${4:-$TIMEOUT}"
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
run_state hang    0 0 1
run_state error   0 0
run_state healthy 1 "$FAKE_IMAGE_COUNT"

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

# --- the guard's BUDGET, which is not the guard's RULE ------------------------------------
# Everything above asks whether the guard demands the right thing. This asks whether it waits
# long enough to be told. `nap` is silent for three seconds and then serves -- Docker
# Desktop's Resource Saver, 2.6s measured. At the old 1s budget the guard called a napping
# Mac hung, having woken it itself, which reaches a maintainer as "it works when I run it by
# hand" and a fleet as no containers on every idle Mac.

# A FRESH DAEMON PER READING: a nap ends at the first request, so reusing one instance would
# measure the woken daemon twice and every assertion here would pass on a fake that never
# napped.
echo "  nap: the old 1s budget rejects it"
start_fake nap
nap_short=$(OSQI="$OSQI" "$ROOT/bin/container-scan" --socket "$SOCK" --timeout 1 2>/dev/null)
# THE MUTATION, WRITTEN INTO THE SUITE. 1s was the shipped default and produced the bug. If
# this ever scans, the fake is serving immediately and the check below proves nothing.
check "a 1s budget calls a sleeping daemon unreachable" \
      "$(printf '%s' "$nap_short" | python3 -c 'import json,sys
try: r = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(r) == 1 and r[0]["extra"] == "unhealthy:000" else 0)' 2>/dev/null)" \
      "got: $nap_short -- if this scanned, the nap is not napping and the next check is vacuous"
stop_fake

echo "  nap: the shipped budget waits it out"
start_fake nap
t0=$(python3 -c 'import time;print(time.time())')
nap_out=$(OSQI="$OSQI" "$ROOT/bin/container-scan" --socket "$SOCK" 2>/dev/null); nap_rc=$?
nap_elapsed=$(python3 -c "import time;print(f'{time.time()-$t0:.2f}')")
check "the guard waits out the wake and scans (${nap_elapsed}s)" \
      "$([ "$nap_rc" = 0 ] && echo 1 || echo 0)" \
      "got exit $nap_rc -- at a ping budget under the wake this is 2, extra=unhealthy:000"
# Rows, not just a 0. Admitting it and returning nothing would pass the check above while
# reporting a napping Mac as an empty one -- the failure this whole file exists for.
check "and the rows are images, not a marker on its own" \
      "$(printf '%s' "$nap_out" | python3 -c 'import json,sys
try: r = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if any(x["kind"] == "image" for x in r) else 0)' 2>/dev/null)" \
      "got: $(printf '%s' "$nap_out" | head -c 120)"
stop_fake

# PATIENCE IS BOUNDED, and the vocabulary does not change at the far end of it: a daemon that
# outsleeps the budget is indistinguishable from a hung one and reported the same way. A 30s
# nap against a 2s budget makes the point in two seconds.
echo "  a nap longer than the budget is still unreachable"
export FAKE_DOCKER_NAP_SECONDS=30
start_fake nap
over=$(OSQI="$OSQI" "$ROOT/bin/container-scan" --socket "$SOCK" --timeout 2 2>/dev/null)
check "reports unhealthy:000, and claims no rows" \
      "$(printf '%s' "$over" | python3 -c 'import json,sys
try: r = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(r) == 1 and r[0]["extra"] == "unhealthy:000" else 0)' 2>/dev/null)" \
      "got: $over"
stop_fake
unset FAKE_DOCKER_NAP_SECONDS

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
# THE SAME ARGUMENT AS "killed promptly" BELOW, which was widened from 4 to 10 for exactly
# this reason -- and this threshold was left behind because nothing had made it marginal yet.
#
# THE NOMINAL COST GREW, and it grew for a reason recorded in bin/container-scan: SIGTERM no
# longer ends a wedged osqueryi once the query names docker_containers or
# docker_image_labels, so the SIGKILL grace is now paid on EVERY bounded kill rather than
# skipped when the child exits politely. 2s bound + 1s grace + ~0.5s startup is ~3.5s
# nominal where it used to be ~2.5s.
#
# Against a 5s ceiling that is not much headroom, and CI proved it: 4.61s in one run and
# 5.45s in the next, which failed for contention rather than for anything the test is about.
# What this check exists to catch is a bound that never fires, and the fake sleeps 300s --
# so 10 detects that just as decisively and stops the suite going red on a busy runner.
check "bounded at 2s (${elapsed}s)" \
      "$(python3 -c "print(1 if $elapsed < 10 else 0)")" "took ${elapsed}s"
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

echo "  inlining the branch costs the whole inventory, which is why the split exists"
# THE EVIDENCE FOR THE ARCHITECTURE, and the reason nobody should fold containers back into
# the composed artifact.
#
# THE SHAPE OF THIS FAILURE CHANGED when the branch grew past docker_images, and the new
# shape is worse. Both are measured, on 2026-09-13, against this same wedge fake:
#
#   docker_images alone          SIGTERM ends it in 200ms, exit 0, and the file holds a
#                                FULL-looking inventory with the container half missing --
#                                a plausible lie.
#   plus docker_containers OR    SIGTERM IS IGNORED ENTIRELY. The process must be SIGKILLed,
#   docker_image_labels          wait status 137, and the output file is ZERO BYTES.
#
# Either arm alone reproduces it; it is not an interaction between them. So a naive wrapper
# that sends SIGTERM and waits -- which is what this test did until the second arm landed,
# and what this whole suite's 120s watchdog caught -- now WAITS FOREVER.
#
# That is still an argument for the split, and a stronger one. The old failure lied
# quietly; the new one hangs the collector. bin/container-scan survives both because
# run_bounded escalates to SIGKILL on a deadline -- which was written as a belt-and-braces
# measure against a process "not obliged to honour" SIGTERM and is now LOAD-BEARING.
# Simplifying that escalation away would leave an unkillable osqueryi on every wedged Mac.
start_fake wedge
inline="$(mktemp "${TMPDIR:-/tmp}/inline.XXXXXX")"
{ sed 's/;$//' "$COMPOSED"; printf '\nUNION ALL\n\n'
  awk '/^SELECT/,0' "$ROOT/queries/containers.sql"; echo ';'; } > "$inline"
naive="$(mktemp "${TMPDIR:-/tmp}/naive.XXXXXX")"
"$OSQI" --docker_socket="$SOCK" --json < "$inline" > "$naive" 2>/dev/null &
np=$!; nw=0
while [ "$nw" -lt 20 ]; do kill -0 "$np" 2>/dev/null || break; sleep 0.1; nw=$(( nw + 1 )); done
if kill -0 "$np" 2>/dev/null; then blocked=1; else blocked=0; fi
kill -TERM "$np" 2>/dev/null
# A GRACE PERIOD, THEN SIGKILL, and the grace is the assertion. If SIGTERM ever starts
# working again this loop exits early and `termed` says so, which is how an osquery upgrade
# that changes this becomes visible instead of being discovered by a hung suite.
ng=0
while [ "$ng" -lt 10 ] && kill -0 "$np" 2>/dev/null; do sleep 0.1; ng=$(( ng + 1 )); done
if kill -0 "$np" 2>/dev/null; then termed=0; else termed=1; fi
kill -KILL "$np" 2>/dev/null
{ wait "$np"; nrc=$?; } 2>/dev/null
check "the composed query blocks and has to be killed" "$blocked" \
      "it finished on its own -- if the stall is gone, re-argue the split from scratch"
check "SIGTERM alone does NOT end it, so a naive wrapper waits forever" \
      "$([ "$termed" = 0 ] && echo 1 || echo 0)" \
      "SIGTERM ended it after ${ng}00ms. That is the OLD docker_images-only behaviour: if it
       is back, the comment above is stale and the run_bounded escalation is belt-and-braces
       again rather than load-bearing. Re-measure before believing it."
check "...and SIGKILL leaves NO inventory at all, not a partial one" \
      "$(python3 -c "
import json
try: rows = json.load(open('$naive'))
except Exception: print(1); raise SystemExit   # unparseable or empty is the finding
print(0)" 2>/dev/null)" \
      "the file parsed as JSON -- $(wc -c < "$naive" | tr -d ' ') bytes. A killed osqueryi
       that still flushes valid JSON is the plausible-lie failure, which needs its own
       assertion rather than this one"
rm -f "$inline" "$naive"
stop_fake

echo "  the real image fixture classifies to the right agents"
# The fixture is five REAL images captured from a real daemon (see test/lib/fake_docker.py).
# ONE is a catalogued agent (aider) and five are not, and BOTH halves are assertions: a matcher that
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
for want in aider; do
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
print(1 if sorted(f['id'] for f in d['findings']) == ['aider'] else 0)" 2>/dev/null)" \
      "alpine, spicedb, the ECR python image, the LiteLLM gateway and the llama.cpp model runner must all stay unmatched"
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
#
# A FAILURE SAYS WHAT DIFFERED. This check failed on run 37836487241 with nothing but its
# label: the comparison printed 0 and the second scan's stderr went to /dev/null, so
# nobody could tell a timed-out scan from a changed row. Each side's scan marker, the rows
# only one side has, and the second scan's exit code and stderr are printed now. It passes
# only on the word `same`, so a comparison that crashes and prints nothing still fails.
cs_err="$(mktemp "${TMPDIR:-/tmp}/cs-err.XXXXXX")"
stdout_now="$("$ROOT/bin/container-scan" --socket "$SOCK" 2>"$cs_err")"; cs_rc=$?
cs_diff="$(CS_A="$stdout_now" CS_B="$(cat "$CACHE")" python3 -c "
import json, os
def load(name):
    try:
        return json.loads(os.environ[name]), None
    except Exception as e:
        return None, 'is not JSON (%s): %r' % (e, os.environ[name][:120])
def split(doc):
    return ([r.get('extra') for r in doc if r.get('kind') == 'scan'],
            sorted(json.dumps(r, sort_keys=True) for r in doc if r.get('kind') != 'scan'))
(a, ea), (b, eb) = load('CS_A'), load('CS_B')
if ea or eb:
    print('stdout %s; the file %s' % (ea or 'parsed', eb or 'parsed'))
    raise SystemExit
(ma, ra), (mb, rb) = split(a), split(b)
if ra == rb:
    print('same')
    raise SystemExit
print('stdout: %d rows, scan marker %s; the file: %d rows, scan marker %s'
      % (len(ra), ma, len(rb), mb))
only_a, only_b = sorted(set(ra) - set(rb)), sorted(set(rb) - set(ra))
for r in only_a[:5]: print('only on stdout:   ' + r)
for r in only_b[:5]: print('only in the file: ' + r)
if len(only_a) > 5 or len(only_b) > 5: print('(the first five of each)')" 2>&1)"
check "stdout and the file agree, image rows and all" \
      "$([ "$cs_diff" = same ] && echo 1 || echo 0)" \
      "the file must be what a human sees when running the scan by hand
$(cs_errtext="$(tail -c 300 "$cs_err")"
  printf '%s\nthe stdout scan exited %s; its stderr: %s' "${cs_diff:-the comparison printed nothing}" \
    "$cs_rc" "${cs_errtext:-none}" | sed 's/^/          /')"
rm -f "$cs_err"
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
# THE THRESHOLD MEASURES BEHAVIOUR, NOT LOAD. The mechanism is a 1s bound, then SIGTERM,
# then a grace of 10 x 0.1s, then SIGKILL -- about 2s nominal. What it is guarding against
# is the escalation being GONE, and this child sleeps 300s, so a run without SIGKILL takes
# roughly 300 seconds. Anything under ten proves the escalation fired.
#
# It was 4, which is close enough to the nominal 2s that a loaded runner trips it: observed
# at 2.41s locally, 3.21s in one CI run and 4.10s in the next, where it failed for no reason
# but contention. A test that goes red on a busy machine teaches people to re-run it, and a
# suite people re-run is a suite they stop reading. 10 is still 30x below the failure it
# detects.
check "and killed promptly (${elapsed}s)" \
      "$(python3 -c "print(1 if $elapsed < 10 else 0)")" \
      "took ${elapsed}s; without the SIGKILL escalation this child sleeps for 300"

echo "  the cache is replaced by rename, not written in place"
# A torn read is a race and a race is a bad test. The inode is a deterministic proxy for the
# same property: mv gives a new one, an in-place write keeps it. Mutation testing found this
# entirely unprotected, and a half-written cache is exactly the truncated JSON that reads to
# a collector as a Mac reporting nothing.
CACHE="$(mktemp "${TMPDIR:-/tmp}/cache.XXXXXX")"
start_fake healthy
"$ROOT/bin/container-scan" --socket "$SOCK" --cache "$CACHE" >/dev/null 2>&1
# `stat -f %i` is BSD and `stat -c %i` is GNU, and neither exists on the other. Asking
# python for it needs no branch and no feature detection -- and python3 is already a hard
# requirement of the writer this test exercises.
inode() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }
ino1=$(inode "$CACHE")
"$ROOT/bin/container-scan" --socket "$SOCK" --cache "$CACHE" >/dev/null 2>&1
ino2=$(inode "$CACHE")
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

echo "  a marker row survives a socket path that is trying to break it"
# THE REASON marker() WAS AN INTERPRETER. A socket path is input, and a quote in one emits
# malformed JSON -- which a collector reads as "this machine reported nothing", the exact
# outcome the row exists to prevent. The objection was never printf, it was un-escaped
# interpolation, so this pins the escaper against every byte JSON cares about at once:
# apostrophe, double quote, backslash, newline, tab, and UTF-8 that must survive untouched.
#
# Asserted by PARSING, not by grepping the output: a test that matched the escaped text
# would pass on a string that no parser accepts, which is the bug itself.
weird_sock='/tmp/it'"'"'s "weird"\back'$'\n''sock'$'\t''tab/ünï'
weird_row="$(. "$ROOT/bin/container-scan"; MARKER=1 marker 'timeout:6' "$weird_sock")"
check "a hostile socket path round-trips byte-exact" \
      "$(printf '%s' "$weird_row" | python3 -c "
import json, sys
try: r = json.load(sys.stdin)[0]
except Exception: print(0); raise SystemExit
print(1 if r['loc'] == sys.argv[1] and r['extra'] == 'timeout:6'
      and sorted(r) == ['extra','id','kind','loc','perms','ver'] else 0)" "$weird_sock" 2>/dev/null)" \
      "got: $(printf '%s' "$weird_row" | head -c 160)"

echo "  the row that says the writer never ran does not need the writer's interpreter"
# THE MANAGED MAC THIS EXISTS FOR. Without Command Line Tools /usr/bin/python3 is a STUB: it
# prints an install prompt on stderr and exits 1 with EMPTY STDOUT. docs/deployment.md said
# that state surfaces as `no-cache`. It did not -- the no-cache marker was itself built with
# python3, so the one row whose whole job is to say the writer never ran was built by the
# interpreter that stopped the writer, and printed nothing. A collector that records stdout
# and discards the status reads nothing as a machine with nothing on it.
#
# THE STUB LEAVES A BREADCRUMB, so this asserts python was NEVER CALLED rather than that the
# run happened to survive calling it -- a fallback would pass the second and not the first.
# `python` as well as `python3`, because a reintroduction could reach for either.
PYSTUB="$(mktemp -d "${TMPDIR:-/tmp}/pystub.XXXXXX")"
printf '#!/bin/sh\necho "$0" >> "%s/called"\nexit 1\n' "$PYSTUB" > "$PYSTUB/python3"
cp "$PYSTUB/python3" "$PYSTUB/python"
chmod +x "$PYSTUB/python3" "$PYSTUB/python"

nocache="$(PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" --cache "$PYSTUB/absent.json" 2>/dev/null)"; rc=$?
check "--cache on a missing file still exits 1" "$([ "$rc" = 1 ] && echo 1 || echo 0)" "got $rc"
check "...and still prints the no-cache row on STDOUT" \
      "$(printf '%s' "$nocache" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(rows) == 1 and rows[0]['kind'] == 'scan' and rows[0]['id'] == 'inventory'
      and rows[0]['extra'] == 'no-cache' else 0)" 2>/dev/null)" \
      "got: $(printf '%s' "$nocache" | head -c 160) -- empty here is the bug this closes"

# A PRESENT cache is `cat` with a parse check, and the check is what tells a half-written
# file from a machine with nothing on it. Both halves are asserted: the good file must come
# back byte-for-byte -- the old implementation re-encoded, which silently normalised whatever
# the writer had put there -- and the truncated one must be caught rather than forwarded.
printf '[{"kind":"app","id":"com.x","ver":"1","loc":"/A/it'"'"'s \\"q\\"","extra":"","perms":""}]' \
  > "$PYSTUB/good.json"
echoed="$(PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" --cache "$PYSTUB/good.json" 2>/dev/null)"
check "a valid cache comes back byte-for-byte" \
      "$([ "$echoed" = "$(cat "$PYSTUB/good.json")" ] && echo 1 || echo 0)" \
      "got: $(printf '%s' "$echoed" | head -c 160)"

printf '[{"kind":"app","id":' > "$PYSTUB/trunc.json"
trunc="$(PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" --cache "$PYSTUB/trunc.json" 2>/dev/null)"; rc=$?
check "a truncated cache exits 1 and says so in a row" \
      "$([ "$rc" = 1 ] && printf '%s' "$trunc" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(rows) == 1 and rows[0]['id'] == 'inventory'
      and rows[0]['extra'] == 'error' else 0)" 2>/dev/null || echo 0)" \
      "rc=$rc got: $(printf '%s' "$trunc" | head -c 160)"

# EVERY MODE, not only the ones whose output is asserted above. A path that still reached for
# python3 would be found by the breadcrumb below rather than by whichever fleet ran it first.
start_fake healthy
PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" --write "$PYSTUB/w.json" \
     --status "$PYSTUB/w.txt" --socket "$SOCK" >/dev/null 2>&1; write_rc=$?
check "--write runs to completion with no interpreter" \
      "$([ "$write_rc" = 0 ] && [ -s "$PYSTUB/w.json" ] && [ -s "$PYSTUB/w.txt" ] && echo 1 || echo 0)" \
      "rc=$write_rc status=$(cat "$PYSTUB/w.txt" 2>/dev/null | head -c 200)"
check "...and the status line keeps its shape" \
      "$(grep -cE '^(ok|degraded) [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z rows=[0-9]+( [a-z-]+=[^ ]+)+$' \
         "$PYSTUB/w.txt" 2>/dev/null || echo 0)" \
      "got: $(cat "$PYSTUB/w.txt" 2>/dev/null | head -c 200)"
PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" --deep --socket "$SOCK" >/dev/null 2>&1
PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" >/dev/null 2>&1
stop_fake

# CONTAINER_RUNTIME_ROOT is pinned throughout this block: `absent` now depends on what else
# the machine has, so an assertion expecting it is otherwise an assertion about the host --
# and a hosted ubuntu runner ships podman.
RTROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtroot.XXXXXX")"
mkdir -p "$RTROOT/empty" "$RTROOT/podman/usr/bin" "$RTROOT/asdir/usr/bin/podman"
printf '#!/bin/sh\nexit 0\n' > "$RTROOT/podman/usr/bin/podman"
chmod +x "$RTROOT/podman/usr/bin/podman"

# `absent` is a stated fact about the machine, not a branch that failed. A status line that
# calls a Mac without Docker `degraded` fires on every such Mac, and a signal that fires on
# a third of a fleet for nothing is a signal a fleet learns to ignore.
CONTAINER_RUNTIME_ROOT="$RTROOT/empty" PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" \
     --write "$PYSTUB/a.json" --status "$PYSTUB/a.txt" \
     --socket /nonexistent/d.sock >/dev/null 2>&1
check "a machine with no Docker is ok, not degraded" \
      "$(grep -cE '^ok .* containers=absent' "$PYSTUB/a.txt" 2>/dev/null || echo 0)" \
      "got: $(cat "$PYSTUB/a.txt" 2>/dev/null | head -c 200)"

# ...and the distinction still works in the other direction: a daemon that did not answer is
# a branch that could not look, which is exactly what the first token is for.
start_fake wedge
PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" --write "$PYSTUB/d.json" \
     --status "$PYSTUB/d.txt" --socket "$SOCK" >/dev/null 2>&1
stop_fake
check "a branch that could not look still degrades" \
      "$(grep -cE '^degraded .* containers=(unhealthy|timeout|error)' \
         "$PYSTUB/d.txt" 2>/dev/null || echo 0)" \
      "got: $(cat "$PYSTUB/d.txt" 2>/dev/null | head -c 200)"

# `absent` stopped degrading because it is nothing to look at; a runtime we cannot read is
# the opposite, so it lands on the other side. With no rule of its own -- bin/discover
# degrades anything that is neither `ok` nor `absent` -- and asserted anyway, because a
# fourth name added to that CASE would silence a Podman fleet with nothing going red.
CONTAINER_RUNTIME_ROOT="$RTROOT/podman" PATH="$PYSTUB:$PATH" "$ROOT/bin/discover" \
     --write "$PYSTUB/u.json" --status "$PYSTUB/u.txt" \
     --socket /nonexistent/d.sock >/dev/null 2>&1
check "a runtime we cannot read degrades the line, unlike absent" \
      "$(grep -cE '^degraded .* containers=unreadable:podman' "$PYSTUB/u.txt" 2>/dev/null \
         || echo 0)" \
      "got: $(cat "$PYSTUB/u.txt" 2>/dev/null | head -c 200)"

absent_row="$(CONTAINER_RUNTIME_ROOT="$RTROOT/empty" PATH="$PYSTUB:$PATH" \
              "$ROOT/bin/container-scan" --socket /nonexistent/d.sock 2>/dev/null)"
check "container-scan's absent marker needs no interpreter" \
      "$(printf '%s' "$absent_row" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(rows) == 1 and rows[0]['id'] == 'containers'
      and rows[0]['extra'] == 'absent' else 0)" 2>/dev/null)" \
      "got: $(printf '%s' "$absent_row" | head -c 160)"

# In the PYSTUB block deliberately: this is a marker row, so the "python was never called"
# check below has to cover its producer too.
unread_row="$(CONTAINER_RUNTIME_ROOT="$RTROOT/podman" PATH="$PYSTUB:$PATH" \
              "$ROOT/bin/container-scan" --socket /nonexistent/d.sock 2>/dev/null)"; unread_rc=$?
check "a podman install is named, not reported absent" \
      "$(printf '%s' "$unread_row" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if len(rows) == 1 and rows[0]['kind'] == 'scan' and rows[0]['id'] == 'containers'
      and rows[0]['extra'] == 'unreadable:podman'
      and rows[0]['loc'] == sys.argv[1] else 0)" "$RTROOT/podman/usr/bin/podman" 2>/dev/null)" \
      "got: $(printf '%s' "$unread_row" | head -c 200)"
check "...and it is still 'did not scan', not a failure" \
      "$([ "$unread_rc" = 2 ] && echo 1 || echo 0)" "got $unread_rc"

# The must-not half: a producer that named a runtime on every machine would pass the check
# above and tell a reader nothing. Same invocation, empty candidate root.
check "an empty machine still reports absent, so the term is not free" \
      "$(printf '%s' "$absent_row" | python3 -c "
import json, sys
try: print(1 if json.load(sys.stdin)[0]['extra'] == 'absent' else 0)
except Exception: print(0)" 2>/dev/null)" \
      "got: $(printf '%s' "$absent_row" | head -c 160)"

# A directory is executable, so `-x` alone would match one named podman. The producer tests
# `-f` first; this is what goes red if that stops being true.
CONTAINER_RUNTIME_ROOT="$RTROOT/asdir"
if other_runtime; then dirhit=1; else dirhit=0; fi
unset CONTAINER_RUNTIME_ROOT
check "a directory named podman is not an install" \
      "$([ "$dirhit" = 0 ] && echo 1 || echo 0)" \
      "matched $RUNTIME_NAME at $RUNTIME_AT -- -f must be tested before -x"

# The other kind of evidence. Through the primitive rather than a planted path, because
# bash cannot create a socket.
start_fake healthy
RUNTIME_NAME=""; RUNTIME_AT=""
if _runtime_seen colima "$SOCK"; then sockhit=1; else sockhit=0; fi
check "a live socket counts as evidence, attributed to the runtime asked for" \
      "$([ "$sockhit" = 1 ] && [ "$RUNTIME_NAME" = colima ] && [ "$RUNTIME_AT" = "$SOCK" ] \
         && echo 1 || echo 0)" \
      "hit=$sockhit name=$RUNTIME_NAME at=$RUNTIME_AT"
stop_fake

# The $SUDO_USER candidates: under `sudo bin/discover --deep` $HOME is root's, and Rancher
# Desktop has no binary to fall back on, so a wrong pair here reads `absent` on a machine
# that is running containers. Both homes, because /Users is macOS and /home is Linux.
for _home in Users home; do
  _rd="$RTROOT/rd/$_home/rdtest/.rd"
  mkdir -p "$_rd"
  python3 "$HERE/lib/fake_docker.py" "$_rd/docker.sock" hang >/dev/null 2>&1 &
  _rdpid=$!
  for _ in $(seq 1 40); do [ -e "$_rd/docker.sock" ] && break; sleep 0.1; done
  # A subshell, so SUDO_USER and HOME do not leak: an assignment before a FUNCTION call
  # persists in bash, unlike one before a command.
  _rdout="$( CONTAINER_RUNTIME_ROOT="$RTROOT/rd"
             SUDO_USER=rdtest
             HOME="$RTROOT/empty"
             other_runtime && printf '%s %s' "$RUNTIME_NAME" "$RUNTIME_AT" )"
  kill "$_rdpid" 2>/dev/null; wait "$_rdpid" 2>/dev/null
  check "a rancher-desktop socket under \$SUDO_USER's /$_home home is found" \
        "$([ "$_rdout" = "rancher-desktop $_rd/docker.sock" ] && echo 1 || echo 0)" \
        "got: '$_rdout'"
  rm -rf "$RTROOT/rd"
done

rm -rf "$RTROOT"

check "python was never called" "$([ ! -e "$PYSTUB/called" ] && echo 1 || echo 0)" \
      "called: $(cat "$PYSTUB/called" 2>/dev/null | head -c 200)"
rm -rf "$PYSTUB"

# Its own directory: $PYSTUB is gone by here, and reusing a removed path is the kind of
# breakage that shows up as an assertion failing for the wrong reason.
JSONTMP="$(mktemp -d "${TMPDIR:-/tmp}/jsonhelp.XXXXXX")"

echo "  osq_run discards the output of a failed parse"
# THE GUARD EVERY OTHER JSON CALL STANDS ON, asserted directly rather than through a caller.
# Fed malformed JSON, osqueryi writes its error to stderr, exits 1, and STILL PRINTS "[\n\n]"
# on stdout -- five bytes of valid, empty, entirely plausible JSON. A caller that read stdout
# without the status would report a clean machine because a document failed to parse.
#
# BOTH HALVES ARE ASSERTED, and the first is what makes the second mean anything: raw
# osqueryi must be shown to print the lie here, or a future osqueryi that stopped doing it
# would leave this test passing while proving nothing.
bad_sql="SELECT json_extract(value,'\$.id') AS id FROM json_each('[{')"
raw_out="$("$OSQI" --json "$bad_sql" 2>/dev/null)"; raw_rc=$?
check "raw osqueryi still prints [] on a parse failure" \
      "$([ "$raw_rc" != 0 ] && [ -n "$(printf '%s' "$raw_out" | tr -d '[:space:]')" ] && echo 1 || echo 0)" \
      "rc=$raw_rc out=$(printf '%s' "$raw_out" | tr -d '\n')  -- if this changed, osq_run's \
guard may no longer be load-bearing, but do not delete it without measuring"
guarded="$(. "$ROOT/bin/container-scan"; osq_run "$OSQI" --json "$bad_sql" 2>/dev/null)"; g_rc=$?
check "osq_run prints nothing at all, and says so in its status" \
      "$([ "$g_rc" != 0 ] && [ -z "$guarded" ] && echo 1 || echo 0)" \
      "rc=$g_rc out=[$guarded]"

echo "  json_concat refuses to invent an empty inventory"
CONCAT_A='[{"kind":"app","id":"a-1","ver":"1","loc":"/a","extra":"","perms":""}]'
CONCAT_B='[{"kind":"scan","id":"containers","ver":"9","loc":"/s","extra":"ok","perms":""}]'
joined="$(. "$ROOT/bin/container-scan"; json_concat "$OSQI" "$CONCAT_A" "$CONCAT_B")"
check "two documents join, in order, keeping every row" \
      "$(printf '%s' "$joined" | python3 -c "
import json, sys
try: rows = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if [r['id'] for r in rows] == ['a-1','containers'] else 0)" 2>/dev/null)" \
      "got: $(printf '%s' "$joined" | tr -d '\n ')"
check "an empty second document is [] rather than an error" \
      "$(. "$ROOT/bin/container-scan"; json_concat "$OSQI" "$CONCAT_A" "" \
         | python3 -c "
import json, sys
try: print(1 if len(json.load(sys.stdin)) == 1 else 0)
except Exception: print(0)" 2>/dev/null)" \
      "an absent deep half must cost the base rows nothing"
# The one that matters: a malformed half must take the WHOLE join down and print NOTHING,
# because a partial join is a machine reporting less than it found, and "[\n\n]" is a machine
# reporting nothing at all while looking clean.
cat_bad="$(. "$ROOT/bin/container-scan"; json_concat "$OSQI" "$CONCAT_A" '[{' 2>/dev/null)"; cb_rc=$?
check "a malformed half fails loudly and prints nothing" \
      "$([ "$cb_rc" != 0 ] && [ -z "$cat_bad" ] && echo 1 || echo 0)" \
      "rc=$cb_rc out=[$cat_bad] -- printing [] here is the bug this repo exists to prevent"

echo "  every branch's SQL arrives byte for byte as the pack holds it"
# A QUERY THAT LOST ITS TAIL WOULD STILL RUN, still return rows, and still look right in a
# row count -- which is the shape of failure this repo keeps finding. The text crosses one
# osqueryi joined to its branch name by a tab, so this reads the pack independently and
# compares every byte.
. "$ROOT/bin/container-scan"
pack_branches "$OSQI" "$ROOT/dist/ai-discovery.conf" "$PLATFORM" > "$JSONTMP/packlines" 2>/dev/null
pack_verdict="$(python3 - "$ROOT/dist/ai-discovery.conf" "$JSONTMP/packlines" "$PLATFORM" <<'PACKCHECK'
import json, sys
pack = json.load(open(sys.argv[1]))["queries"]
want = {n: q["query"] for n, q in pack.items()
        if q.get("platform") in (sys.argv[3], "posix", "all")}
got = {}
for line in open(sys.argv[2]).read().splitlines():
    if not line:
        continue
    name, tab, text = line.partition("\t")
    if not tab:
        print("no tab in: %.60r" % line); raise SystemExit
    got[name] = text
if set(got) != set(want):
    print("branches missing=%s extra=%s" % (sorted(set(want) - set(got)),
                                            sorted(set(got) - set(want))))
    raise SystemExit
bad = [n for n in want if got[n] != want[n]]
print("text differs for %s" % bad if bad else "1")
PACKCHECK
)"
check "the branch list and every query match the pack exactly" "$pack_verdict" "$pack_verdict"

echo "  a validator that cannot answer is not a cache that is broken"
# THE THIRD OUTCOME, and it exists because collapsing it into "bad" sends someone to look at
# a file that is fine. OSQI points at a binary that exits non-zero and prints nothing, which
# is what osq_run turns any osqueryi failure into.
printf '[]' > "$JSONTMP/fine.json"
broken_out="$(OSQI=/usr/bin/false "$ROOT/bin/discover" --cache "$JSONTMP/fine.json" 2>&1)"; bo_rc=$?
check "--cache exits 1 and names osqueryi, not the file" \
      "$([ "$bo_rc" = 1 ] && printf '%s' "$broken_out" | grep -q 'osqueryi did not answer' && echo 1 || echo 0)" \
      "rc=$bo_rc got: $(printf '%s' "$broken_out" | head -c 160)"
rm -rf "$JSONTMP"

echo "  a broken branch document costs one branch, and the merge says which"
# THE INPUT THAT MATTERS, HANDED DIRECTLY. While the merge was a heredoc inside --write, the
# only way to reach it was a full writer run against real branches -- so the one case worth
# testing, a branch whose document is broken, could not be handed to it at all. It is a
# function now and this points six branches at it, each carrying a different fact:
#
#   good     rows, no scan row of its own    -> rows kept, a synthetic `ok` marker added
#   substit  rows plus id=<its own name>     -> its row stands, NO synthetic marker
#   additive rows plus id=systemd            -> both ship: the branch ran AND systemd did not
#   broken   not JSON at all                 -> `error`, and the other five still report
#   empty    zero bytes, no .failed sentinel -> `error`
#   sentinel .failed present                 -> `error`
#
# `empty` is the one that is a FIX rather than a port. The python merge read "" as [] and
# called it ok, so bin/container-scan exiting 1 -- "could not run at all", which prints an
# empty line -- came back as containers=ok: a scan that never happened, reported as a scan
# that found nothing.
MERGEDIR="$(mktemp -d "${TMPDIR:-/tmp}/merge.XXXXXX")"
row() { printf '{"kind":"%s","id":"%s","ver":"1","loc":"","extra":"%s","perms":""}' "$1" "$2" "$3"; }
printf '[%s]' "$(row app good-1 '')"                                  > "$MERGEDIR/good"
printf '[%s,%s]' "$(row app sub-1 '')" "$(row scan substit timeout:6)" > "$MERGEDIR/substit"
printf '[%s,%s]' "$(row app add-1 '')" "$(row scan systemd absent)"    > "$MERGEDIR/additive"
printf '[{"kind":"app","id":'                                          > "$MERGEDIR/broken"
: > "$MERGEDIR/empty"
: > "$MERGEDIR/sentinel"
: > "$MERGEDIR/sentinel.failed"

merged="$(. "$ROOT/bin/container-scan"
          merge_branches "$OSQI" "$MERGEDIR" good substit additive broken empty sentinel)"
check "the merge answers at all with a malformed branch in the set" \
      "$([ -n "$merged" ] && echo 1 || echo 0)" \
      "empty -- one bad document took the whole payload down, which is the all-or-nothing \
merge the independent writer exists to avoid"
# THE VERDICT IS COMPUTED OUT OF LINE, AND NOT INSIDE A COMMAND SUBSTITUTION. Two traps met
# here, both of which fail as a wrong answer rather than an error:
#
#   `python3 - <<'X'` reads the SCRIPT from stdin, so a pipe into it is discarded in silence
#   and every assertion reads as failed;
#
#   a heredoc inside $( ) is scanned for the closing paren by bash 3.2 WITHOUT respecting the
#   quoted delimiter, so one apostrophe in a comment -- "substit's own row" -- swallows the
#   `)` and the file stops parsing. `bash -n` catches that one; nothing catches the first.
#
# So the payload goes in through argv and the verdict comes back through a file.
printf '%s' "$merged" > "$MERGEDIR/merged.json"
python3 - "$MERGEDIR/merged.json" > "$MERGEDIR/verdict" <<'MERGECHECK'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    print("unparseable"); raise SystemExit
scans = {(r["id"], r["extra"]) for r in rows if r["kind"] == "scan"}
ids = {r["id"] for r in rows if r["kind"] != "scan"}
want = {("good", "ok"), ("substit", "timeout:6"), ("additive", "ok"),
        ("systemd", "absent"), ("broken", "error"), ("empty", "error"),
        ("sentinel", "error")}
# The substit branch supplied its own row, so exactly one scan row may carry that name.
dupes = [r for r in rows if r["kind"] == "scan" and r["id"] == "substit"]
problems = []
if scans != want:
    problems.append("scans missing=%s extra=%s" % (sorted(want - scans), sorted(scans - want)))
if ids != {"good-1", "sub-1", "add-1"}:
    problems.append("rows lost or invented: %s" % sorted(ids))
if len(dupes) != 1:
    problems.append("substit has %d scan rows, not 1" % len(dupes))
print("; ".join(problems) if problems else "1")
MERGECHECK
merge_verdict="$(cat "$MERGEDIR/verdict")"
check "each branch reports the right outcome, and no branch loses its rows" \
      "$merge_verdict" "$merge_verdict"
rm -rf "$MERGEDIR"

echo "  one broken branch costs one branch"
# THE RELIABILITY CLAIM the independent writer exists for. Composed, one unavailable table
# returns zero rows for the WHOLE inventory; run apart, it costs its own branch and nothing
# else. One python call computes every verdict and prints them as shell-readable lines --
# five separate inline snippets was fragile and, in this shell, silently produced nothing.
PACKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pack.XXXXXX")"
python3 - "$ROOT/dist/ai-discovery.conf" "$PACKDIR/pack.conf" <<'MKPACK'
import json, platform, sys
full = json.load(open(sys.argv[1]))
# THE BORROWED BRANCHES MUST BE THIS PLATFORM'S, or bin/discover filters every one of them
# out and writes no payload at all -- which is how this test failed on Linux while passing
# on macOS. The pair and the kinds they must produce are named per platform rather than
# derived from the same pack, because deriving both sides of an assertion from one source
# is how a test stops being able to fail.
PLATFORM = {"Darwin": "darwin", "Linux": "linux"}[platform.system()]
BORROW = {"darwin": (("apps", "homebrew"), {"app", "brew"}),
          "linux": (("packages-linux", "desktop-linux"), {"deb", "desktop"})}[PLATFORM]
# Three branches, not all of them: two good ones plus a broken one prove the claim, and
# the rest would add seconds of re-measuring what the suite already measures.
#
# `homebrew` RATHER THAN `packages` on darwin, and the swap is the point. This used to
# take ("apps", "packages") and assert both `app` and `brew` came back -- true when
# packages.sql carried the Homebrew branch. It is `posix` now and carries only npm,
# because homebrew_packages is a darwin-only table and could not stay in a file a Linux
# artifact composes.
pack = {"queries": {k: full["queries"][k] for k in BORROW[0]}}
# A table that cannot exist, which is what an older osquery presents for a real one.
pack["queries"]["broken"] = {
    "query": "SELECT 1 AS kind, 2 AS id, 3 AS ver, 4 AS loc, 5 AS extra, 6 AS perms "
             "FROM table_that_does_not_exist;",
    "interval": 3600, "platform": PLATFORM, "description": "deliberately broken"}
json.dump(pack, open(sys.argv[2], "w"))
# Hand the expected kinds to the verdict below rather than making it guess.
json.dump(sorted(BORROW[1]), open(sys.argv[2] + ".kinds", "w"))
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
    want = set(json.load(open(sys.argv[1].replace("out.json", "pack.conf.kinds"))))
    good = 1 if want <= kinds and len(rows) > 100 else 0
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
