#!/bin/bash
# THE ONE SCENARIO THAT CARRIES GENUINELY NEW IDENTIFIERS, and it installs the real
# 200MB .deb to get them. Cursor publishes an official deb and rpm from
# cursor.com/api/download, so neither package route has to stand in for the other.
#
# It also gets a negative control for free, which is the part worth reading: Ubuntu ships
# `libxcursor1` and `libwayland-cursor0`, both real packages whose names contain `cursor`.
# The deb_packages route matches EXACTLY, so both must be declined -- and expected.json
# asserts that, because "correctly declined" and "never looked at" are indistinguishable
# without it. Same shape as `libxdmcp` versus `mcp`.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
# The rpm family runs this install as 77-linux-rpm. On a dnf image the deb would fail to
# install and the assertion would then report the signature missing, which is the wrong
# thing to be red about.
[ "$(pm)" = apt ] || { echo "SKIP: the .deb needs dpkg; 77-linux-rpm carries the rpm"; exit 3; }
need_curl
need_pkgs python3 || true

arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
case "$arch" in
  amd64) plat=linux-x64 ;;
  arm64) plat=linux-arm64 ;;
  *) echo "SKIP: no Cursor .deb for $arch"; exit 3 ;;
esac

# The URL comes from the vendor's own API rather than being pinned, because a pinned
# version goes stale silently and the scenario would then prove that an old build's
# identifier still resolves. The IDENTIFIER is read off the install by osquery, which is
# what makes this a fact rather than a download.
#
# Neither failure below is a SKIP: a changed API or a moved package is what this scenario
# must report. See retry in lib/guest-linux.sh.
cursor_url() {
  curl --retry 3 -fsSL "https://cursor.com/api/download?platform=$plat&releaseTrack=stable" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["debUrl"])'
}
url=$(retry "resolving the Cursor download URL" cursor_url) \
  || { echo "FAIL: could not resolve the Cursor download URL"; exit 1; }
echo "--- installing $url"
retry "the Cursor download" curl --retry 3 -fsSLo /tmp/cursor.deb "$url" \
  || { echo "FAIL: the Cursor .deb did not download"; exit 1; }
try "installing the Cursor .deb" sudo_maybe apt-get -qq install -y /tmp/cursor.deb \
  || try "dpkg -i for Cursor" sudo_maybe dpkg -i /tmp/cursor.deb \
  || echo "WARN: Cursor did not install"
echo "--- what dpkg recorded:"
dpkg -l 2>/dev/null | grep -iE "^i.*cursor" || echo "      no cursor package"
rm -f /tmp/cursor.deb
