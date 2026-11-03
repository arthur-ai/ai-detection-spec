#!/bin/bash
# Terminal coding agents through their npm names, each run once the way that writes its state
# directory without credentials. Read off an npm install on 2026-10-29 and a container run on
# 2026-11-03; catalog/agents.yaml carries the versions.
#
#   Kimi Code       @moonshot-ai/kimi-code       ~/.kimi-code on `kimi -p hi`, not on --version
#   CodeBuddy Code  @tencent-ai/codebuddy-code   ~/.codebuddy on --help, not on --version
#   Qoder CLI       @qoder-ai/qodercli           postinstall writes ~/.qoder/entry/
#   Letta Code      @letta-ai/letta-code         ~/.letta on --version, which is not a value:
#                                                the Letta server writes it too
#
# SEPARATE from 84-linux-installers, whose curl installers put the same `kimi` and `qodercli`
# on PATH, and from 94-linux-cli-agents-legacy, whose Python kimi-cli this package's
# postinstall would rename to kimi-legacy.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
# 22 because @moonshot-ai/kimi-code declares node >=22.19 and @letta-ai/letta-code ^22.23.4.
need_node 22 || echo "WARN: Node 22 did not install"
# A COMPILER, for Letta: its node-pty ships no linux prebuild, so npm falls back to node-gyp,
# which needs make and a C++ compiler. A hosted runner has both; the Debian, Rocky, Fedora
# and Amazon Linux images have neither, and there the install failed with `not found: make`
# (CI run 40918177229). A fleet machine without a toolchain cannot install Letta from npm.
case "$(pm)" in
  apt) need_pkgs make g++ || echo "WARN: make and g++ did not install" ;;
  dnf) need_pkgs make gcc-c++ || echo "WARN: make and gcc-c++ did not install" ;;
esac

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

# `kimi -p hi` fails at sign-in AFTER writing ~/.kimi-code; that failure is the expected
# outcome, so only the directory is checked.
need_user
as_user 'kimi -p hi </dev/null' >/dev/null 2>&1 || true
try_user "codebuddy --help, which is what writes ~/.codebuddy" 'codebuddy --help >/dev/null' || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ 2>&1' | sed 's/^/      /'
