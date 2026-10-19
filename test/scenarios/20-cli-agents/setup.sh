#!/bin/zsh
# Demo rows: Claude Code (47 devices), Codex CLI (12).
# Two different install shapes that both have to work.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
# Claude Code ships a native installer, NOT an npm package. It lands at
# ~/.local/bin/claude as a symlink into ~/.local/share/claude/versions/<ver>,
# which is also where the version string comes from - we never exec the binary.
curl --retry 3 -fsSL https://claude.ai/install.sh | bash || echo "WARN: claude code install failed"
# Codex CLI is a genuine npm global. 22 for Pi's installer, below.
need_node 22
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
# binary; npm is the primary distribution. The Homebrew identifiers are NOT unexercised
# -- 21-cli-agents-homebrew exists to install exactly those, on a machine with no npm
# copy to collide with, and both `gemini-cli` and `copilot-cli` are recorded from it.
# This comment used to end "the Homebrew identifiers stay unexercised", which was true
# when it was written and stopped being true the day that scenario landed.
#
# `|| echo WARN` so a network failure does not abort the whole scenario. It still
# FAILS, in the assertion, where the reason is visible: a missing must_find names the
# agent, while an aborted setup names nothing.
for pkg in @google/gemini-cli @github/copilot cline \
           opencode-ai @continuedev/cli @kilocode/cli @augmentcode/auggie; do
  npm install -g "$pkg" || echo "WARN: $pkg install failed"
done

# Pi's own installer, the route pi.dev lists first. It runs npm ci into ~/.pi/agent/install,
# which npm_packages never reads, so ~/.pi is the only thing here that can name Pi. It needs
# Node 22.19 or newer, and asks on /dev/tty only when it can open one: an Actions step and
# run.sh's ssh have none, so it takes its defaults.
pi_once() { curl --retry 3 -fsSL https://pi.dev/install.sh | sh && test -e "$HOME/.pi/agent/bin/pi"; }
retry "the Pi installer" pi_once || true

# INVOKED, NOT JUST INSTALLED. A state directory does not exist until the agent runs once,
# which is why ~/.codex read DID NOT APPEAR while a scenario was installing Codex CLI on every run.
# `--version` is the smallest invocation that is not a no-op and needs no credentials.
#
# NOT ASSERTED. Whether this particular agent writes its state directory on --version is
# unmeasured, and asserting it before knowing would be a guess wearing a test's clothes.
# The run records what actually appeared; if the directory shows up, coverage reports it,
# and if it does not, the gap stays visible and honest.
command -v codex >/dev/null 2>&1 && (codex --version >/dev/null 2>&1 || true)
