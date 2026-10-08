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
# Neither failure below is a SKIP: a changed API or a moved package is what this scenario
# must report. See retry in lib/guest-linux.sh.
cursor_url() {
  curl --retry 3 -fsSL "https://cursor.com/api/download?platform=$plat&releaseTrack=stable" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["rpmUrl"])'
}
url=$(retry "resolving the Cursor rpm URL" cursor_url) \
  || { echo "FAIL: could not resolve the Cursor rpm URL"; exit 1; }
echo "--- installing $url"
retry "the Cursor download" curl --retry 3 -fsSLo /tmp/cursor.rpm "$url" \
  || { echo "FAIL: the Cursor .rpm did not download"; exit 1; }
# --nodeps: the rpm declares desktop dependencies a container has no reason to carry, and
# what is under test is the PACKAGE RECORD, not whether Cursor could launch.
try "rpm -i --nodeps of the Cursor rpm" sudo_maybe rpm -i --nodeps /tmp/cursor.rpm \
  || try "dnf install of the Cursor rpm" sudo_maybe dnf -q -y install /tmp/cursor.rpm \
  || echo "WARN: Cursor did not install"
rm -f /tmp/cursor.rpm
rpm -qa 2>/dev/null | grep -i cursor || echo "WARN: no cursor rpm recorded"
