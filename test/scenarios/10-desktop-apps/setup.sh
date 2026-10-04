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
# KEEP IT THAT WAY: a cask whose depends_on floor is above the oldest macOS in the
# scenarios.yml matrix silently costs that runner every cask in the loop below.
#
# lm-studio and jan were installed here and are not any more: they are model runners, and
# the scope is agents. Worth remembering that lm-studio sat in this list for a long time
# WITHOUT being asserted -- installed on every run, proving nothing.
#
# WARN rather than exit: a cask download failing is a network fact, and the assertion is
# where a missing app should be reported, because it names WHICH one. An aborted setup
# names none of them.
# kiro, antigravity and antigravity-ide added 2026-09-05. All three declare
# depends_on macos >= 12, read off the Homebrew API that day (kiro 1.0.411,
# antigravity 2.11.0, antigravity-ide 2.5.5), so they clear the floor rule above.
# THEY DO COST DOWNLOAD: 255MB, 191MB and 212MB, which is roughly a
# 50% increase on this scenario's bytes. Recorded because that is the tradeoff to revisit
# if this list grows again, not a reason to skip the install -- the bundle ids are the
# whole point and only an install proves them.
for c in claude cursor chatgpt comet orion devin-desktop kiro antigravity antigravity-ide; do
  brew install --cask "$c" || echo "WARN: $c failed"
done
