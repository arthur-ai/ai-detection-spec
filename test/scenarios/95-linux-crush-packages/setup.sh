#!/bin/bash
# Crush from its release's own .deb or .rpm, whichever this host's family takes. The
# package puts /usr/bin/crush and nothing under a home, so the package row is the only
# witness. Read off crush_0.98.2_amd64.deb on Ubuntu 24.04, 2026-10-28.
#
# The version comes from the release redirect rather than being pinned, so the scenario
# keeps proving the current package. Charm's apt and yum repositories are not used.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl

case "$(uname -m)" in
  x86_64)  deb_arch=amd64 rpm_arch=x86_64 ;;
  aarch64) deb_arch=arm64 rpm_arch=aarch64 ;;
  *) echo "SKIP: no Crush package for $(uname -m)"; exit 3 ;;
esac
# Read off the redirect of the latest release's checksums file, which names the tag.
tag=$(curl --retry 3 -fsS -o /dev/null -w '%{redirect_url}' \
  https://github.com/charmbracelet/crush/releases/latest/download/checksums.txt \
  | sed -n 's|.*/download/\([^/]*\)/checksums.txt$|\1|p')
[ -n "$tag" ] || { echo "FAIL: the latest Crush release did not resolve"; exit 1; }
v="${tag#v}"
base="https://github.com/charmbracelet/crush/releases/download/$tag"
# mktemp, keeping the suffix dnf keys on, for need_chrome's reason in lib/guest-linux.sh: a
# fixed /tmp name can be planted before the privileged install.
case "$(pm)" in
  apt) pkg=$(mktemp /tmp/crush.XXXXXX.deb)
       retry "the Crush .deb" curl --retry 3 -fsSLo "$pkg" "$base/crush_${v}_${deb_arch}.deb" \
         || { rm -f "$pkg"; echo "FAIL: the Crush .deb did not download"; exit 1; }
       try "dpkg -i crush" sudo_maybe dpkg -i "$pkg" || echo "WARN: crush did not install" ;;
  dnf) pkg=$(mktemp /tmp/crush.XXXXXX.rpm)
       retry "the Crush .rpm" curl --retry 3 -fsSLo "$pkg" "$base/crush-${v}-1.${rpm_arch}.rpm" \
         || { rm -f "$pkg"; echo "FAIL: the Crush .rpm did not download"; exit 1; }
       try "dnf install crush" sudo_maybe dnf -q -y install "$pkg" || echo "WARN: crush did not install" ;;
  *)   echo "SKIP: neither dpkg nor rpm here"; exit 3 ;;
esac
rm -f "$pkg"
echo "--- where the package put the binary:"
ls -la /usr/bin/crush 2>/dev/null || echo "      no /usr/bin/crush"
