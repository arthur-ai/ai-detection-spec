#!/bin/zsh
# GROK BOT through its cask, which tracks the app's own update feed. Never launched: the
# bundle id is what is asserted, and a first launch asks for a sign-in.
#
# WARN rather than exit: the assertion names what is missing.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
retry grok-bot brew install --cask grok-bot || echo "WARN: the grok-bot cask failed"
