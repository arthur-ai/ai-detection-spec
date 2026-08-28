#!/bin/zsh
# Demo rows: Claude Code (47 devices), Codex CLI (12).
# Two different install shapes that both have to work.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
# Claude Code ships a native installer, NOT an npm package. It lands at
# ~/.local/bin/claude as a symlink into ~/.local/share/claude/versions/<ver>,
# which is also where the version string comes from - we never exec the binary.
curl -fsSL https://claude.ai/install.sh | bash || echo "WARN: claude code install failed"
# Codex CLI is a genuine npm global.
need_node
npm install -g @openai/codex || echo "WARN: codex install failed"
