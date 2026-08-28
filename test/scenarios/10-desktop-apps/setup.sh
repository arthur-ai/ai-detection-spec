#!/bin/zsh
# Demo rows: Claude Desktop (64 devices), Cursor (112), ChatGPT Desktop (89), Comet (8).
# All cask tokens verified against the Homebrew API.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
for c in claude cursor chatgpt comet lm-studio; do brew install --cask "$c" || echo "WARN: $c failed"; done
