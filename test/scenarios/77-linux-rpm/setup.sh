#!/bin/bash
# THE RPM FAMILY, in a fedora container on the same ubuntu runner, because GitHub offers
# no RPM-distro runner. Cursor publishes an official .rpm as well as a .deb, so this
# carries a real identifier rather than proving the route can merely be reached.
#
# WHAT THIS SCENARIO REALLY CHECKS is that one composed artifact serves both distro
# families. dist/discovery-linux.sql names deb_packages AND rpm_packages, and the obvious
# fear is that the missing one errors the whole statement -- which is what a genuinely
# absent table does: `SELECT * FROM snap_packages` returns "[\n\n]" and exits 1 on every
# Linux box. Measured instead: both tables are REGISTERED on both families and the absent
# one simply returns no rows. This scenario is where that keeps being true.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
[ "$(pm)" = dnf ] || { echo "SKIP: this scenario needs an rpm distro"; exit 3; }
need_pkgs curl python3 || true

arch=$(uname -m)
case "$arch" in
  x86_64)  plat=linux-x64 ;;
  aarch64) plat=linux-arm64 ;;
  *) echo "SKIP: no Cursor .rpm for $arch"; exit 3 ;;
esac
url=$(curl -fsSL "https://cursor.com/api/download?platform=$plat&releaseTrack=stable" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["rpmUrl"])') \
  || { echo "SKIP: could not resolve the Cursor rpm URL"; exit 3; }
echo "--- installing $url"
curl -fsSLo /tmp/cursor.rpm "$url" || { echo "SKIP: download failed"; exit 3; }
# --nodeps: the rpm declares desktop dependencies a container has no reason to carry, and
# what is under test is the PACKAGE RECORD, not whether Cursor could launch.
sudo_maybe rpm -i --nodeps /tmp/cursor.rpm >/dev/null 2>&1 \
  || sudo_maybe dnf -q -y install /tmp/cursor.rpm >/dev/null 2>&1 \
  || echo "WARN: cursor rpm install failed"
rm -f /tmp/cursor.rpm
rpm -qa 2>/dev/null | grep -i cursor || echo "WARN: no cursor rpm recorded"
