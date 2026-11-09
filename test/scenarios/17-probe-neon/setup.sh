#!/bin/zsh
# THROWAWAY PROBE, never merged: installs Opera Neon from the vendor's own endpoint and
# prints what it leaves, so catalog values are read off a real install.
HERE="$(cd "$(dirname "$0")" && pwd)"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'
main() {
source "$HERE/../../lib/guest.sh"
touch /tmp/probe-marker
echo "=== get.geo.opera.com listing"
curl -sSL -A "$UA" -m 30 https://get.geo.opera.com/pub/opera_neon/ | head -c 1500; echo
v=$(curl -sSL -A "$UA" -m 30 https://get.geo.opera.com/pub/opera_neon/ | grep -oE 'href="[0-9][0-9.]+/"' | sed 's/href="//; s/\/"//' | sort -V | tail -1)
echo "latest listed: $v"
if [ -n "$v" ]; then
  curl -sSL -A "$UA" -m 30 "https://get.geo.opera.com/pub/opera_neon/$v/" | head -c 800; echo
  curl -sSL -A "$UA" -m 30 "https://get.geo.opera.com/pub/opera_neon/$v/mac/" | head -c 1500; echo
  curl -sSL -A "$UA" -m 30 "https://get.geo.opera.com/pub/opera_neon/$v/win/" | head -c 1500; echo
fi
echo "=== the stable/mac zip"
curl -sSL -A "$UA" -m 120 -D /tmp/neon.hdr -o /tmp/neon.zip https://net.geo.opera.com/opera_neon/stable/mac
grep -i -E '^(content-disposition|content-type|location)' /tmp/neon.hdr
mkdir -p /tmp/neonzip && ditto -x -k /tmp/neon.zip /tmp/neonzip && find /tmp/neonzip -maxdepth 4 | head -30
inst=$(find /tmp/neonzip -maxdepth 2 -name '*.app' | head -1)
echo "installer: $inst"
[ -n "$inst" ] && plutil -p "$inst/Contents/Info.plist" | head -40
[ -n "$inst" ] && ls -la "$inst/Contents/MacOS" "$inst/Contents/Resources" | head -40
bin=$(ls "$inst/Contents/MacOS/"* 2>/dev/null | head -1)
[ -n "$bin" ] && strings "$bin" | grep -E '^--?[a-z][a-z-]{3,}' | sort -u | head -60
echo "=== run the installer, bounded"
if [ -n "$bin" ]; then
  ( "$bin" --silent --runimmediately --launchbrowser=0 > /tmp/inst.log 2>&1 & echo $! > /tmp/inst.pid )
  for i in $(seq 1 60); do ls -d /Applications/*Neon* 2>/dev/null && break; sleep 5; done
  sleep 20
  head -c 3000 /tmp/inst.log
  kill "$(cat /tmp/inst.pid)" 2>/dev/null
fi
pkill -f 'Opera Neon' 2>/dev/null
echo "=== apps installed after the marker"
for app in /Applications/*.app ~/Applications/*.app; do
  [ "$app" -nt /tmp/probe-marker ] || continue
  echo "$app: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  ls "$app/Contents/Library/LaunchAgents" "$app/Contents/Library/LaunchServices" "$app/Contents/Library" 2>/dev/null
done
echo "=== osqueryi apps"
sudo /usr/local/bin/osqueryi --json "SELECT name, bundle_identifier, bundle_short_version, path FROM apps WHERE name LIKE '%Opera%' OR name LIKE '%Neon%'"
echo "=== launchd"
sudo /usr/local/bin/osqueryi --json "SELECT label, path FROM launchd WHERE label LIKE '%opera%' OR label LIKE '%neon%'"
echo "=== files newer than the marker"
find ~ /Library -mindepth 1 -maxdepth 4 -newer /tmp/probe-marker 2>/dev/null | grep -i -E 'opera|neon' | head -40
}
main 2>&1 | tee /tmp/probe.out
python3 "$HERE/emit.py" /tmp/probe.out
exit 0
