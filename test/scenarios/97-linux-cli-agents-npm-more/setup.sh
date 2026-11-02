#!/bin/bash
# Four terminal coding agents that herdr runs, through their npm names. Read off this
# script's runs on 2026-11-02; catalog/agents.yaml carries the versions.
#
#   MastraCode     mastracode                   npm -g; run, and writes no top-level directory
#   Command Code   command-code                 npm -g; ~/.commandcode on --version and -p
#   Devin CLI      devin                        npm -g; not run
#   Oh My Pi       @oh-my-pi/pi-coding-agent    bun install -g, its README's route; not run
#
# Devin CLI and Oh My Pi are NOT RUN, so their package is the only witness here: the curl
# installers in 98 and 99 prove their other values, on hosts of their own because both
# routes put the same command on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
# 22 because mastracode declares node >=22.19 and command-code >=22.
need_node 22 || echo "WARN: Node 22 did not install"
# The bun installer unzips its archive.
command -v unzip >/dev/null 2>&1 || need_pkgs unzip || echo "WARN: unzip did not install"

for pkg in mastracode command-code devin; do
  retry "npm install -g $pkg" try "npm install -g $pkg" \
    sudo_maybe npm install -g --no-fund --no-audit "$pkg" || true
done
try_user "the bun installer" 'curl --retry 3 -fsSL https://bun.sh/install | bash' || true
# BY PATH, as in 81: as_user's PATH does not carry ~/.bun/bin.
retry "bun install -g @oh-my-pi/pi-coding-agent" try_user "bun install -g @oh-my-pi/pi-coding-agent" \
  '~/.bun/bin/bun install -g @oh-my-pi/pi-coding-agent' || true

# Each fails without credentials; only what it leaves behind is checked.
as_user 'timeout 60 mastracode --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 mastracode -p hi </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 command-code --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 command-code -p hi </dev/null' >/dev/null 2>&1 || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ 2>&1' | sed 's/^/      /'
