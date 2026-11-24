#!/bin/zsh
# Three agents through Homebrew on macOS, installed and not run; read off probe run
# 45238894100 on 2026-11-23 and this scenario's own runs.
#
#   Craft Agents  the cask `craft-agents`, the app
#   Codewhale     Hmbown/deepseek-tui's `codewhale`, which homebrew_packages names without
#                 its tap; its curl installer and npm package are 119's and 115's
#   Octomind      muvon/tap's `octomind`, likewise; Apple silicon only, which both labels are
#
# craft-agents declares macOS >= 12, so it installs on the oldest macOS in the scenarios.yml
# matrix (10's floor rule); read off homebrew-cask on 2026-11-23.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# FRESH METADATA, for 22's reason: a cached cask can name a build its CDN no longer serves.
out=$(brew update 2>&1) || { echo "WARN: brew update failed; cask metadata may be stale:"
                              print -r -- "$out" | tail -5 | sed 's/^/      /'; }
# THE TAP'S NAME IS NOT IN THE ROW, so each tap token is a value only while nothing official
# shares it. Asserted before the taps are added, as 22 does for `kilo`.
for t in codewhale octomind; do
  for repo in homebrew/core homebrew/cask; do
    if brew info "$repo/$t" >/dev/null 2>&1; then
      echo "FAIL: $repo now has a \`$t\`, which the catalog's value would claim"; exit 1
    fi
  done
done
# Homebrew refuses a formula from an untrusted tap; Codewhale's install guide says so and
# gives this step.
brew trust hmbown/deepseek-tui >/dev/null 2>&1 || true
# Through retry, for 13's reason: a CDN can reset a transfer mid-download. Running out WARNs,
# so the assertion names the missing agent.
retry "craft-agents" brew install --cask craft-agents || true
retry "Hmbown/deepseek-tui/codewhale" brew install Hmbown/deepseek-tui/codewhale || true
retry "muvon/tap/octomind" brew install muvon/tap/octomind || true
brew list --versions craft-agents codewhale octomind 2>/dev/null | sed 's/^/  /'
if [ -d "/Applications/Craft Agents.app" ]; then
  echo "  Craft Agents: $(plutil -extract CFBundleIdentifier raw "/Applications/Craft Agents.app/Contents/Info.plist")"
else
  echo "WARN: no /Applications/Craft Agents.app"
fi
