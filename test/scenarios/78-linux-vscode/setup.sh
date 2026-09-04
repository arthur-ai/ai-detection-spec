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
try "installing the VS Code deb" sudo_maybe apt-get -qq install -y /tmp/code.deb \
  || try "dpkg -i for VS Code" sudo_maybe dpkg -i /tmp/code.deb \
  || echo "WARN: VS Code did not install"
rm -f /tmp/code.deb
code --version --no-sandbox 2>&1 | head -1 || true

# AS THE USER: extensions live in ~/.vscode/extensions, so installing as root would put
# them under /root and leave the /home branch -- the one a fleet has -- unexercised.
# --no-sandbox because there is no display and no user namespace in CI.
#
# `try_user` RATHER THAN `|| echo WARN`. The first CI run of this scenario failed with
# nothing but "WARN: install failed" in the log, because the command's own error went to
# /dev/null -- so the run proved only that something was wrong. It reproduced nowhere
# locally, root or non-root, arm64 or amd64, which is exactly when the reason matters.
for ext in saoudrizwan.claude-dev continue.continue; do
  try_user "installing $ext" "code --no-sandbox --install-extension $ext --force" || true
done
# as_user, NOT try_user: `try` is quiet on success by design, so wrapping an
# INFORMATIONAL command in it printed a header with nothing under it.
echo "--- extensions the CLI reports:"
as_user 'code --no-sandbox --list-extensions --show-versions' 2>&1 | sed 's/^/      /' || true
echo "--- extensions on disk:"
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
ls -1 "$home/.vscode/extensions" 2>&1 | head -10 \
  || diagnose code
