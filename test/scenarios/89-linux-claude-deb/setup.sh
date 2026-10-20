#!/bin/bash
# Claude Code from Anthropic's apt repository, through the deb_packages route. The native
# installer (71-linux-cli-agents, 83-linux-claude-running) leaves a link at
# ~/.local/bin/claude; the .deb puts an ELF at /usr/bin/claude and nothing under any home,
# so none of the home-rooted routes sees it and dpkg's row is the only evidence. Read off a
# real install on 2026-10-19, Ubuntu 22.04 on a GCE VM: `claude-code 2.1.292-1 amd64`,
# reported every hour by a fleet the classifier was calling clean.
#
# The repository is registered the way Anthropic documents it, key and fingerprint check
# included (https://code.claude.com/docs/en/setup#install-with-linux-package-managers),
# rather than fetching the .deb out of the pool: a fleet on apt is what this stands in for,
# and apt verifying the InRelease signature is part of what such a fleet installs.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
# The rpm family has a repository of its own that no scenario installs yet. On a dnf image
# the apt steps would fail and the assertion would then report the signature missing, which
# is the wrong thing to be red about.
[ "$(pm)" = apt ] || { echo "SKIP: the apt repository needs dpkg; the dnf repository is not a scenario yet"; exit 3; }
need_curl
need_pkgs gnupg ca-certificates || true

key_url=https://downloads.claude.ai/keys/claude-code.asc
fpr=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
sudo_maybe install -d -m 0755 /etc/apt/keyrings
retry "the Claude Code signing key" sudo_maybe curl --retry 3 -fsSL -o /etc/apt/keyrings/claude-code.asc "$key_url" \
  || { echo "FAIL: the signing key did not download"; exit 1; }
# The documented check, and not optional: without it apt trusts whatever the host served.
# A key that changed is what this scenario must report, not work around.
if command -v gpg >/dev/null 2>&1; then
  gpg --show-keys --with-colons /etc/apt/keyrings/claude-code.asc 2>/dev/null | grep -q "^fpr:*:$fpr:" \
    || { echo "FAIL: the signing key's fingerprint is not $fpr"; exit 1; }
else
  echo "WARN: no gpg, so the key's fingerprint was not checked"
fi
echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
  | sudo_maybe tee /etc/apt/sources.list.d/claude-code.list >/dev/null
export DEBIAN_FRONTEND=noninteractive
retry "apt-get update with the Claude Code repository" sudo_maybe apt-get -qq update \
  || { echo "FAIL: apt could not read the Claude Code repository"; exit 1; }
# About 250MB. Not a SKIP: a package that stops installing is what this scenario must report.
try "installing claude-code from apt" sudo_maybe apt-get -qq install -y claude-code \
  || echo "WARN: claude-code did not install"
echo "--- what dpkg recorded:"
dpkg -l 2>/dev/null | grep -iE "^i.*claude" || echo "      no claude package"
echo "--- where the package put the binary:"
ls -la /usr/bin/claude 2>/dev/null || echo "      no /usr/bin/claude"
