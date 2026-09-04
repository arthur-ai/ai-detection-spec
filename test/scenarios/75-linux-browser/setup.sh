#!/bin/bash
# A REAL BROWSER, NOT A PLANTED DIRECTORY TREE, and that is a measured decision rather
# than thoroughness for its own sake.
#
# Three hand-built Linux profiles returned ZERO rows from chrome_extensions -- including
# one under /root, owned by root, with a readable Preferences file the `file` table could
# see. osquery validates a profile by reading its config files and a fixture that merely
# looks right does not pass. A real `google-chrome --headless=new --user-data-dir` profile
# returned a row immediately. So the browser has to actually run once.
#
# THE EXTENSION IDENTIFIER WILL BE EMPTY and that is correct, not a failure. osquery
# derives `identifier` from the manifest `key`, which a planted or unpacked extension does
# not carry -- verified here, with osquery logging
# `ExtensionKeyError (The 'key' property is missing from the extension manifest)`. The
# Web Store's signed CRX does carry it, which is what 45-claude-extension uses to get a
# real id on macOS. This scenario asserts the BRANCH works: permissions, the <all_urls>
# flag and the profile path. It does not assert an id it cannot produce.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user

arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
# Google ships no Linux arm64 Chrome at all. Chromium would need a snap on Ubuntu, and a
# snap relocates the profile to ~/snap/chromium/common/chromium -- which osquery DOES
# scan, but that is a different path than the one a fleet's Chrome uses. Skipping is
# honest here: the CI runner is x86_64 and runs this for real.
[ "$arch" = amd64 ] || { echo "SKIP: Google ships no Linux $arch Chrome build"; exit 3; }

curl -fsSLo /tmp/chrome.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  || { echo "SKIP: Chrome download failed"; exit 3; }
sudo_maybe apt-get -qq install -y /tmp/chrome.deb >/dev/null 2>&1 \
  || echo "WARN: Chrome install failed"
rm -f /tmp/chrome.deb

# Let Chrome scaffold its own profile. --no-sandbox because CI has no user namespaces.
as_user 'google-chrome --headless=new --no-sandbox --disable-gpu \
  --user-data-dir=$HOME/.config/google-chrome --dump-dom about:blank' >/dev/null 2>&1 \
  || echo "WARN: headless Chrome run failed"

# An extension planted into that REAL profile, the same move 40-browser makes on macOS.
# The permissions and the <all_urls> host_permission are what the assertion reads.
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
ext="$home/.config/google-chrome/Default/Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0.0_0"
sudo_maybe mkdir -p "$ext"
sudo_maybe tee "$ext/manifest.json" >/dev/null <<'MANIFEST'
{"name":"Fixture agent extension","version":"1.0.0","manifest_version":3,
 "permissions":["tabs","cookies","nativeMessaging"],
 "host_permissions":["<all_urls>"]}
MANIFEST

# A native-messaging manifest in the USER scope, whose directory name is `NativeMessagingHosts`
# -- mixed case -- while the system scope uses `native-messaging-hosts`. osquery's LIKE is
# case-sensitive, so getting one of the two wrong returns half the answer with no error.
# Both spellings were read off this same real install.
sudo_maybe mkdir -p "$home/.config/google-chrome/NativeMessagingHosts"
sudo_maybe tee "$home/.config/google-chrome/NativeMessagingHosts/com.anthropic.claude_browser_extension.json" >/dev/null <<'NMH'
{"name":"com.anthropic.claude_browser_extension","type":"stdio",
 "path":"/opt/fixture/bridge","allowed_origins":["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]}
NMH
sudo_maybe chown -R "$SCENARIO_USER:$SCENARIO_USER" "$home/.config"
