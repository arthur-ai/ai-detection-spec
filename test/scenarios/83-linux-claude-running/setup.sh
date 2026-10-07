#!/bin/bash
# Claude Code RUNNING, through the process_paths route. Its native install runs from
# ~/.local/share/claude/versions/<version>, which no presence route names: `binaries`
# names the ~/.local/bin/claude link, and a running process reports where the link leads.
#
# `claude mcp serve` is the smallest invocation that keeps a Claude Code process alive
# without a login: it serves MCP over stdio and waits. A sleep holds its stdin open,
# because a stdio server exits on EOF and </dev/null would prove nothing.
#
# EXIT 3 WHERE THE PATH CANNOT BE READ. osquery reads another user's executable path only
# with ptrace rights. Root on a host has them, and so does CI's ubuntu runner job, which
# runs the query with sudo. Root in a default Docker container does not, so there the path
# is '' and the row this scenario asserts cannot exist. That is a property of the
# container, and 82-linux-running covers what a container can see. Locally:
#   LINUX_DOCKER_ARGS='--cap-add SYS_PTRACE' test/run-linux.sh 83-linux-claude-running
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
try_user "the Claude Code native installer" \
  'curl --retry 3 -fsSL https://claude.ai/install.sh | bash' || true

as_user 'setsid bash -c "sleep 3600 | ~/.local/bin/claude mcp serve" </dev/null >/tmp/claude-mcp.log 2>&1 &' || true
for _ in $(seq 1 15); do
  pgrep -u "$SCENARIO_USER" -f 'claude mcp serve' >/dev/null && break
  sleep 2
done
pid=$(pgrep -u "$SCENARIO_USER" -x claude | head -1 || true)
if [ -z "$pid" ]; then
  echo "WARN: claude mcp serve is not running. It said:"
  sed 's/^/      /' /tmp/claude-mcp.log | tail -15
  exit 0
fi
echo "--- claude mcp serve is pid $pid, and osquery reads it as:"
sudo_maybe osqueryi --json "SELECT name, path FROM processes WHERE pid = $pid" | sed 's/^/      /'
# A count, not the path itself: --csv renders an empty string as "", which is not empty.
readable=$(sudo_maybe osqueryi --csv --header=false \
  "SELECT count(*) FROM processes WHERE pid = $pid AND path != ''" 2>/dev/null || echo 0)
[ "$readable" = 1 ] || { echo "SKIP: osquery cannot read another user's executable path here (no ptrace right)"; exit 3; }
