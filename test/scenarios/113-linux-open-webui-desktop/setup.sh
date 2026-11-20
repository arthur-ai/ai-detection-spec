#!/bin/bash
# Open WebUI Desktop from its latest release's .deb, installed and not run. The release ships
# a .deb, an AppImage, a snap and a flatpak for Linux, and no .rpm, so a dnf host skips.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
[ "$(pm)" = apt ] || { echo "SKIP: Open WebUI Desktop ships no .rpm, only a .deb"; exit 3; }
need_curl

arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
case "$arch" in
  amd64|arm64) ;;
  *) echo "SKIP: no Open WebUI Desktop .deb for $arch"; exit 3 ;;
esac
# Fresh lists first, for 112's reason: libegl-mesa0 answered 404 here too (ubuntu-24.04-arm,
# probe run 44703507946).
retry "apt-get update" try "apt-get update" sudo_maybe apt-get -qq update || true
pkg=$(mktemp /tmp/open-webui.XXXXXX.deb)
retry "the Open WebUI Desktop .deb" curl --retry 3 -fsSLo "$pkg" \
  "https://github.com/open-webui/desktop/releases/latest/download/open-webui_${arch}.deb" \
  || { rm -f "$pkg"; echo "FAIL: the Open WebUI Desktop .deb did not download"; exit 1; }
try "installing the Open WebUI Desktop .deb" sudo_maybe apt-get -qq install -y "$pkg" \
  || echo "WARN: Open WebUI Desktop did not install"
rm -f "$pkg"
echo "--- what dpkg recorded:"
dpkg -l 2>/dev/null | grep -i webui || echo "      no open-webui package"
