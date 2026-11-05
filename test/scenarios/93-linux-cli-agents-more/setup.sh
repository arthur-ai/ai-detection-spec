#!/bin/bash
# Terminal coding agents through their current npm or PyPI names, each run once the
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
#   DeepSeek dsh  @deepseek-ai/dsh        ~/.dsh on `dsh --profile headless`, not catalogued
#
# SEPARATE from 94-linux-cli-agents-legacy, which installs the previous npm names: Amp's,
# Droid's and Junie's ship the same binary as these.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
# 24 because @deepseek-ai/dsh 0.2.2-rc.1, its `latest` since 2026-11-05, declares node
# >=24.9.0, and under Node 22 npm resolves no version at all (ETARGET, run 42102236848).
# @qwen-code/qwen-code declares >=22; the others accept 20.
need_node 24 || echo "WARN: Node 24 did not install"
# NO COMPILER, unlike 96's for Letta: DeepSeek Harness pins node-pty 1.2.0-beta.15, which ships
# linux-x64 and linux-arm64 prebuilds, and installed without make or g++ in node:22-bookworm-slim
# on both arches on 2026-11-03.
need_user
need_pkgs python3 || true

for pkg in @ampcode/cli @factory/cli @charmland/crush @qwen-code/qwen-code @google/jules \
           @deepseek-ai/dsh; do
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
as_user 'timeout 60 dsh --profile headless hi </dev/null' >/dev/null 2>&1 || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ 2>&1' | sed 's/^/      /'
# PROBE ONLY, not for main.
os_id="$(. /etc/os-release && printf '%s-%s' "${ID:-linux}" "${VERSION_ID:-}")-$(uname -m)"
echo "::notice title=probe 93 $os_id::node=$(node --version 2>&1) $(npm ls -g --depth=0 2>/dev/null | grep -E '@ampcode|@factory|@charmland|@qwen-code|@google/jules|@deepseek-ai|@jetbrains' | sed 's/.* //' | tr '\n' ' ') vibe=$(as_user 'ls ~/.local/share/uv/tools 2>&1' | tr '\n' ' ') dots=$(as_user 'ls -1d ~/.*/ 2>/dev/null | tr "\n" " "')"
