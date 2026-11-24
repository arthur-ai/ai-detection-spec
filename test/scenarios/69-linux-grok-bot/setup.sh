#!/bin/bash
# GROK BOT from its own .deb or .rpm, whichever this host's family takes. The app's update
# feed names only the AppImage, which leaves no package record and no .desktop file. The
# packages sit in the directory the feed names, so the feed's URL and version locate them.
# Its own scenario for the download, as 13 was split from 10.
#
# THE RPM IS NOT THE FILE THE DOWNLOAD PAGE LINKS: catalog/agents.yaml's grok-bot entry has
# the two names and the dates each was tried.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_pkgs python3 || true

case "$(uname -m)" in
  x86_64)  plat=x64 deb_arch=amd64 rpm_arch=x86_64 ;;
  aarch64) plat=arm64 deb_arch=arm64 rpm_arch=aarch64 ;;
  *) echo "SKIP: no Grok Bot package for $(uname -m)"; exit 3 ;;
esac
# The file's name with %s where the feed's version goes.
case "$(pm)" in
  apt) name="grok-bot_%s_$deb_arch.deb" sfx=.deb ;;
  dnf) name="grok-bot-%s-1.$rpm_arch.rpm" sfx=.rpm ;;
  *)   echo "SKIP: neither dpkg nor rpm here"; exit 3 ;;
esac
# Neither failure below is a SKIP: a changed feed or a moved package is what this scenario
# must report.
pkg_url() {
  curl --retry 3 -fsSL "https://api2.cursor.sh/updates/api/update/linux-$plat/sand/0.0.0/stable" \
    | python3 -c '
import json, sys
f = json.load(sys.stdin)
print("%s/%s" % (f["url"].rsplit("/", 1)[0], sys.argv[1] % f["version"]))' "$name"
}
url=$(retry "resolving the Grok Bot package URL" pkg_url) \
  || { echo "FAIL: could not resolve the Grok Bot package URL"; exit 1; }
echo "--- installing $url"
# mktemp, keeping the suffix the package manager keys on: a fixed /tmp name can be planted
# before the privileged install (need_chrome in lib/guest-linux.sh).
pkg=$(mktemp --suffix="$sfx")
retry "the Grok Bot download" curl --retry 3 -fsSLo "$pkg" "$url" \
  || { rm -f "$pkg"; echo "FAIL: the Grok Bot package did not download"; exit 1; }
case "$sfx" in
  # apt, not dpkg -i alone: dpkg leaves a package with unmet dependencies unconfigured, and
  # the query reads only `install ok installed`.
  .deb) try "installing the Grok Bot .deb" sudo_maybe env DEBIAN_FRONTEND=noninteractive \
            apt-get -qq install -y "$pkg" \
          || echo "WARN: Grok Bot did not install" ;;
  .rpm) try "installing the Grok Bot .rpm" sudo_maybe dnf -q -y install "$pkg" \
          || echo "WARN: Grok Bot did not install" ;;
esac
rm -f "$pkg"
echo "--- what the package manager recorded:"
{ dpkg -l 2>/dev/null | grep -E "^ii +grok-bot "; rpm -q grok-bot 2>/dev/null | grep -v "not installed"; } \
  || echo "      no grok-bot package"
