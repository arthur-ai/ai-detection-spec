#!/bin/zsh
# THROWAWAY PROBE, never merged: installs candidates and prints what they ship, so the
# catalog values can be read off a real install before the real scenario is written.
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
touch /tmp/probe-marker
echo "=== brew install --cask manus"
retry manus brew install --cask manus || echo "WARN: manus failed"
echo "=== brew install --cask antigravity-cli"
retry antigravity-cli brew install --cask antigravity-cli || echo "WARN: antigravity-cli failed"
echo "=== Atlas: the disabled cask's last pinned URL"
A_URL='https://persistent.oaistatic.com/atlas/public/ChatGPT_Atlas_Desktop_public_1.2026.189.1_20260724200710000.dmg'
A_SHA=894b60a1276c65dd220984db647963e6245e06e2211fb3c61b944f6e1a013435
curl -sS -o /dev/null -w 'pinned dmg HTTP %{http_code} bytes %{size_download}\n' -r 0-1023 "$A_URL" || true
echo "=== Atlas appcast"
curl -sS -w '\nappcast HTTP %{http_code}\n' 'https://persistent.oaistatic.com/atlas/public/sparkle_public_appcast.xml' | head -c 4000; echo
if retry atlas curl -fsSL -o /tmp/atlas.dmg "$A_URL"; then
  echo "atlas sha256 $(shasum -a 256 /tmp/atlas.dmg | cut -d' ' -f1) (cask: $A_SHA)"
  install_dmg /tmp/atlas.dmg "ChatGPT Atlas.app" || echo "WARN: atlas dmg did not install"
fi
echo "=== Manus electron-builder feed"
curl -sS -w '\nfeed HTTP %{http_code}\n' https://download.manus.im/latest-mac.yml | head -c 2000; echo
echo "=== Info.plist of every app installed after the marker"
for app in /Applications/*.app; do
  [ "$app" -nt /tmp/probe-marker ] || continue
  echo "$app: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  ls "$app/Contents/Library/LaunchAgents" "$app/Contents/Library/LaunchServices" 2>/dev/null
done
echo "=== osqueryi apps"
sudo /usr/local/bin/osqueryi --json "SELECT name, bundle_identifier, bundle_short_version, path FROM apps WHERE path LIKE '/Applications/%' AND (name LIKE '%Manus%' OR name LIKE '%Atlas%')"
echo "=== osqueryi homebrew_packages"
sudo /usr/local/bin/osqueryi --json "SELECT name, version, type, path FROM homebrew_packages WHERE name IN ('manus','antigravity-cli','chatgpt-atlas')"
echo "=== agy"
ls -la "$(brew --prefix)/bin/agy" 2>&1
"$(brew --prefix)/bin/agy" --version 2>&1 | head -5
echo "=== files under ~ newer than the marker"
find ~ -mindepth 1 -maxdepth 3 -newer /tmp/probe-marker -not -path '*/Library/Caches/*' 2>/dev/null | grep -v -E '/Library/(Logs|Caches)|\.cache|/work/' | head -60
exit 0
