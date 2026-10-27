#!/bin/bash
# OPENCLAW'S RETIRED npm NAMES ON LINUX, as 56-openclaw-retired-names installs them on macOS:
# `clawdbot` and `moltbot`, the names it published under before `openclaw`. Machines that took
# them still carry them, so the npm route keeps both values, and this proves them on Linux.
#
# --ignore-scripts: npm_packages reads the installed package.json, which needs no install
# script, and the retired builds' scripts are not what is under test.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_node 22 || echo "WARN: Node 22 did not install"
need_user
for pkg in clawdbot moltbot; do
  retry "npm install -g $pkg" \
    sudo_maybe npm install -g --no-fund --no-audit --ignore-scripts "$pkg" \
    || echo "WARN: $pkg did not install"
done
sudo_maybe npm ls -g --depth=0 2>/dev/null | sed 's/^/      /' || true
