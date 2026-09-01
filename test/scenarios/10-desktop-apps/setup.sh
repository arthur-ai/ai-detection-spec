#!/bin/zsh
# Demo rows: Claude Desktop (64 devices), Cursor (112), ChatGPT Desktop (89), Comet (8).
# All cask tokens verified against the Homebrew API.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# lm-studio was ALREADY here and was never asserted, so it installed on every run and
# proved nothing -- the catalog listed it as unverified while a scenario was installing it.
# Now in must_find, along with three more cask tokens verified against the Homebrew API
# before being added: `orion`, `devin-desktop` (Windsurf's token, which is NOT `windsurf`)
# and `perplexity`.
#
# WARN rather than exit: a cask download failing is a network fact, and the assertion is
# where a missing app should be reported, because it names WHICH one. An aborted setup
# names none of them.
for c in claude cursor chatgpt comet lm-studio orion devin-desktop perplexity jan; do
  brew install --cask "$c" || echo "WARN: $c failed"
done
