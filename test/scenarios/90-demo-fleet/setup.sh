#!/bin/zsh
# Everything at once - one VM carrying the full demo narrative.
# Use this to generate realistic seed evidence for UP-4898.
#
# THE SCENARIOS IT RUNS ARE expected.json's `composes`, from which tools/scenarios.py derives
# this scenario's must_find: the union of theirs. A second list here still named
# 30-local-models after that scenario was removed. 11-perplexity-desktop is in it because it
# was split out of 10-desktop-apps for its macOS >= 15 floor.
set -e
. "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
# python3 reads the list, and /usr/bin/python3 is a stub until the Command Line Tools are installed.
need_clt || { echo "FAIL: Command Line Tools did not install" >&2; exit 1; }
D="$(cd "$(dirname "$0")/.." && pwd)"
for s in $(python3 -c 'import json, sys; print(" ".join(json.load(open(sys.argv[1]))["composes"]))' \
             "$(dirname "$0")/expected.json"); do
  echo "--- $s ---"; zsh "$D/$s/setup.sh" || echo "WARN: $s had failures"
done
