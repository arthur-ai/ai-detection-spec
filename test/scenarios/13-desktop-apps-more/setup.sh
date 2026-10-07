#!/bin/zsh
# More desktop agents, split from 10-desktop-apps BY BYTES: Dia's zip alone is 840MB,
# measured 2026-10-07. A separate scenario is a separate CI job, so the downloads run in
# parallel and a failure names this list rather than 10's as well.
#
# The floor rule in 10's header applies here too: every cask below must install on the
# oldest macOS in the scenarios.yml matrix. Read off the Homebrew API on 2026-10-07:
# thebrowsercompany-dia >= 14 and arm64 only, trae, trae-cn and block-goose >= 12.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# WARN rather than exit, for the reason 10 gives: the assertion names which app is missing.
for c in thebrowsercompany-dia trae trae-cn block-goose; do
  brew install --cask "$c" || echo "WARN: $c failed"
done
