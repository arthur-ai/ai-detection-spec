#!/bin/zsh
# 23-pi-npm -- Pi from npm on macOS under both its scopes, as 87-linux-pi and
# 88-linux-pi-legacy install them on Linux. 20-cli-agents runs Pi's own installer and forbids
# these rows, so the npm route needs a host of its own.
#
# ONE HOST FOR BOTH SCOPES. They publish the same `pi` command, so the second goes in with
# --force and takes the link; npm_packages reads each package's own directory, and both stay.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_node 22
retry "npm install -g @earendil-works/pi-coding-agent" \
  npm install -g --no-fund --no-audit @earendil-works/pi-coding-agent \
  || echo "WARN: @earendil-works/pi-coding-agent did not install"
retry "npm install -g @mariozechner/pi-coding-agent" \
  npm install -g --no-fund --no-audit --force @mariozechner/pi-coding-agent \
  || echo "WARN: @mariozechner/pi-coding-agent did not install"
npm ls -g --depth=0 2>/dev/null | sed 's/^/  /'
