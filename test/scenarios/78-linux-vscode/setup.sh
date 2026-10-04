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
# The deb or the rpm, by family: Microsoft publishes both from the same URL shape, and
# the extension directory osquery reads is the same install either way.
case "$(pm)-$(uname -m)" in
  apt-x86_64)  build=linux-deb-x64   pkg=/tmp/code.deb ;;
  apt-aarch64) build=linux-deb-arm64 pkg=/tmp/code.deb ;;
  dnf-x86_64)  build=linux-rpm-x64   pkg=/tmp/code.rpm ;;
  dnf-aarch64) build=linux-rpm-arm64 pkg=/tmp/code.rpm ;;
  *) echo "SKIP: no VS Code package for $(pm) on $(uname -m)"; exit 3 ;;
esac
if [ "$(pm)" = apt ]; then
  # libasound2t64 is Ubuntu 24.04's name for the ALSA library and Debian 12 still says
  # libasound2. apt resolves the deb's dependencies itself when the install goes through
  # apt-get, so this only matters on the dpkg -i fallback.
  need_pkgs libasound2t64 || need_pkgs libasound2 || true
fi
curl -fsSLo "$pkg" "https://update.code.visualstudio.com/latest/$build/stable" \
  || { echo "SKIP: VS Code download failed"; exit 3; }
if [ "$(pm)" = apt ]; then
  try "installing the VS Code deb" sudo_maybe apt-get -qq install -y "$pkg" \
    || try "dpkg -i for VS Code" sudo_maybe dpkg -i "$pkg" \
    || echo "WARN: VS Code did not install"
else
  try "installing the VS Code rpm" sudo_maybe dnf -q -y install "$pkg" \
    || echo "WARN: VS Code did not install"
fi
rm -f "$pkg"
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
as_user_ls "$home/.vscode/extensions" | head -10 || diagnose code
