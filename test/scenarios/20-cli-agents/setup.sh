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

# Four more agents that ship on npm. Installed here rather than left as catalog
# exceptions, because a real install is the standard and every one of these had an
# unattended path available -- the only thing missing was this.
#
# Each package name was READ OFF THE REGISTRY before being trusted. Checking them is
# also what retired two catalog entries: npm's `mcp` turned out to be Mintlify's package
# rather than the protocol SDK, and the SDK itself is a LIBRARY an agent is built with --
# agent tooling, not an agent -- so neither is scanned for any more.
#
# npm is chosen over Homebrew for gemini-cli and copilot-cli deliberately. Both also
# ship a formula/cask, and installing both ways would have them fight over the same
# binary; npm is the primary distribution. The Homebrew identifiers stay unexercised
# and docs/agents.md says so per-identifier -- the AGENT meets the standard, one of
# its routes is verified, and the report does not pretend otherwise.
#
# `|| echo WARN` so a network failure does not abort the whole scenario. It still
# FAILS, in the assertion, where the reason is visible: a missing must_find names the
# agent, while an aborted setup names nothing.
for pkg in @google/gemini-cli @github/copilot cline; do
  npm install -g "$pkg" || echo "WARN: $pkg install failed"
done
