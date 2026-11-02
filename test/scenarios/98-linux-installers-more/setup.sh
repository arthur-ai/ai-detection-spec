#!/bin/bash
# Three terminal coding agents through their vendors' curl installers, each run once.
#
#   Maki          maki.sh/install.sh
#   Prime Agent   app.primeintellect.ai/prime-agent/install.sh
#   Oh My Pi      omp.sh/install, with no bun on the host, so it fetches the prebuilt binary
#
# SEPARATE from 97-linux-cli-agents-npm-more, which installs Oh My Pi through bun.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs tar gzip || true

try_user "the Maki installer" 'curl --retry 3 -fsSL https://maki.sh/install.sh | sh' || true
try_user "the Prime Agent installer" 'curl --retry 3 -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh' || true
try_user "the Oh My Pi installer" 'curl --retry 3 -fsSL https://omp.sh/install | sh' || true

as_user 'timeout 60 maki --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 prime-agent --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 omp --version </dev/null' >/dev/null 2>&1 || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
PROBE_NAME=98-linux-installers-more

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
