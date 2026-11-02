#!/bin/bash
# Three terminal coding agents through their npm names, each run once.
#
#   MastraCode     mastracode                    npm -g
#   Command Code   command-code                  npm -g
#   Oh My Pi       @oh-my-pi/pi-coding-agent     bun install -g, the route its README recommends
#
# SEPARATE from 98-linux-installers-more, which installs Oh My Pi through its curl
# installer: both put an `omp` on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
# 22 because mastracode declares node >=22.19 and command-code >=22.
need_node 22 || echo "WARN: Node 22 did not install"
# The bun installer unzips its archive.
command -v unzip >/dev/null 2>&1 || need_pkgs unzip || echo "WARN: unzip did not install"

for pkg in mastracode command-code; do
  retry "npm install -g $pkg" try "npm install -g $pkg" \
    sudo_maybe npm install -g --no-fund --no-audit "$pkg" || true
done
try_user "the bun installer" 'curl --retry 3 -fsSL https://bun.sh/install | bash' || true
retry "bun install -g @oh-my-pi/pi-coding-agent" try_user "bun install -g @oh-my-pi/pi-coding-agent" \
  '~/.bun/bin/bun install -g @oh-my-pi/pi-coding-agent' || true

# Run once each, without credentials; whatever fails after writing its directory is fine.
as_user 'timeout 60 mastracode --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 mastracode -p hi </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 command-code --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 command-code -p hi </dev/null' >/dev/null 2>&1 || true
as_user 'PATH=$HOME/.bun/bin:$PATH timeout 60 omp --version </dev/null' >/dev/null 2>&1 || true
as_user 'PATH=$HOME/.bun/bin:$PATH timeout 60 omp -p hi </dev/null' >/dev/null 2>&1 || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ 2>&1' | sed 's/^/      /'
PROBE_NAME=97-linux-cli-agents-npm-more

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
