#!/bin/bash
# Codewhale and Momentic's Mo through their npm names, read off probe run 45238894100 on
# 2026-11-23:
#
#   Codewhale      codewhale   npm -g; its postinstall fetches the release binaries
#   Momentic's Mo  qa          npm -g; the CLI for Mo, Momentic's QA agent
#
# Each is run only as `--version`, as the scenario's user, and expected.json holds
# ~/.codewhale absent after it, so each package is its agent's only witness here: Codewhale's
# curl installer and its ~/.codewhale are 119-linux-codewhale-octomind's, on a host of its
# own because both routes put `codewhale` on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
# 22 because codewhale's installer stops below Node 22, and qa declares ^22.12.0 || >=24.
need_node 22 || echo "WARN: Node 22 did not install"

for pkg in codewhale qa; do
  retry "npm install -g $pkg" try "npm install -g $pkg" \
    sudo_maybe npm install -g --no-fund --no-audit "$pkg" || true
done
echo "--- versions:"
for c in codewhale qa; do
  echo "      $c: $(as_user "timeout 30 $c --version </dev/null" 2>&1 | head -1)"
done
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ 2>&1' | sed 's/^/      /'
