#!/bin/bash
# THE SCENARIO THAT RETIRES A BLIND SPOT. docs/blind-spots.yaml said "VS Code extensions
# -- osquery has no table for them at all", which was true when it was written and false
# from osquery 5.11.0. Cline ships as a VS Code extension first, so it was invisible on
# its primary route while the catalog listed it under npm.
#
# Continue is installed too and is DELIBERATELY NOT in the catalog. It is plainly an
# agent by this repo's own test, and adding it is a separate decision from adding Linux
# support -- so it must show up UNMATCHED rather than being claimed by Cline's signature.
# That assertion is what distinguishes "not catalogued yet" from "route quietly broken",
# and it is the honest way to carry a known gap: visible, in the tree, and under-reporting
# rather than over-reporting.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs libasound2t64 || true

arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
case "$arch" in
  amd64) build=linux-deb-x64 ;;
  arm64) build=linux-deb-arm64 ;;
  *) echo "SKIP: no VS Code deb for $arch"; exit 3 ;;
esac
curl -fsSLo /tmp/code.deb "https://update.code.visualstudio.com/latest/$build/stable" \
  || { echo "SKIP: VS Code download failed"; exit 3; }
sudo_maybe apt-get -qq install -y /tmp/code.deb >/dev/null 2>&1 \
  || sudo_maybe dpkg -i /tmp/code.deb >/dev/null 2>&1 \
  || echo "WARN: VS Code install failed"
rm -f /tmp/code.deb

# AS THE USER: extensions live in ~/.vscode/extensions, so installing as root would put
# them under /root and leave the /home branch -- the one a fleet has -- unexercised.
# --no-sandbox because there is no display and no user namespace in CI.
for ext in saoudrizwan.claude-dev continue.continue; do
  as_user "code --no-sandbox --install-extension $ext --force" >/dev/null 2>&1 \
    || echo "WARN: $ext install failed"
done
as_user 'code --no-sandbox --list-extensions --show-versions' 2>/dev/null || true
