#!/usr/bin/env bash
# Compares actual osquery output against a scenario's golden counts.
# Counts, not "did it parse": every defect found so far returned plausible output with the
# wrong number of rows, and none of them errored.
#
# The query enumerates and holds no catalog, so a count proves only that each BRANCH still
# returns rows, and most counts are floors. Whether the rows resolve to the right agent is
# assert_classified's question, and it also proves they resolve to nothing else.
set -euo pipefail

# A TEST RUN IS NOT A USE, and bin/classify sends one usage event per run. `CI` already
# suppresses it on a runner, but a scenario guest is a fresh VM or container that inherits
# nothing, and a maintainer's own machine has no CI set at all -- so the suite would post
# an event for every fixture it classifies and the field data would be mostly us. Set
# explicitly rather than relied upon: see docs/telemetry.md.
export AI_DETECTION_SPEC_TELEMETRY=0

# THE ASSERTIONS LIVE IN tools/scenarios.py, beside the vocabulary they read, so a key this
# file checks and a key the static gate accepts cannot be two lists. It refuses a scenario
# whose files it cannot read in full before asserting anything.
SCENARIOS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/scenarios.py"

assert_counts() {
  python3 "$SCENARIOS_PY" assert-counts "$1" "$2"
}

# Run the reference classifier over enumerated evidence and check what it concludes: every
# agent must_find names, and nothing else. The query returns everything, so "did we find
# OpenClaw" is answered by the matcher, not by a row count, and an agent found beyond
# must_find is a signature too broad -- `mcp` as a substring also matches libxdmcp.
assert_classified() {
  python3 "$SCENARIOS_PY" assert-classified "$1" "$2"
}

# The rendered match SQL -- osquery/dist/signatures.sql and osquery/dist/agents-<platform>.sql -- against
# the same real install, held to the classifier.
#
# The rendered SQL is derived from the classifier's own index, which makes agreement likely
# and proves nothing; the fixtures in osquery/test/test_match_sql.py prove the predicates, and this
# is where the two meet REAL rows from a scenario that installed real software. Two checks:
# the fragment over the rows just collected must claim exactly the evidence rows the
# classifier claims, and the standalone artifact, run live, must find what `must_find`
# names (except agents this payload found only through images, which only the bounded
# container branch carries) and nothing beyond it.
#
# Given <agents.json> and <parity.json> it runs no osqueryi: test/run.sh produces both in
# the Tart guest and asserts on a host that may have none. Without them it runs osqueryi
# itself, with `sudo -n` for the live artifact when not already root.
assert_match_sql() {
  local actual_json="$1" expected_json="$2" root="$3" agents_json="${4:-}" parity_json="${5:-}"
  python3 "$root/osquery/test/test_match_sql.py" --assert "$actual_json" "$expected_json" \
    --root "$root/osquery" ${agents_json:+--agents "$agents_json"} ${parity_json:+--parity "$parity_json"}
}
