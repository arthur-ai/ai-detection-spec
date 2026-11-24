#!/bin/zsh
# GROK BOT through its cask. Never launched: the bundle id and the cask are what is asserted.
#
# WARN rather than exit: the assertion names what is missing.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# FRESH METADATA, as 13 does, so the cask is the one Homebrew names today and not the one the
# runner image cached.
brew update >/dev/null 2>&1 || echo "WARN: brew update failed; cask metadata may be stale"
retry grok-bot brew install --cask grok-bot || echo "WARN: the grok-bot cask failed"
