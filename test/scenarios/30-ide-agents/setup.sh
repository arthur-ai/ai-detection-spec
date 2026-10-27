#!/bin/zsh
# 30-ide-agents -- IDE extensions on macOS. Six agents found only as VS Code extensions, each
# listed on macOS where nothing else proves it (85-linux-vscode-agents installs them on
# Linux), one extension per agent; and one JetBrains plugin, for the query that reads them.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

# VS Code from Microsoft's universal build, into /Applications, unless the image has it.
APP="/Applications/Visual Studio Code.app"
if [ ! -d "$APP" ]; then
  retry "the VS Code download" curl --retry 3 -fsSLo /tmp/vscode.zip \
    https://update.code.visualstudio.com/latest/darwin-universal/stable \
    || { echo "FAIL: VS Code did not download, so no extension can be installed"; exit 1; }
  ditto -x -k /tmp/vscode.zip /Applications
fi
CODE="$APP/Contents/Resources/app/bin/code"
"$CODE" --version | head -1 || { echo "FAIL: no VS Code CLI at $CODE"; exit 1; }

# Through retry, for the Marketplace's transient failures (lib/guest-linux.sh,
# install_vscode_ext). Running out fails the assertion, which names the agent.
for ext in rooveterinaryinc.roo-cline google.geminicodeassist amazonwebservices.amazon-q-vscode \
           sourcegraph.cody-ai danielsanmedium.dscodegpt; do
  retry "installing $ext" "$CODE" --install-extension "$ext" --force || true
done
# BLACKBOX IS UNPUBLISHED and still served by URL; 85-linux-vscode-agents says why.
retry "downloading blackboxapp.blackbox" curl --retry 3 -fsSL --compressed -o /tmp/blackbox.vsix \
  https://marketplace.visualstudio.com/_apis/public/gallery/publishers/blackboxapp/vsextensions/blackbox/2.8.53/vspackage \
  && retry "installing blackboxapp.blackbox" "$CODE" --install-extension /tmp/blackbox.vsix --force \
  || true
echo "--- extensions on disk:"
ls -1 "$HOME/.vscode/extensions" 2>&1 | sed 's/^/      /'

# ONE JETBRAINS PLUGIN, for jetbrains.sql on macOS, which no other scenario reaches. Amazon Q
# (Marketplace 24267), the smallest of the catalog's six at 44.8 MB, unpacked from the
# Marketplace's own zip where an IDE puts it -- lib/guest-linux.sh's install_jb_plugin, with
# no IDE. On macOS osquery reads ~/Library/Application Support/JetBrains/<Product>/plugins
# (jetbrains_plugins.h at 5.23.1).
dest="$HOME/Library/Application Support/JetBrains/IdeaIC2025.2/plugins"
mkdir -p "$dest"
jb_latest_update() {
  curl --retry 3 -fsSL "https://plugins.jetbrains.com/api/plugins/$1/updates?size=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'
}
if upd=$(retry "looking up plugin 24267" jb_latest_update 24267) \
   && retry "downloading plugin 24267" curl --retry 3 -fsSL -o /tmp/jb-24267.zip \
        "https://plugins.jetbrains.com/plugin/download?updateId=$upd"; then
  ditto -x -k /tmp/jb-24267.zip "$dest" || echo "WARN: plugin 24267 did not unpack"
fi
echo "--- plugins on disk:"
ls -1 "$dest" 2>&1 | sed 's/^/      /'
