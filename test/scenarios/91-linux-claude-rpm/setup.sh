#!/bin/bash
# Claude Code from Anthropic's dnf repository, through the rpm_packages route: the rpm
# family's half of 89-linux-claude-deb. The package is the same shape on both families, an
# ELF at /usr/bin/claude and nothing under any home, so rpm's database row is the only
# evidence, as dpkg's is on apt.
#
# The repository is registered the way Anthropic documents it
# (https://code.claude.com/docs/en/setup#install-with-linux-package-managers), gpgcheck on,
# and the key is verified against the published fingerprint BEFORE it is imported: `dnf -y`
# would otherwise accept whatever key the repository served, and a changed key is what this
# scenario must report, not work around.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
[ "$(pm)" = dnf ] || { echo "SKIP: this scenario needs an rpm distro; 89-linux-claude-deb carries the apt repository"; exit 3; }
# Separately, not one transaction: amazonlinux:2023 ships curl-minimal, which `dnf install
# curl` conflicts with, and a failed transaction would take gnupg2 down with it and leave
# the fingerprint unchecked. need_curl installs curl only where there is none.
need_curl
need_pkgs gnupg2 || true

key_url=https://downloads.claude.ai/keys/claude-code.asc
fpr=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
retry "the Claude Code signing key" curl --retry 3 -fsSL -o /tmp/claude-code.asc "$key_url" \
  || { echo "FAIL: the signing key did not download"; exit 1; }
if command -v gpg >/dev/null 2>&1; then
  gpg --show-keys --with-colons /tmp/claude-code.asc 2>/dev/null | grep -q "^fpr:*:$fpr:" \
    || { echo "FAIL: the signing key's fingerprint is not $fpr"; exit 1; }
else
  echo "WARN: no gpg, so the key's fingerprint was not checked"
fi
try "importing the verified key into rpm" sudo_maybe rpm --import /tmp/claude-code.asc \
  || { echo "FAIL: rpm would not import the key"; exit 1; }
rm -f /tmp/claude-code.asc
sudo_maybe tee /etc/yum.repos.d/claude-code.repo >/dev/null <<'REPO'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
REPO
# About 290MB. Not a SKIP: a package that stops installing is what this scenario must report.
try "installing claude-code from dnf" sudo_maybe dnf -q -y install claude-code \
  || echo "WARN: claude-code did not install"
echo "--- what rpm recorded:"
rpm -q claude-code 2>/dev/null || echo "      no claude-code rpm"
echo "--- where the package put the binary:"
ls -la /usr/bin/claude 2>/dev/null || echo "      no /usr/bin/claude"
