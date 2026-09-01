#!/bin/zsh
# Perplexity Desktop, alone, BECAUSE OF ITS macOS FLOOR AND NOTHING ELSE.
#
# This is a split off 10-desktop-apps, not a new subject. `perplexity` declares
# depends_on macos >= 15 while claude, cursor, chatgpt, comet, devin-desktop and orion
# install on 13 or lower -- so one cask's floor was deciding whether the other six were
# tested at all, and on macos-14 they simply were not. Read off the Homebrew API on
# 2026-09-01:
#
#   claude v1.40609.0        >= 12      comet v145.2.7632.4581   >= 12
#   cursor v3.18.9           >= 12      orion v1.1.2,151         (no constraint)
#   chatgpt v26.831.11858    >= 13      devin-desktop v3.8.20    >= 12
#   perplexity v26.34.0      >= 15   <- the only one, and the reason this file exists
#
# So the skip is now scoped to the cask that earns it: 10-desktop-apps lost its
# requires.json and covers six casks on both runners, and this scenario carries the
# min_macos 15 for the seventh. openclaw is the only other >= 15 cask in the repo and
# already sits alone in 50-autonomous.
#
# WARN rather than exit, as in 10-desktop-apps: a cask download failing is a network fact,
# and the assertion is where a missing app should be reported, because it names which one.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install --cask perplexity || echo "WARN: perplexity failed"
