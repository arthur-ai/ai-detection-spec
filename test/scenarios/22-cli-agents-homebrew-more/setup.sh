#!/bin/zsh
# Two terminal coding agents through Homebrew: Maki's formula and Devin CLI's cask.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install maki || echo "WARN: formula maki failed"
brew install --cask devin-cli || echo "WARN: cask devin-cli failed"
brew list --versions 2>/dev/null | sed 's/^/  /'

# ---- PROBE ONLY, never merged.
body="$( { echo "brew:"; brew list --versions 2>&1 | grep -i -E "maki|devin"; ls -1d ~/.*/ ~/.local/bin/* 2>&1 | head -40; echo "rows:"; sudo osqueryi --json < osquery/dist/discovery-darwin.sql 2>&1 | grep -i -E "maki|devin|\"scan\"" | head -60; } 2>&1 )"
body="${body//\%/%25}"; body="${body//$'\n'/%0A}"
echo "::notice title=probe 22 $(sw_vers -productVersion)-$(uname -m)::$body"
