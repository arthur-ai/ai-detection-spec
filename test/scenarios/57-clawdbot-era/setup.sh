#!/bin/zsh
# THE PREDECESSOR APP, INSTALLED FOR REAL.
#
# This project's macOS app has shipped under three names -- Clawdis, then Clawdbot, then
# OpenClaw -- and the catalog carries the bundle id of each generation it can prove. This
# scenario proves the middle one. Read off Clawdbot.app/Contents/Info.plist inside the
# shipped 2026.1.23 zip, never off the cask:
#
#   CFBundleIdentifier         com.clawdbot.mac
#   CFBundleShortVersionString 2026.1.23
#
# NEVER RUN THIS SETUP ON A MANAGED HOST. Like 56, it installs deliberately outdated
# software, and that is safe only because the guest is disposable, unenrolled and holds no
# credentials. This line lives here rather than in expected.json because this is the file
# someone reads before running it.
#
# A DIRECT DOWNLOAD, NOT A CASK. Homebrew renamed the `clawdbot` cask to `openclaw` on
# 2026-01-30 and keeps no versioned casks, so there is nothing to `brew install`. The
# release asset survives under the renamed repo, which is why the URL says openclaw.
#
# WARN rather than exit on a failed download: that is a network fact, and the assertion is
# where a missing app should be reported, because it names which one.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

VER=2026.1.23
URL="https://github.com/openclaw/openclaw/releases/download/v${VER}/Clawdbot-${VER}.zip"

if curl -fsSL --retry 2 -o /tmp/clawdbot.zip "$URL"; then
  ditto -x -k /tmp/clawdbot.zip /tmp/clawdbot-app
  # Into /Applications so the `apps` table sees it the way it sees every other install.
  rm -rf "/Applications/Clawdbot.app"
  ditto "/tmp/clawdbot-app/Clawdbot.app" "/Applications/Clawdbot.app"
  # Report what the artifact actually says, so a run that installs a DIFFERENT build than
  # the one this scenario was written against says so in its own log rather than failing
  # later as a mystery.
  plutil -extract CFBundleIdentifier raw "/Applications/Clawdbot.app/Contents/Info.plist" \
    | sed 's/^/  CFBundleIdentifier /'
else
  echo "WARN: Clawdbot ${VER} download failed"
fi
