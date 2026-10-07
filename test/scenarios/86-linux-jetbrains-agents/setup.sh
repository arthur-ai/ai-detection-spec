#!/bin/bash
# FOUR VENDORS' AGENTS AS JETBRAINS PLUGINS, unpacked the way 80-linux-jetbrains unpacks
# Continue and Cline. Kept apart from 80, whose downloads are already about 620MB, so a
# Marketplace failure here names these four rather than all six.
#
#   17718  GitHub Copilot       carried on copilot-cli. A Marketplace install, unlike the
#                               VS Code blind spot, where the editor bundles Copilot
#   24198  Gemini Code Assist
#   24267  Amazon Q             AWS ends support for its IDE plugins on 2027-04-30, per the
#                               Marketplace listing on 2026-10-07; installed machines remain
#   9682   Cody
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
dest="$home/.local/share/JetBrains/IdeaIC2025.2"
install_jb_plugin "$dest" 17718 24198 24267 9682
echo "--- plugins on disk:"
as_user_ls "$dest" | sed 's/^/      /'
echo "--- as osquery reads them:"
sudo_maybe osqueryi --json \
  "SELECT product_type, uid, name, vendor, version, path FROM users CROSS JOIN jetbrains_plugins USING (uid)" \
  | sed 's/^/      /' || diagnose osqueryi
