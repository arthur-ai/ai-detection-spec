#!/bin/zsh
# OPERA NEON through the installer Opera's site serves, which fetches the current build and
# writes /Applications/Opera Neon.app. No cask exists. Its own job for the download, as 13
# was split from 10.
#
# THE INSTALLER LAUNCHES THE BROWSER even under --launchbrowser=0 (probe run 42675163069), so
# it is waited for, bounded, and then both are stopped: the bundle id is what is asserted.
# WARN rather than exit: the assertion names what is missing.
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
zip="$(mktemp /tmp/neon.XXXXXX)"
dir="$(mktemp -d /tmp/neon.XXXXXX)"
retry opera-neon curl -fsSL -o "$zip" 'https://net.geo.opera.com/opera_neon/stable/mac' \
  || { echo "WARN: the Opera Neon installer did not download"; exit 0; }
ditto -x -k "$zip" "$dir" || { echo "WARN: the Opera Neon installer did not unpack"; exit 0; }
"$dir/Opera Neon Installer.app/Contents/MacOS/Opera Neon Installer" \
  --silent --runimmediately --launchbrowser=0 >/dev/null 2>&1 &
inst=$!
plist="/Applications/Opera Neon.app/Contents/Info.plist"
for _ in $(seq 1 60); do
  kill -0 "$inst" 2>/dev/null || break
  [ -f "$plist" ] && { sleep 15; break; }
  sleep 5
done
kill "$inst" 2>/dev/null
pkill -f '/Applications/Opera Neon.app/' 2>/dev/null
if [ -f "$plist" ]; then
  for key in CFBundleIdentifier CFBundleShortVersionString; do
    plutil -extract "$key" raw "$plist" | sed "s/^/  $key /"
  done
else
  echo "WARN: the installer left no /Applications/Opera Neon.app"
fi
exit 0
