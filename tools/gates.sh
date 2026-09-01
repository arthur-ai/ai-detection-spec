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
run python3 tools/build.py --check
run python3 tools/validate_catalog.py
run python3 tools/agent_status.py --check
run python3 tools/agent_status.py --json
run python3 test/test_matcher.py
run python3 tools/check_no_catalog.py
run python3 tools/check_doc_numbers.py
run python3 tools/check_workflows.py
[ "$fail" -eq 0 ] && echo "gates: PASS" || echo "gates: FAIL"
exit "$fail"
