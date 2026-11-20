#!/bin/bash
# The Warp app from Warp's own .deb or .rpm, whichever this host's family takes, installed and
# not run. app.warp.dev/download?package=<deb|deb_arm64|rpm|rpm_arm64> redirects to the
# current build, so the scenario keeps proving the current package. The package sets up
# Warp's apt or yum repository for updates; nothing here reads that.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl

case "$(uname -m)" in
  x86_64)  sfx= ;;
  aarch64) sfx=_arm64 ;;
  *) echo "SKIP: no Warp package for $(uname -m)"; exit 3 ;;
esac
# mktemp, keeping the suffix the package manager keys on: a fixed /tmp name can be planted
# before the privileged install (need_chrome in lib/guest-linux.sh).
case "$(pm)" in
  # FRESH LISTS FIRST: the package's dependencies come from the distribution, and a hosted
  # runner's lists can name a build the mirror has dropped. libegl-mesa0 answered 404 on
  # both Ubuntu runners in probe run 44703507946.
  apt) retry "apt-get update" try "apt-get update" sudo_maybe apt-get -qq update || true
       pkg=$(mktemp /tmp/warp.XXXXXX.deb)
       retry "the Warp .deb" curl --retry 3 -fsSLo "$pkg" "https://app.warp.dev/download?package=deb$sfx" \
         || { rm -f "$pkg"; echo "FAIL: the Warp .deb did not download"; exit 1; }
       try "installing the Warp .deb" sudo_maybe apt-get -qq install -y "$pkg" \
         || echo "WARN: Warp did not install" ;;
  dnf) pkg=$(mktemp /tmp/warp.XXXXXX.rpm)
       retry "the Warp .rpm" curl --retry 3 -fsSLo "$pkg" "https://app.warp.dev/download?package=rpm$sfx" \
         || { rm -f "$pkg"; echo "FAIL: the Warp .rpm did not download"; exit 1; }
       try "installing the Warp .rpm" sudo_maybe dnf -q -y install "$pkg" \
         || echo "WARN: Warp did not install" ;;
  *)   echo "SKIP: neither dpkg nor rpm here"; exit 3 ;;
esac
rm -f "$pkg"
echo "--- what the package manager recorded:"
{ dpkg -l 2>/dev/null | grep -i warp; rpm -qa 2>/dev/null | grep -i warp; } || echo "      no warp package"
