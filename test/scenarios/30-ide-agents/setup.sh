#!/bin/zsh
# 30-ide-agents -- the agents found only as VS Code extensions, on macOS. Each is listed on
# macOS, and nothing proved one there: 85-linux-vscode-agents installs them on Linux. One
# extension per agent, its only witness here.
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
