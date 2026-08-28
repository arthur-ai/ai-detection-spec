#!/usr/bin/env bash
# Exercise the container query against every state a Docker daemon can be in, and
# assert that the guard admits exactly one of them.
#
# Usage: test/docker_states.sh
#
# Runs in about fifteen seconds and needs no Docker: osquery's --docker_socket flag is
# pointed at a fake daemon (test/lib/fake_docker.py). That matters because the states
# that break things cannot be produced on demand from a real install, and a hosted macOS
# runner has no Docker at all -- so a test that needed one would simply never run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SOCK=/tmp/arthur-fake-docker.sock
OSQI="${OSQI:-/usr/local/bin/osqueryi}"
QUERY="SELECT tags FROM docker_images"
fail=0

# The guard under test. Kept here in the same shape discovery.sh uses it, so the two
# cannot drift silently -- a copy that diverges is worse than no test.
docker_healthy() {
  [ -S "$1" ] || return 1
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 \
       --unix-socket "$1" http://localhost/_ping 2>/dev/null)" = "200" ]
}

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
    rows=$("$OSQI" --docker_socket="$SOCK" --json "$QUERY" 2>/dev/null \
           | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo -1)
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
run_state healthy 1 3

# The guard's whole purpose: prove the unguarded query really does stall on 'hang', so
# nobody concludes the guard is defending against nothing. Bounded, because it does not
# finish on its own.
echo "  hang, WITHOUT the guard"
start_fake hang
stalled=$(python3 - "$OSQI" "$SOCK" <<'PY'
import subprocess, sys
try:
    subprocess.run([sys.argv[1], f"--docker_socket={sys.argv[2]}", "--json",
                    "SELECT tags FROM docker_images"], capture_output=True, timeout=12)
    print("returned")
except subprocess.TimeoutExpired:
    print("stalled")
PY
)
check "the unguarded query stalls past 12s" "$([ "$stalled" = stalled ] && echo 1 || echo 0)" \
      "got '$stalled' -- if this stops failing, the stall is gone and the guard may be removable"
stop_fake

echo
[ "$fail" -eq 0 ] && echo "docker-states: PASS" || echo "docker-states: FAIL"
exit "$fail"
