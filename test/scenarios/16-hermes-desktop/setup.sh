#!/bin/zsh
# PROBE ONLY: prints what the Hermes desktop package ships, as annotations.
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
note() { python3 -c 'import sys;t,m=sys.argv[1],sys.stdin.read();print("::notice title="+t+"::"+m[:6000].replace("%","%25").replace("\r","").replace("\n","%0A"))' "$1"; }
base=https://hermes-assets.nousresearch.com
feed="$(curl -fsSL --retry 2 "$base/releases/darwin/stable/stable-mac.yml" 2>&1)"
print -r -- "$feed" | note feed
url="$(print -r -- "$feed" | python3 -c '
import sys,re
for l in sys.stdin:
    m=re.search(r"(?:url|path):\s*[\x27\"]?([^\s\x27\"]+\.dmg)",l)
    if m: print(m.group(1)); break')"
dmg=/tmp/hermes.dmg
for u in "$url" "$base$url" "$base/$url" "$base/releases/darwin/stable/$url"; do
  case "$u" in http*) curl -fsSL --retry 2 -o $dmg "$u" && { echo "got $u"; break; } ;; esac
done
mnt="$(mktemp -d /tmp/dmg.XXXXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" $dmg >/dev/null
app="$(cd "$mnt" && ls -d *.app | head -1)"
{ echo "url=$url"; ls -la "$mnt"; echo "app=$app"; } | note dmg
ditto "$mnt/$app" "/Applications/$app"; hdiutil detach "$mnt" >/dev/null || true
P="/Applications/$app/Contents"
{ for k in CFBundleIdentifier CFBundleName CFBundleDisplayName CFBundleExecutable CFBundleShortVersionString; do echo "$k=$(plutil -extract $k raw "$P/Info.plist" 2>&1)"; done
  ls "$P/MacOS"; ls "$P/Resources" | head -40; find "$P" -maxdepth 6 -name 'hermes*' -type f | head -20
  find "$P" -name Info.plist -path '*Helpers*' -maxdepth 4 | while read -r f; do plutil -extract CFBundleIdentifier raw "$f"; done; } 2>&1 | note plist
sudo -n /usr/local/bin/osqueryi --json "SELECT bundle_identifier, bundle_short_version, name, path FROM apps WHERE path LIKE '/Applications/%'" | grep -i -B2 -A3 hermes | note osq-apps
# Launch, bounded, to see what a first run writes and what runs.
ls -la ~ | note home-before
open -g "/Applications/$app" & sleep 45
{ ps -axo pid,comm | grep -i -E 'hermes|python' | grep -v grep; echo ---; ls -la ~; echo ---; ls -la ~/.hermes 2>&1 | head; ls -d ~/Library/Application\ Support/* | grep -i hermes; ls -la ~/.local/bin 2>&1; } | note after-launch
sudo -n /usr/local/bin/osqueryi --json "SELECT p.name, p.path FROM processes p WHERE p.path LIKE '%ermes%'" | head -60 | note osq-proc
exit 0
