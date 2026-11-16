#!/bin/bash
# GROK BOT's .deb, from the directory the app's update feed names for its AppImage. The feed
# serves only the AppImage, which leaves no package record and no .desktop file, so the deb
# beside it is what the package and desktop routes can see. Its own scenario for the
# download, as 13 was split from 10.
#
# THE RPM IS NOT INSTALLED: the Grok_Bot_<ver>.rpm that cursor.com/download/bot links
# answered a 243-byte body that is not an rpm on 2026-11-16 (probe run 43929616449), so the
# rpm family exits 3 here rather than asserting a package nobody could install.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
[ "$(pm)" = apt ] || { echo "SKIP: the .deb needs dpkg, and Grok Bot's rpm is not served"; exit 3; }
need_curl
need_pkgs python3 || true

case "$(dpkg --print-architecture 2>/dev/null || echo amd64)" in
  amd64) plat=x64 deb_arch=amd64 ;;
  arm64) plat=arm64 deb_arch=arm64 ;;
  *) echo "SKIP: no Grok Bot .deb for this architecture"; exit 3 ;;
esac
# Neither failure below is a SKIP: a changed feed or a moved package is what this scenario
# must report.
deb_url() {
  curl --retry 3 -fsSL "https://api2.cursor.sh/updates/api/update/linux-$plat/sand/0.0.0/stable" \
    | python3 -c '
import json, sys
f = json.load(sys.stdin)
print("%s/grok-bot_%s_%s.deb" % (f["url"].rsplit("/", 1)[0], f["version"], sys.argv[1]))' "$deb_arch"
}
url=$(retry "resolving the Grok Bot deb URL" deb_url) \
  || { echo "FAIL: could not resolve the Grok Bot deb URL"; exit 1; }
echo "--- installing $url"
deb=$(mktemp --suffix=.deb)
retry "the Grok Bot download" curl --retry 3 -fsSLo "$deb" "$url" \
  || { echo "FAIL: the Grok Bot .deb did not download"; exit 1; }
# apt, not dpkg -i alone: dpkg leaves a package with unmet dependencies unconfigured, and
# the query reads only `install ok installed`.
try "installing the Grok Bot .deb" sudo_maybe env DEBIAN_FRONTEND=noninteractive \
    apt-get -qq install -y "$deb" \
  || echo "WARN: Grok Bot did not install"
rm -f "$deb"
echo "--- what dpkg recorded:"
dpkg -l 2>/dev/null | grep -E "^ii +grok-bot " || echo "      no grok-bot package"
