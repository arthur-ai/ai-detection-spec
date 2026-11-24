#!/bin/zsh
# Terminal coding agents through Homebrew, installed and not run; the token is the claim.
#
#   Maki        homebrew-core's `maki`
#   Devin CLI   the binary-only cask `devin-cli`
#   Warp        the cask `warp-agent-cli`, Warp's Agent CLI; its app is 24's
#   Kilo CLI    Kilo-Org/tap's `kilo`, which homebrew_packages names without its tap
#   Codewhale   Hmbown/deepseek-tui's `deepseek-tui`, the formula from before the rename,
#               likewise; it installs the `codewhale` binary the current formula does, so
#               that one is 19's
#
# Every cask installs on the oldest macOS in the scenarios.yml matrix (10's floor rule). Read
# off the Homebrew API on 2026-11-20: warp-agent-cli >= 14, devin-cli none.
#
# SEPARATE from 21-cli-agents-homebrew only to keep that machine's list its own; no token
# collides with a command 21 installs.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# THE TAP'S NAME IS NOT IN THE ROW, so each tap token is a value only while nothing official
# shares it. Asserted before the taps are added, against the two repositories by name, so a
# tap left on a reused runner cannot answer for them.
for t in kilo deepseek-tui; do
  for repo in homebrew/core homebrew/cask; do
    if brew info "$repo/$t" >/dev/null 2>&1; then
      echo "FAIL: $repo now has a \`$t\`, which the catalog's value would claim"; exit 1
    fi
  done
done
# Through retry, for 13's reason: a CDN can reset a transfer mid-download. Running out WARNs,
# so the assertion names the missing agent.
retry "maki" brew install maki || true
for c in devin-cli warp-agent-cli; do
  retry "$c" brew install --cask "$c" || true
done
retry "Kilo-Org/tap/kilo" brew install Kilo-Org/tap/kilo || true
# Deprecated, and Homebrew's warning says it will be disabled on 2027-08-14 (probe run
# 45468880057). From then this install fails, and docs/signature-lifecycle.md has the path.
retry "Hmbown/deepseek-tui/deepseek-tui" brew install Hmbown/deepseek-tui/deepseek-tui || true
brew list --versions maki devin-cli warp-agent-cli kilo deepseek-tui 2>/dev/null | sed 's/^/  /'
