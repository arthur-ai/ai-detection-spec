#!/bin/bash
# An agent RUNNING, not only installed: the scenario the `proc` kind needs. OpenClaw's
# gateway is a long-lived node process, so it is still running when the query reads the
# process table, and osquery/queries/running.sql names it by the package its workers run from.
#
# THE TOKEN IS THROWAWAY and the gateway has no channel and no model. That is enough to
# start the process this run asserts on and nothing more. In a container the gateway binds
# to every address and refuses to start without auth, so a token is set rather than
# `--auth none`, which 55 can use on a Mac.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_node 24 || echo "WARN: Node 24 did not install; openclaw needs it"
need_user
try "npm install -g openclaw" sudo_maybe npm install -g --no-fund --no-audit openclaw || true

# AS THE USER, detached: setsid so the gateway outlives the shell that started it, and
# its own log so a gateway that refuses to start says why.
as_user 'OPENCLAW_GATEWAY_TOKEN=throwaway setsid openclaw gateway run --allow-unconfigured \
  </dev/null >/tmp/gateway.log 2>&1 &' || true
# WAIT FOR `ready`, NOT FOR THE FIRST WORKER. On CI's runners the setup stopped at the first
# worker, before the gateway had finished starting, and the query step after it found no
# worker at all. The log is printed either way, so a gateway that stops says why.
for _ in $(seq 1 60); do
  grep -q '\[gateway\] ready' /tmp/gateway.log 2>/dev/null && break
  sleep 2
done
echo "--- the gateway's log, last lines:"
tail -8 /tmp/gateway.log 2>/dev/null | sed 's/^/      /'
echo "--- the gateway's processes, as osquery reads them:"
sudo_maybe osqueryi --json \
  "SELECT name, path, substr(cmdline, 1, 120) AS cmd FROM processes WHERE cmdline LIKE '%node_modules/openclaw/%'" \
  | sed 's/^/      /'
