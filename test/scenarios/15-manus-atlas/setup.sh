#!/bin/zsh
# TWO DESKTOP AGENTS, each installed the one way it can be unattended.
#
# Manus, through its cask, which tracks download.manus.im's electron-builder feed. The app
# was renamed Manus.app -> Manus Studio.app between 1.7.4 and 2.0.6 and kept its bundle id;
# CI run 40914014884 installed both, macOS 15's cached metadata still resolving 1.7.4.
#
# ChatGPT Atlas, from OpenAI's own URL. OpenAI retired Atlas on 2026-08-09 and the
# `chatgpt-atlas` cask was disabled on 2026-08-26, but the last build is still served and
# machines that installed it still carry it. URL and sha256 are that cask's own for
# 1.2026.189.1, which is also the first item of the app's Sparkle feed,
# persistent.oaistatic.com/atlas/public/sparkle_public_appcast.xml, read in the same run.
# The hash is checked so a different file at that URL shows up as a missing id.
#
# NEVER RUN THIS SETUP ON A MANAGED HOST: the feed's newest Atlas build is from 2026-07-24.
#
# WARN rather than exit: the assertion names which app is missing.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
retry manus brew install --cask manus || echo "WARN: the manus cask failed"

URL='https://persistent.oaistatic.com/atlas/public/ChatGPT_Atlas_Desktop_public_1.2026.189.1_20260724200710000.dmg'
SHA=894b60a1276c65dd220984db647963e6245e06e2211fb3c61b944f6e1a013435
DMG=/tmp/chatgpt-atlas.dmg
if ! retry "the Atlas DMG" curl -fsSL -o "$DMG" "$URL"; then
  echo "WARN: the Atlas DMG download failed"
elif [ "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "WARN: the Atlas DMG's sha256 is not the cask's, so it was not installed"
else
  install_dmg "$DMG" "ChatGPT Atlas.app" || echo "WARN: the Atlas DMG did not mount or copy"
fi
