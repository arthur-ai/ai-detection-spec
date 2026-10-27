#!/bin/bash
# CLAUDE CODE FROM npm ON LINUX. 71 and 83 install it natively and 89 and 91 by deb and rpm,
# so no Linux scenario installed the package and its value was proved on macOS and Windows
# only. A scenario of its own: two install routes for one binary name cannot share a host
# (84-linux-installers), and the Linux scenarios that already install from npm forbid
# claude-code as their control.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_node 22 || echo "WARN: Node 22 did not install"
need_user
retry "npm install -g @anthropic-ai/claude-code" \
  sudo_maybe npm install -g --no-fund --no-audit @anthropic-ai/claude-code \
  || echo "WARN: @anthropic-ai/claude-code did not install"
sudo_maybe npm ls -g --depth=0 2>/dev/null | sed 's/^/      /' || true
