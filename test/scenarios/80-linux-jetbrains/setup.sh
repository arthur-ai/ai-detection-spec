#!/bin/bash
# Continue and Cline as JetBrains plugins: the second editor route for two agents 78 proves
# through VS Code, on a table osquery grew in 5.18.0.
#
# NO IDE. install_jb_plugin unpacks the Marketplace's own zip into the directory an IDE
# unpacks it into, so the IDE's install path is untested, and expected.json says so.
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
install_jb_plugin "$dest" 22707 28247   # Marketplace ids: Continue, Cline
echo "--- plugins on disk:"
as_user_ls "$dest" | sed 's/^/      /'
echo "--- as osquery reads them:"
sudo_maybe osqueryi --json \
  "SELECT product_type, uid, name, vendor, version, path FROM users CROSS JOIN jetbrains_plugins USING (uid)" \
  | sed 's/^/      /' || diagnose osqueryi
