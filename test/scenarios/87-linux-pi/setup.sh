#!/bin/bash
# Pi from npm under its current scope, and NOT RUN. A run writes ~/.pi, which would be a
# second witness, so @earendil-works/pi-coding-agent is the only thing on this host that can
# name the agent. 88 runs the old scope and proves ~/.pi there.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
# 1.x declares node >= 22.19, newer than any distro stream here.
need_node 22 || echo "WARN: Node 22 did not install"
need_user

retry "npm install -g @earendil-works/pi-coding-agent" \
  sudo_maybe npm install -g --no-fund --no-audit @earendil-works/pi-coding-agent \
  || echo "WARN: @earendil-works/pi-coding-agent did not install"
echo "--- $(pi --version 2>&1)"
