#!/bin/zsh
# OpenClaw installed the OTHER documented way.
#
# The project README offers two routes, and they land in completely different places:
#   brew install --cask openclaw          -> /Applications/OpenClaw.app + Caskroom  (50-autonomous)
#   curl -fsSL https://openclaw.ai/install.sh | bash
#   npm install -g openclaw@latest        -> an npm global, NO .app, NO Caskroom
#
# install.sh is not a separate route: reading it shows it resolves npm and performs the
# global install itself, so exercising the npm path covers both. It is driven directly
# here rather than piped from the network, because install.sh renders an interactive UI
# and a test that depends on a live third-party endpoint is a test that fails on Mondays.
#
# This scenario exists because a fleet where everyone used the npm route would show ZERO
# rows from the app and brew branches -- the two that 50-autonomous asserts.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_node
npm install -g openclaw@latest --allow-scripts=openclaw \
  || npm install -g openclaw@latest \
  || { echo "FAIL: could not install openclaw from npm" >&2; exit 1; }
npm ls -g --depth=0 2>/dev/null | sed 's/^/  /'
