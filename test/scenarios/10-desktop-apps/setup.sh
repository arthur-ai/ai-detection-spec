#!/bin/zsh
# Demo rows: Claude Desktop (64 devices), Cursor (112), ChatGPT Desktop (89), Comet (8).
# All cask tokens verified against the Homebrew API.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# Cask tokens verified against the Homebrew API before being added: `orion` and
# `devin-desktop` (Windsurf's token, which is NOT `windsurf`).
#
# `perplexity` LEFT THIS LIST and now has its own scenario, 11-perplexity-desktop. It
# declared depends_on macos >= 15 while everything left here installs on 13 or lower, so
# on macos-14 one cask's floor was skipping the whole scenario and every other cask with
# it. The requires.json went with it, and this scenario now runs on both runners.
#
# KEEP IT THAT WAY: adding a cask with a floor above 13 silently costs macos-14 coverage
# for every cask in the loop below. Check depends_on before adding one.
#
# lm-studio and jan were installed here and are not any more: they are model runners, and
# the scope is agents. Worth remembering that lm-studio sat in this list for a long time
# WITHOUT being asserted -- installed on every run, proving nothing.
#
# WARN rather than exit: a cask download failing is a network fact, and the assertion is
# where a missing app should be reported, because it names WHICH one. An aborted setup
# names none of them.
for c in claude cursor chatgpt comet orion devin-desktop; do
  brew install --cask "$c" || echo "WARN: $c failed"
done
