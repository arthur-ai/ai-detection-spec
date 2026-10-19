#!/bin/bash
# Pi under its OLD npm scope, deprecated in favour of @earendil-works and still installable,
# so a machine that installed it before the move still reports it. Its own host because both
# scopes install the same `pi` binary.
#
# RUN ONCE, because ~/.pi does not exist until then: --version does not create it. With no
# provider configured the run exits 1 after writing ~/.pi/agent, measured on 0.73.1 and
# 1.1.0 on 2026-10-08, so its exit is ignored and the assertion decides.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_node 22 || echo "WARN: Node 22 did not install"
need_user

retry "npm install -g @mariozechner/pi-coding-agent" \
  sudo_maybe npm install -g --no-fund --no-audit @mariozechner/pi-coding-agent \
  || echo "WARN: @mariozechner/pi-coding-agent did not install"
# </dev/null because as_user feeds its script to bash on stdin, and pi would read the rest.
try_user "pi, run once" 'timeout 60 pi -p hello </dev/null >/dev/null 2>&1; test -d ~/.pi/agent' || true
