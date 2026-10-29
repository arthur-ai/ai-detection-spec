#!/bin/zsh
# THE SAME AGENTS, INSTALLED THROUGH HOMEBREW.
#
# 20-cli-agents installs these from npm, which is their primary distribution and the route
# most fleets use. Every one of them ALSO ships a formula or a cask, and those tokens sat
# in the catalog reading DID NOT APPEAR -- a scenario had installed the agent and the
# identifier never showed up, because it was installed the other way.
#
# SEPARATE from 20-cli-agents deliberately, not merged into it. Both routes put a binary of
# the same name on PATH, and installing both on one machine has them fight: whichever lands
# second wins, and the row for the loser is whatever the winner left behind. Two machines
# is the only way to test two routes honestly.
#
# Tokens verified against the Homebrew API before being written here. Some are casks and
# some are formulae, which is not guessable from the product name:
#
#     codex        cask        copilot-cli      cask
#     aider        formula     gemini-cli       formula
#     hermes-agent formula     opencode         formula
#     cursor-cli   cask        block-goose-cli  formula
#     kiro-cli     cask, with an app whose bundle id is com.amazon.codewhisperer
#     qwen-code    formula     mistral-vibe     formula
#     droid        cask, binary-only, Factory's
#
# cursor-cli's binary is cursor-agent and block-goose-cli's is goose, so none of the four
# collides with a command already installed here.
#
# hermes-agent is the formula token, and it is NOT the command it installs: the formula's
# install block writes three commands -- hermes, hermes-agent, hermes-acp -- while
# homebrew_packages renders the formula name. Installing it is the only way to prove that
# is what the row actually says.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew

# WARN rather than exit: a download failing is a network fact, and the assertion is where a
# missing agent should be reported, because it names WHICH one.
for f in aider gemini-cli hermes-agent opencode block-goose-cli qwen-code mistral-vibe; do
  brew install "$f" || echo "WARN: formula $f failed"
done
# muse-code is binary-only and links `muse`, which 14-meta-muse's installer also writes --
# the same two-routes-one-name reason this scenario exists, so it is here and not there.
for c in codex copilot-cli cursor-cli kiro-cli muse-code droid; do
  brew install --cask "$c" || echo "WARN: cask $c failed"
done
brew list --versions 2>/dev/null | sed 's/^/  /'

# NOTHING HERE IS RUN, only installed -- which is the whole claim: a Homebrew token is
# proven by the install alone. The state directories that appear on first invocation are
# therefore absent from this run, and that is not a hole in the suite: ~/.codex comes from
# 20-cli-agents and ~/.aider from 25-python-agents, both recorded.
#
# Hermes is the sharper case: its ~/.hermes lives under HERMES_HOME, which a Homebrew
# install never creates -- the code is in the Cellar and the directory appears on first run.
# So this machine proves the formula token and nothing else about it, and 25-python-agents
# is where the other routes are exercised.
#
# Claude Code's npm package, for the same reason: 20-cli-agents installs it through the
# NATIVE installer -- a shim at ~/.local/bin/claude, no npm row -- so @anthropic-ai/
# claude-code was catalogued and never produced. This machine has no native install to
# collide with.
need_node
retry "npm install -g @anthropic-ai/claude-code" npm install -g @anthropic-ai/claude-code \
  || echo "WARN: claude-code npm install failed"
