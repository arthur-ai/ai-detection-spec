#!/bin/zsh
# Terminal coding agents through Homebrew: Maki's homebrew-core formula and Devin CLI's
# binary-only cask, which herdr runs, and the Warp Agent CLI's cask, from uber/ADR's catalog.
# Nothing is run; the token is the claim. The warp-agent-cli cask needs macOS 14 or later.
#
# SEPARATE from 21-cli-agents-homebrew only to keep that machine's list its own; no token
# collides with a command 21 installs.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install maki || echo "WARN: formula maki failed"
brew install --cask devin-cli || echo "WARN: cask devin-cli failed"
brew install --cask warp-agent-cli || echo "WARN: cask warp-agent-cli failed"
brew list --versions maki devin-cli warp-agent-cli 2>/dev/null | sed 's/^/  /'
