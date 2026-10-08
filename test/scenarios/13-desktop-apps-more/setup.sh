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
# FRESH METADATA, because Dia's vendor serves only the current zip. Both runner images'
# cached casks still named 1.47.2 on 2026-10-08, and that URL answered 404. Stale metadata is
# what 12-chatgpt-pre-rename relies on to reach an old build; here it reaches nothing.
brew update >/dev/null 2>&1 || echo "WARN: brew update failed; cask metadata may be stale"
# Through retry, because a CDN can reset a transfer mid-download. Run 37829705185 lost
# trae-cn to `Connection reset by peer` on macos-15, the same day the same URL installed on
# both runners. Running out still WARNs rather than exits, for the reason 10 gives: the
# assertion names which app is missing.
for c in thebrowsercompany-dia trae trae-cn block-goose; do
  retry "$c" brew install --cask "$c" || true
done
