#!/bin/zsh
# MANUS'S DESKTOP AGENT, through its cask, which tracks download.manus.im's electron-builder
# feed, so each run installs whatever release the feed serves. The manus entry in
# catalog/agents.yaml has the rename and the run that read both app names.
#
# WARN rather than exit: the assertion names what is missing.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
retry manus brew install --cask manus || echo "WARN: the manus cask failed"
