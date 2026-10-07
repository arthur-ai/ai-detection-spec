#!/bin/bash
# Continue and Cline as JetBrains plugins: the second editor route for two agents 78 proves
# through VS Code, on a table osquery grew in 5.18.0.
#
# NO IDE. The way 45-claude-extension unpacks the Web Store's own CRX into a real profile,
# this unpacks the Marketplace's own zip into the directory an IDE unpacks it into. The
# identifier is the zip's root directory, which the vendor ships. The IDE's install path is
# therefore untested, and expected.json says so.
#
# THE LINUX DIRECTORY HAS NO plugins/ SUFFIX: osquery reads ~/.local/share/JetBrains/
# <Product>% here and .../plugins only on macOS. One level deeper returns zero rows and no
# error.
#
# About 620MB of downloads: both plugins bundle per-platform binaries.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
dest="$home/.local/share/JetBrains/IdeaIC2025.2"
as_user "mkdir -p '$dest'"

# AS THE USER: jetbrains_plugins is per uid, and the /home branch is the one a fleet has.
#
# A FAILED DOWNLOAD FAILS THE ASSERTIONS rather than exiting 3, for the reason 78 gives:
# from in here an outage looks the same as a plugin that is gone for good, and a skip
# would hide the second. curl's own retries cover the transient case.
for plugin in 22707 28247; do   # Marketplace ids: Continue, Cline
  upd=$(curl --retry 3 -fsSL "https://plugins.jetbrains.com/api/plugins/$plugin/updates?size=1" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])') \
    || { echo "WARN: the Marketplace returned no update for plugin $plugin"; continue; }
  # The download URL answers 301 to /files/<plugin>/<update>/<name>.zip; -L follows it.
  try_user "downloading plugin $plugin update $upd" \
    "curl --retry 3 -fsSL -o /tmp/jb-$plugin.zip 'https://plugins.jetbrains.com/plugin/download?updateId=$upd'" \
    || continue
  # python's zipfile rather than unzip: one fewer package on three families. The zip root
  # IS the plugin directory, so extractall lands it where the IDE would.
  try_user "unpacking plugin $plugin" \
    "python3 -c \"import zipfile; zipfile.ZipFile('/tmp/jb-$plugin.zip').extractall('$dest')\"" || true
  as_user "rm -f /tmp/jb-$plugin.zip"
done
echo "--- plugins on disk:"
as_user_ls "$dest" | sed 's/^/      /'
echo "--- as osquery reads them:"
sudo_maybe osqueryi --json \
  "SELECT product_type, uid, name, vendor, version, path FROM users CROSS JOIN jetbrains_plugins USING (uid)" \
  | sed 's/^/      /' || diagnose osqueryi
