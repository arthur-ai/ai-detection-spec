#!/usr/bin/env bash
# Compare query output against a scenario's expectations.
# Usage: test/assert.sh <actual.json> <expected.json>
#
# Three layers. D20 split the question in two: the query enumerates, so counts can only
# prove that each BRANCH still returns rows; whether the evidence resolves to the right
# agent is a question for the classifier, and `classified` asks it there. The third holds
# the rendered match SQL -- the catalog as the endpoint runs it -- to the classifier's
# answer on the same rows, and runs dist/agents-<platform>.sql live.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
rc=0
assert_counts "$1" "$2" || rc=1
assert_classified "$1" "$2" "$HERE/.." || rc=1
assert_match_sql "$1" "$2" "$HERE/.." || rc=1
exit "$rc"
