#!/bin/bash
# Devin CLI, Cognition's terminal agent, through its curl installer, run once.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs tar gzip || true

try_user "the Devin CLI installer" 'curl --retry 3 -fsSL https://cli.devin.ai/install.sh | bash' || true
as_user 'timeout 60 devin --version </dev/null' >/dev/null 2>&1 || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
PROBE_NAME=99-linux-devin-cli

# ---- PROBE ONLY, never merged: emit what landed as one annotation, readable over REST.
probe_notice() {
  local tag body sql
  tag="$( (. /etc/os-release 2>/dev/null && echo "$ID-$VERSION_ID") || sw_vers -productVersion)-$(uname -m)"
  case "$(uname -s)" in Darwin) sql=osquery/dist/discovery-darwin.sql ;; *) sql=osquery/dist/discovery-linux.sql ;; esac
  body="$( {
    echo "homes:"
    as_user 'ls -1d ~/.*/ ~/.local/bin/* ~/.bun/bin/* ~/.bun/install/global/node_modules/* 2>&1' 2>&1 | head -60
    sudo_maybe sh -c 'ls -1d /root/.*/ /root/.local/bin/* 2>&1' 2>&1 | head -30
    echo "rows:"
    sudo_maybe osqueryi --json < "$sql" 2>&1 | grep -i -E "omp|mastra|command|devin|maki|prime|pi-coding|earendil|cognition|\"scan\"" | head -80
  } 2>&1 )"
  body="${body//'%'/%25}"; body="${body//$'\r'/}"; body="${body//$'\n'/%0A}"
  echo "::notice title=probe $PROBE_NAME $tag::$body"
}
probe_notice || true
