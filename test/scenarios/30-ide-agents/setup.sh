#!/bin/zsh
# 30-ide-agents -- agents that ship as VS Code extensions and JetBrains plugins, on macOS.
#
# The macOS half of four Linux scenarios: 78 and 85 (VS Code), 80 and 86 (JetBrains). There
# they are split to hold controls -- Cline against Roo Code's `roo-cline`, Claude Code against
# Cline's `claude-dev` -- and those hold there, on the same matcher. Here every value is
# installed on one host, so each is proved on macOS once.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

# VS CODE from Microsoft's universal build, into /Applications, unless the image has it.
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
# install_vscode_ext). Running out fails the assertions, which name the extension.
for ext in anthropic.claude-code openai.chatgpt saoudrizwan.claude-dev continue.continue \
           rooveterinaryinc.roo-cline kilocode.kilo-code augment.vscode-augment \
           google.geminicodeassist amazonwebservices.amazon-q-vscode sourcegraph.cody-ai \
           danielsanmedium.dscodegpt; do
  retry "installing $ext" "$CODE" --install-extension "$ext" --force || true
done
# BLACKBOX IS UNPUBLISHED and still served by URL; 85-linux-vscode-agents says why.
for spec in blackbox/2.8.53 blackboxagent/3.7.0; do
  vsix="/tmp/${spec%/*}.vsix"
  retry "downloading blackboxapp.${spec%/*}" curl --retry 3 -fsSL --compressed -o "$vsix" \
    "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/blackboxapp/vsextensions/$spec/vspackage" \
    && retry "installing $vsix" "$CODE" --install-extension "$vsix" --force || true
done
echo "--- extensions on disk:"
ls -1 "$HOME/.vscode/extensions" 2>&1 | sed 's/^/      /'

# JETBRAINS PLUGINS, unpacked from the Marketplace's own zip into the directory an IDE uses,
# as lib/guest-linux.sh's install_jb_plugin does: no IDE. On macOS osquery reads
# ~/Library/Application Support/JetBrains/<Product>/plugins (jetbrains_plugins.h at 5.23.1).
#   22707 Continue   28247 Cline   17718 GitHub Copilot   24198 Gemini Code Assist
#   24267 Amazon Q   9682 Cody
dest="$HOME/Library/Application Support/JetBrains/IdeaIC2025.2/plugins"
mkdir -p "$dest"
jb_latest_update() {
  curl --retry 3 -fsSL "https://plugins.jetbrains.com/api/plugins/$1/updates?size=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'
}
for plugin in 22707 28247 17718 24198 24267 9682; do
  upd=$(retry "looking up plugin $plugin" jb_latest_update "$plugin") || continue
  retry "downloading plugin $plugin" curl --retry 3 -fsSL -o "/tmp/jb-$plugin.zip" \
    "https://plugins.jetbrains.com/plugin/download?updateId=$upd" || continue
  ditto -x -k "/tmp/jb-$plugin.zip" "$dest" || echo "WARN: plugin $plugin did not unpack"
done
echo "--- plugins on disk:"
ls -1 "$dest" 2>&1 | sed 's/^/      /'
