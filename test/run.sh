#!/usr/bin/env bash
# Run one discovery scenario in a disposable macOS VM.
#
#   ./run.sh 30-local-models        run one scenario
#   ./run.sh --all                  run every scenario
#   KEEP_VM=1 ./run.sh 50-autonomous  leave the VM up for inspection
#
# Each run clones a pinned base image, provisions, queries, asserts, and destroys.
# Nothing touches the host. Safe to run repeatedly and in CI on a Mac runner.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/vm.sh"; source "$HERE/lib/assert.sh"

: "${OSQUERY_VERSION:=5.23.1}"
: "${OSQI:=/usr/local/bin/osqueryi}"
: "${KEEP_VM:=0}"
ART="$HERE/artifacts"; mkdir -p "$ART"

run_scenario() {
  # Separate statements: bash expands every word of a `local` before assigning any
  # of them, so `local s="$1" vm="...${s}..."` sees s unset and trips `set -u`.
  local s="$1"
  local vm="arthur-disc-${s}-$$"
  local dir="$HERE/scenarios/$s"
  local rc=0
  [ -d "$dir" ] || { echo "no such scenario: $s" >&2; return 1; }

  echo "=== $s ==="
  vm_create "$vm"; vm_boot "$vm"
  trap '[ "$KEEP_VM" = "1" ] || vm_destroy "'"$vm"'"' RETURN

  # A scenario can be unrunnable rather than broken. OpenClaw needs Sequoia, and a Tart
  # guest can never be newer than the host, so on an older host that is a fact about the
  # lab and not a defect in the query. Report it as SKIP: a failure nobody can act on
  # gets ignored, and an ignored suite stops being read at all.
  if [ -f "$dir/requires.json" ]; then
    local need guest
    need=$(python3 -c "import json;print(json.load(open('$dir/requires.json')).get('min_macos',0))")
    guest=$(vm_ssh "$vm" "sw_vers -productVersion" | cut -d. -f1)
    if [ "$guest" -lt "$need" ]; then
      echo "SKIP: needs macOS >= $need, guest is $guest"
      python3 -c "import json;print('      '+json.load(open('$dir/requires.json')).get('why',''))"
      # Say how to fix it here, not in a README nobody opens while staring at a skip.
      echo "      To run it: on a macOS $need+ host, or explicitly ->"
      echo "        BASE_IMAGE=$(image_for_macos "$need") ./run.sh $s"
      echo
      return 2
    fi
  fi

  # osquery: the same official pkg an MDM would deploy — signed and notarized upstream, we
  # sign nothing.
  vm_ssh "$vm" "curl -fsSL -o /tmp/osquery.pkg https://pkg.osquery.io/darwin/osquery-${OSQUERY_VERSION}.pkg \
                && sudo -n installer -pkg /tmp/osquery.pkg -target / >/dev/null" \
    || { echo "FAIL: osquery ${OSQUERY_VERSION} did not install" >&2; return 1; }

  # Absolute path, deliberately. The pkg symlinks /usr/local/bin/osqueryi, but sudo's
  # secure_path is /usr/bin:/bin:/usr/sbin:/sbin, so `sudo osqueryi` is "command not found"
  # for root. A collection script deployed by an MDM runs as root too and hits exactly this
  # — invoke by path.
  vm_ssh "$vm" "test -x $OSQI" || { echo "FAIL: $OSQI missing after install" >&2; return 1; }

  # Ship the whole scenario tree, not just this one setup.sh: 90-demo-fleet composes its
  # siblings by path, and would silently run nothing if they were absent from the guest.
  # /tmp/lib/, not /tmp/. Every setup.sh sources "$(dirname $0)/../../lib/guest.sh", which
  # from /tmp/scenarios/<name>/ resolves to /tmp/lib/guest.sh. Landing it at /tmp/guest.sh
  # broke every scenario on this path with "no such file or directory: /guest.sh", and CI
  # never saw it: scenarios.yml runs setup.sh from the repo on a runner, where the same
  # relative path resolves in-tree. The VM path is the one nothing else exercises.
  vm_ssh "$vm" "mkdir -p /tmp/lib"
  vm_put "$vm" "$HERE/lib/guest.sh" /tmp/lib/guest.sh
  tar -C "$HERE" -czf "$ART/scenarios.tgz" scenarios
  vm_put "$vm" "$ART/scenarios.tgz" /tmp/scenarios.tgz
  vm_ssh "$vm" "tar -C /tmp -xzf /tmp/scenarios.tgz && chmod +x /tmp/scenarios/*/setup.sh"
  # Exit 3 from a setup script means "this environment cannot host this scenario" -- as
  # distinct from "setup broke". Some capabilities cannot be gated up front the way a macOS
  # version can: whether Docker can run inside a guest depends on nested virtualisation,
  # which you only discover by trying. A scenario that reports FAIL for that would train
  # people to ignore a red suite.
  local setup_rc=0
  vm_ssh "$vm" "/tmp/scenarios/$s/setup.sh" || setup_rc=$?
  if [ "$setup_rc" = "3" ]; then
    echo "SKIP: setup reported this environment cannot host the scenario"
    [ -f "$dir/requires.json" ] && python3 -c "import json;print('      '+json.load(open('$dir/requires.json')).get('why',''))"
    echo
    return 2
  fi
  [ "$setup_rc" = "0" ] || { echo "FAIL: scenario setup failed (exit $setup_rc)" >&2; return 1; }

  # Run the SHIPPING script, not a reimplementation of it. The harness used to invoke
  # osqueryi directly and measure gzip+base64 bytes, while discovery.sh emitted raw JSON
  # -- so the suite reported ~600B while the real artifact would have produced 34KB on a
  # developer Mac and blown the EA cap. Neither number was wrong on its own. Exercise the
  # artifact and there is nothing left to drift.
  vm_put "$vm" "$HERE/../dist/discovery.sql" /tmp/discovery.sql

  local start; start=$(date +%s)
  vm_ssh "$vm" "sudo -n /usr/local/bin/osqueryi --json < /tmp/discovery.sql" > "$ART/$s.json" \
    || { echo "FAIL: discovery.sh failed; see $ART/$s.json" >&2; return 1; }
  local elapsed=$(( $(date +%s) - start ))

  local bytes
  bytes=$(python3 - "$ART/$s.json" <<'EOF' || true
import base64, gzip, json, sys
try:
    doc = json.load(open(sys.argv[1]))
except (json.JSONDecodeError, OSError):
    sys.exit(1)
blob = json.dumps(doc, separators=(",", ":")).encode()
print(len(base64.b64encode(gzip.compress(blob))))
EOF
)
  [ -n "$bytes" ] || { echo "FAIL: osqueryi produced no valid JSON; see $ART/$s.json" >&2; return 1; }

  echo "runtime ${elapsed}s | EA payload ${bytes} bytes gzip+base64"
  [ "$elapsed" -le 10 ] || { echo "FAIL: runtime ${elapsed}s exceeds the 10s EA budget" >&2; rc=1; }
  [ "$bytes" -le 30000 ] || { echo "FAIL: payload ${bytes} exceeds the 30000 byte EA budget" >&2; rc=1; }

  # BOTH layers, the same two test/assert.sh runs in CI. run.sh called only assert_counts,
  # so the VM path -- the one that installs real software, and the only reason the VM
  # exists -- never asked the classifier anything. Counts prove each BRANCH still returns
  # rows; whether that evidence resolves to the right agent is a different question, and
  # `classified.must_find` is where it is asked. A scenario could add an agent to
  # must_find, pass here, and have verified nothing.
  #
  # Found by adding five agents to must_find and noticing the run reported ALL PASS
  # without ever printing them.
  assert_counts "$ART/$s.json" "$dir/expected.json" || rc=1
  assert_classified "$ART/$s.json" "$dir/expected.json" "$HERE/.." || rc=1

  # Record WHICH IDENTIFIERS this run actually matched, into a committed observed.json.
  # test/artifacts/ is gitignored and per-machine, so the raw output cannot back a
  # document anyone else can check. Without this, coverage could only ever be reported per
  # AGENT -- and expected.json names the agent, never the identifier that found it, so an
  # entry could read as verified while carrying identifiers nothing had exercised.
  #
  # Only on success: a failed run's matches are not evidence of anything.
  [ "$rc" -eq 0 ] && python3 "$HERE/../tools/agent_status.py" --record "$ART/$s.json" "$dir"
  echo
  return $rc
}

"$HERE/lint.sh" || { echo "lint failed - fix before burning a VM boot on it" >&2; exit 1; }
vm_require; vm_pull
fails=0; skips=0
run_one() {
  local rc=0
  run_scenario "$1" || rc=$?
  case "$rc" in
    0) ;;
    2) skips=$((skips+1)) ;;   # unrunnable here, not broken
    *) fails=$((fails+1)) ;;
  esac
}
if [ "${1:-}" = "--all" ]; then
  for d in "$HERE"/scenarios/*/; do run_one "$(basename "$d")"; done
else
  run_one "${1:?usage: run.sh <scenario>|--all}"
fi

# Skips are reported alongside passes, never folded into them. A suite that says
# "ALL PASS" while silently skipping the scenario carrying the demo punchline is
# the same silent-zero failure this whole harness exists to prevent.
if [ "$fails" -eq 0 ]; then
  [ "$skips" -eq 0 ] && echo "ALL PASS" || echo "PASS, with $skips scenario(s) SKIPPED"
else
  echo "$fails scenario(s) FAILED, $skips SKIPPED"
fi
exit "$fails"
