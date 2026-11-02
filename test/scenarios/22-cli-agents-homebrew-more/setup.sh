#!/bin/zsh
# Two terminal coding agents that herdr runs, through Homebrew: Maki's homebrew-core formula
# and Devin CLI's binary-only cask. Nothing is run; the token is the claim.
#
# SEPARATE from 21-cli-agents-homebrew only to keep that machine's list its own; neither
# token collides with a command 21 installs.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install maki || echo "WARN: formula maki failed"
brew install --cask devin-cli || echo "WARN: cask devin-cli failed"
brew list --versions maki devin-cli 2>/dev/null | sed 's/^/  /'
