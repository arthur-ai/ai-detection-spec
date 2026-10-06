#!/bin/zsh
# THE LAST CHATGPT BUILD BEFORE THE CODEX RENAME, INSTALLED FOR REAL.
#
# Builds before the rename carry com.openai.chat; builds after carry com.openai.codex. The
# `chatgpt` cask stopped resolving the old one, after which the only record proving
# com.openai.chat came from a runner image CI no longer has. Read off
# ChatGPT.app/Contents/Info.plist inside this DMG on 2026-10-04, never off the cask:
#
#   CFBundleIdentifier         com.openai.chat
#   CFBundleShortVersionString 1.2026.160
#   LSMinimumSystemVersion     14.0          binary: arm64 only
#
# NEVER RUN THIS SETUP ON A MANAGED HOST. It installs deliberately outdated software, which
# is safe only because the guest is disposable, unenrolled and holds no credentials.
#
# A DIRECT DOWNLOAD, NOT A CASK: Homebrew keeps no versioned casks. URL and sha256 are the
# cask's own at Homebrew commit 7c84f0e (chatgpt 1.2026.160,1781312926). The hash is
# checked so that a different file served from the same URL shows up as a missing id
# instead of passing on a build this header does not describe.
#
# WARN rather than exit on a failed download or hash: the assertion is where a missing app
# should be reported, because it names which one.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

VER=1.2026.160
BUILD=1781312926
SHA=37e043abd3ffa592c4c2ba9ce8494bc3fa3b157ae4e6f7872a792ffd089edf07
URL="https://persistent.oaistatic.com/sidekick/public/ChatGPT_Desktop_public_${VER}_${BUILD}.dmg"
DMG="/tmp/chatgpt-${VER}.dmg"
MNT=/tmp/chatgpt-dmg

if ! curl -fsSL --retry 2 -o "$DMG" "$URL"; then
  echo "WARN: ChatGPT ${VER} download failed"
elif [ "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "WARN: ChatGPT ${VER} sha256 is not the cask's, so it was not installed"
else
  mkdir -p "$MNT"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
  # Into /Applications so the `apps` table sees it the way it sees every other install.
  rm -rf "/Applications/ChatGPT.app"
  ditto "$MNT/ChatGPT.app" "/Applications/ChatGPT.app"
  hdiutil detach "$MNT" >/dev/null
  plutil -extract CFBundleIdentifier raw "/Applications/ChatGPT.app/Contents/Info.plist" \
    | sed 's/^/  CFBundleIdentifier /'
fi
