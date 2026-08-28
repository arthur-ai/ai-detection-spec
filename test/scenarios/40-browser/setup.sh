#!/bin/zsh
# Demo row: Monica AI extension (31 devices) + demo step 3, the <all_urls> and
# native-messaging-bridge finding. This is the beat the shipped glob would have missed.
#
# REAL: Chrome, and Claude Desktop which writes its own native messaging host manifest.
# SYNTHETIC: the extension payload and one extra NMH manifest.
#
# Synthetic is the right call here and not a shortcut: what breaks in this area is
# glob depth and manifest parsing, not our ability to download from the Web Store.
# Forcing a Web Store install would add a network dependency and a hardcoded extension
# id we have not verified, in exchange for testing nothing extra.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install --cask google-chrome
brew install --cask claude          # writes com.anthropic.claude_browser_extension.json

# `open -a` needs an Aqua session, which SSH does not provide. Drive the binary directly
# in headless mode so Chrome still scaffolds Local State / Preferences / the Default
# profile - osquery's chrome_extensions enumerates profiles from those, not from the
# Extensions directory alone.
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --no-first-run --no-default-browser-check --disable-gpu \
          --user-data-dir="$HOME/Library/Application Support/Google/Chrome" \
          about:blank >/tmp/chrome.log 2>&1 &
sleep 20
pkill -x "Google Chrome" || true
sleep 3

PROF="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
EXT_ID="kbhkmjgjmpbaeoinipbngmmpjppjlkmm"     # synthetic id, 32 chars a-p, Web-Store shaped
mkdir -p "$PROF/$EXT_ID/1.4.2_0"
cat > "$PROF/$EXT_ID/1.4.2_0/manifest.json" <<'JSON'
{
  "manifest_version": 3,
  "name": "Monica AI Assistant (test fixture)",
  "version": "1.4.2",
  "description": "Synthetic fixture for endpoint discovery tests.",
  "host_permissions": ["<all_urls>"],
  "permissions": ["tabs","cookies","scripting","nativeMessaging","downloads","clipboardRead"]
}
JSON

# NMH at the TWO-component depth (Google/Chrome). The one-% glob never matched this.
NMH="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$NMH"
cat > "$NMH/ai.arthur.test_bridge.json" <<'JSON'
{
  "name": "ai.arthur.test_bridge",
  "description": "Synthetic native messaging host fixture.",
  "path": "/usr/bin/true",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://kbhkmjgjmpbaeoinipbngmmpjppjlkmm/"]
}
JSON
