#!/bin/zsh
# Two terminal coding agents that herdr runs, through Homebrew: Maki's homebrew-core formula
# and Devin CLI's binary-only cask. Nothing is run; the token is the claim.
#
# SEPARATE from 21-cli-agents-homebrew only to keep that machine's list its own; neither
# token collides with a command 21 installs.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# FRESH METADATA, as 13 does for Dia: Devin's CDN serves only recent builds. On 2026-11-18 the
# macos-26 image's cached cask still named devin-cli 3000.12.43 while homebrew-cask was at
# 3000.14.30821, and the old URL answered 403 (run 44229247235).
brew update >/dev/null 2>&1 || echo "WARN: brew update failed; cask metadata may be stale"
brew install maki || echo "WARN: formula maki failed"
brew install --cask devin-cli || echo "WARN: cask devin-cli failed"
brew list --versions maki devin-cli 2>/dev/null | sed 's/^/  /'
