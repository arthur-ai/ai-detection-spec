#!/usr/bin/env bash
# Compare query output against a scenario's expected counts.
# Usage: test/assert.sh <actual.json> <expected.json>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
assert_counts "$1" "$2"
