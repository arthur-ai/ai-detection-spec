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

# PORT 18789 IS THE LAST DID-NOT-APPEAR IDENTIFIER FOR THIS AGENT, and it needs the gateway
# RUNNING, not merely installed. 50-autonomous uses `open -a`, which needs an Aqua session
# SSH does not provide, so the listener never opens there either.
#
# The right invocation is not guessed here. Writing `openclaw gateway &` on the strength of
# a plausible-sounding subcommand is how a test comes to assert something nobody checked --
# the same move that put npm `aider` in the catalog. So this captures the CLI's own help
# into the run log, and the invocation gets written once the output says what it is.
# PORT 18789 NEEDS THE GATEWAY RUNNING, not merely installed. 50-autonomous uses `open -a`,
# which needs an Aqua session SSH does not provide, so the listener never opens there.
#
# The invocation was NOT guessed. Three candidates were tried in a throwaway run and the
# CLI answered precisely:
#
#   gateway start   -> "Tip: openclaw gateway install" -- wants the launchd daemon first
#   gateway serve   -> "OpenClaw gateway has no command \"serve\"."
#   gateway run     -> "Missing config. Run `openclaw setup` or set gateway.mode=local
#                       (or pass --allow-unconfigured)."
#
# So `run` is the command and --allow-unconfigured is the flag, both named by the tool
# rather than by me. --auth none keeps it from waiting on a credential that a disposable
# guest has no way to supply.
echo "--- starting the gateway ---"
( openclaw gateway run --allow-unconfigured --auth none >/tmp/gw.log 2>&1 & ) || true
for i in $(seq 1 20); do
  if lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  LISTENING on 18789"
    break
  fi
  sleep 2
done
lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1 \
  || { echo "  no listener on 18789; the gateway said:"; tail -5 /tmp/gw.log | sed 's/^/    /'; }
