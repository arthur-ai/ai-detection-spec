#!/bin/bash
# Seven terminal coding agents through their current npm or PyPI names, each run once the
# way that writes its state directory without credentials. Read off this script's run on
# 2026-10-28; catalog/agents.yaml carries the versions.
#
#   Amp           @ampcode/cli            no top-level state directory
#   Factory Droid @factory/cli            ~/.factory on `droid exec`, not on --help
#   Crush         @charmland/crush        no top-level state directory
#   Qwen Code     @qwen-code/qwen-code    ~/.qwen on `qwen -p`, not on --help
#   Jules CLI     @google/jules           ~/.jules on `jules version`
#   Junie CLI     @jetbrains/junie        postinstall writes ~/.local/bin/junie; ~/.junie on --version
#   Mistral Vibe  mistral-vibe (uv tool)  ~/.vibe on `vibe -p`, not on --version
#
# SEPARATE from 94-linux-cli-agents-legacy, which installs the previous npm names: Amp's,
# Droid's and Junie's ship the same binary as these.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
# 22 because @qwen-code/qwen-code declares node >=22. The other packages accept 20.
need_node 22 || echo "WARN: Node 22 did not install"
need_user
need_pkgs python3 || true

for pkg in @ampcode/cli @factory/cli @charmland/crush @qwen-code/qwen-code @google/jules; do
  retry "npm install -g $pkg" try "npm install -g $pkg" \
    sudo_maybe npm install -g --no-fund --no-audit "$pkg" || true
done
# Junie's postinstall writes its shim under os.homedir(), so HOME is pinned: whether sudo
# resets it is the host's choice, and the assertion names /root.
retry "npm install -g @jetbrains/junie" try "npm install -g @jetbrains/junie" \
  sudo_maybe env HOME=/root npm install -g --no-fund --no-audit @jetbrains/junie || true
try "junie --version, which is what writes ~/.junie" \
  sudo_maybe env HOME=/root /root/.local/bin/junie --version || true

try_user "the uv installer" 'curl --retry 3 -fsSL https://astral.sh/uv/install.sh | sh' || true
try_user "uv tool install mistral-vibe" \
  '$HOME/.local/bin/uv tool install --python 3.12 mistral-vibe' || true

# Each of these fails at authentication AFTER writing its directory; that failure is the
# expected outcome, so only the directory is checked.
as_user 'droid exec hi </dev/null' >/dev/null 2>&1 || true
as_user 'qwen -p hi </dev/null' >/dev/null 2>&1 || true
try_user "jules version" 'jules version' || true
as_user '$HOME/.local/bin/vibe -p hi </dev/null' >/dev/null 2>&1 || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ 2>&1' | sed 's/^/      /'
