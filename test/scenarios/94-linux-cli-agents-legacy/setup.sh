#!/bin/bash
# The previous npm names of three agents 93-linux-cli-agents-more installs current. Each
# ships the binary its successor does, so they need their own host.
#
#   @sourcegraph/amp       now a wrapper depending on @ampcode/cli, still at `latest`
#   droid                  Factory's unscoped name, published beside @factory/cli
#   @jetbrains/junie-cli   Junie's name until @jetbrains/junie, last published 2026-04-27
#
# Nothing is run: the package rows are the claim, and the directories are 93's.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_node 20 || echo "WARN: Node 20 did not install"

for pkg in @sourcegraph/amp droid; do
  try "npm install -g $pkg" sudo_maybe npm install -g --no-fund --no-audit "$pkg" || true
done
try "npm install -g @jetbrains/junie-cli" \
  sudo_maybe env HOME=/root npm install -g --no-fund --no-audit @jetbrains/junie-cli || true
echo "--- the globals npm recorded:"
npm ls -g --depth=0 2>/dev/null | sed 's/^/      /'
