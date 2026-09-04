#!/bin/bash
# THE SCENARIO THAT PROVES THE POINT OF THE WHOLE LINUX PORT: every identifier asserted
# here ALREADY EXISTED in the catalog before Linux was supported at all. The npm route
# and the `~/`-rooted path routes are platform-independent, so what was missing was never
# the signatures -- it was queries that looked in /home and /root, and a matcher whose
# HOME_ROOTS covered them. Nothing in catalog/agents.yaml was added for this scenario.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_node
need_user

# Claude Code ships a native installer, not an npm package. It lands at
# ~/.local/bin/claude as a symlink into ~/.local/share/claude/versions/<ver>. Run AS THE
# USER, not as root, so it lands under /home/dana and exercises the branch a real fleet
# has rather than the /root one.
as_user 'curl -fsSL https://claude.ai/install.sh | bash' || echo "WARN: claude code install failed"

# Genuine npm globals. Installed system-wide, which on Linux is
# /usr/local/lib/node_modules -- npm_packages reports it with no path assumption in the
# query, and the structural predicate that bounds the recursion was measured on Linux
# too: 329 rows unbounded, 1 with it.
for pkg in @openai/codex @google/gemini-cli @github/copilot cline; do
  need_pkgs >/dev/null 2>&1 || true
  sudo_maybe npm install -g --no-fund --no-audit "$pkg" >/dev/null 2>&1 \
    || echo "WARN: $pkg install failed"
done

# INVOKED, NOT JUST INSTALLED. A state directory does not exist until the agent runs
# once, which is why ~/.codex read DID NOT APPEAR while a macOS scenario installed Codex
# CLI on every run. NOT ASSERTED -- whether these write their state dir on --version is
# unmeasured, and the run records what actually appeared.
as_user 'codex --version' >/dev/null 2>&1 || true
as_user 'claude --version' >/dev/null 2>&1 || true
