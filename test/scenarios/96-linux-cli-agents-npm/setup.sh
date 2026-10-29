#!/bin/bash
# Four terminal coding agents through their npm names. Read off an npm install on 2026-10-29;
# catalog/agents.yaml carries the versions.
#
#   Kimi Code       @moonshot-ai/kimi-code       no top-level state directory at install
#   CodeBuddy Code  @tencent-ai/codebuddy-code   no install scripts
#   Qoder CLI       @qoder-ai/qodercli           postinstall writes ~/.qoder/entry/
#   Letta Code      @letta-ai/letta-code         no top-level state directory at install
#
# Nothing is run after installing: the package rows and ~/.qoder are the claim.
#
# SEPARATE from 84-linux-installers, whose curl installers put the same `kimi` and `qodercli`
# on PATH, and from 94-linux-cli-agents-legacy, whose Python kimi-cli this package's
# postinstall would rename to kimi-legacy.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
# 22 because @moonshot-ai/kimi-code declares node >=22.19 and @letta-ai/letta-code ^22.23.4.
need_node 22 || echo "WARN: Node 22 did not install"

for pkg in @moonshot-ai/kimi-code @tencent-ai/codebuddy-code @letta-ai/letta-code; do
  retry "npm install -g $pkg" try "npm install -g $pkg" \
    sudo_maybe npm install -g --no-fund --no-audit "$pkg" || true
done
# Qoder's postinstall writes ~/.qoder under os.homedir(), so HOME is pinned as 93 pins it for
# Junie: whether sudo resets it is the host's choice, and the assertion names /root.
retry "npm install -g @qoder-ai/qodercli" try "npm install -g @qoder-ai/qodercli" \
  sudo_maybe env HOME=/root npm install -g --no-fund --no-audit @qoder-ai/qodercli || true
echo "--- the globals npm recorded:"
npm ls -g --depth=0 2>/dev/null | sed 's/^/      /'
