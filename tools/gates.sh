#!/usr/bin/env bash
# Every fast gate, and a NON-ZERO EXIT when any of them fails.
#
# Exists because a hand-rolled loop reported "FAIL" for two gates and the commit that
# followed went in regardless -- the loop printed a status per command and always exited 0,
# so nothing downstream could tell a green run from a red one. A checklist that cannot fail
# is a checklist nobody has to obey.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
fail=0
# A TEST RUN IS NOT A USE, and bin/classify sends one usage event per run. `CI` already
# suppresses it on a runner, but a scenario guest is a fresh VM or container that inherits
# nothing, and a maintainer's own machine has no CI set at all -- so the suite would post
# an event for every fixture it classifies and the field data would be mostly us. Set
# explicitly rather than relied upon: see docs/telemetry.md.
export AI_DISCOVERY_TELEMETRY=0
run() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  %-42s PASS\n' "$*"
  else
    printf '  %-42s FAIL\n' "$*"
    printf '%s\n' "$out" | tail -4 | sed 's/^/      /'
    fail=1
  fi
}
run test/lint.sh
run python3 osquery/tools/build.py --check
run python3 osquery/tools/render_match.py --check
run python3 osquery/test/test_match_sql.py
run python3 tools/validate_catalog.py
run python3 tools/agent_status.py --check
run python3 tools/agent_status.py --json
run python3 test/test_matcher.py
run python3 test/test_telemetry.py
run python3 test/test_ci_scope.py
run python3 test/test_conformance.py
run python3 test/test_export.py
run python3 osquery/tools/check_no_catalog.py
run python3 tools/check_doc_numbers.py
run python3 tools/check_workflows.py
[ "$fail" -eq 0 ] && echo "gates: PASS" || echo "gates: FAIL"
exit "$fail"
