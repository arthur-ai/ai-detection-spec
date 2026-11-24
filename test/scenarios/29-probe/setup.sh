#!/bin/zsh
# PROBE ONLY (review of #179, 2026-11-24): installs and prints what was left. Never merged.
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
here="$(cd "$(dirname "$0")" && pwd)"
note() { echo "::notice title=$1::$(printf '%s' "$2" | tr '\n' '~' | cut -c1-3800)"; }
need_brew
brew update >/dev/null 2>&1 || echo "WARN: brew update failed"

echo "=== Codewhale's pre-rename formula, deepseek-tui, from the same tap"
pre=""
for repo in homebrew/core homebrew/cask; do
  brew info "$repo/deepseek-tui" >/dev/null 2>&1 && pre="$pre $repo-has-deepseek-tui"
done
brew install Hmbown/deepseek-tui/deepseek-tui > /tmp/ds.log 2>&1; r1=$?; tail -8 /tmp/ds.log
note brew-deepseek "rc=$r1 official=${pre:-none} list=$(brew list --versions deepseek-tui 2>&1) bin=$(ls -la "$(brew --prefix)/bin" 2>/dev/null | grep -E 'codew|deepseek' | awk '{print $9,$10,$11}' | tr '\n' ' ') warn=$(grep -iE 'deprecat|disabled|Refusing|Error' /tmp/ds.log | head -4 | tr '\n' ' ') tail=$(tail -3 /tmp/ds.log)"

sudo -n /usr/local/bin/osqueryi --json < osquery/dist/discovery-darwin.sql > /tmp/probe.json 2>/dev/null
rows=$(python3 "$here/filter.py" /tmp/probe.json)
echo "$rows"
note rows-1 "$(echo "$rows" | head -40)"
# SKIP, so nothing is asserted: the notices above are the result.
exit 3
