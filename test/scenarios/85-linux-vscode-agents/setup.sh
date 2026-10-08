#!/bin/bash
# AGENTS THAT SHIP AS VS CODE EXTENSIONS, beside the two 78 proves. Each passed the test
# continue's catalog entry sets -- it writes files or runs commands -- read off its own
# package.json rather than its listing.
#
# SEPARATE FROM 78 so that 78 keeps its control: it installs saoudrizwan.claude-dev and
# forbids claude-code, which is what says Cline's id is not read as Claude Code's. Here the
# trap runs the other way -- rooveterinaryinc.roo-cline is a Cline fork whose id contains
# `cline` -- so this scenario forbids cline.
#
# Bare VS Code carries NONE of these: on a fresh install ~/.vscode/extensions does not
# exist until the first extension lands, measured 2026-10-07. That is the difference from
# Copilot, which VS Code bundles and docs/blind-spots.yaml records.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_vscode
install_vscode_ext anthropic.claude-code openai.chatgpt rooveterinaryinc.roo-cline \
  kilocode.kilo-code augment.vscode-augment google.geminicodeassist \
  amazonwebservices.amazon-q-vscode sourcegraph.cody-ai danielsanmedium.dscodegpt

# BLACKBOX IS UNPUBLISHED, and still installed on the machines that took it: every one of
# the publisher's extensions reads `unpublished` on the Marketplace (2026-10-07), so `code
# --install-extension blackboxapp.blackbox` answers "not found" -- with 5.3M installs behind
# blackbox and 2.9M behind blackboxagent. The Marketplace still serves each VSIX by URL, so
# that is installed instead: the vendor's artifact, through VS Code's own installer. When
# the URL stops answering, this goes red, and that is the supersession workflow's cue.
for spec in blackbox/2.8.53 blackboxagent/3.7.0; do
  vsix="/tmp/${spec%/*}.vsix"
  try_user "downloading blackboxapp.${spec%/*}" \
    "curl --retry 3 -fsSL --compressed -o $vsix https://marketplace.visualstudio.com/_apis/public/gallery/publishers/blackboxapp/vsextensions/$spec/vspackage" \
    && install_vscode_ext "$vsix"
done

echo "--- extensions on disk:"
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
as_user_ls "$home/.vscode/extensions" | sed 's/^/      /' || diagnose code
