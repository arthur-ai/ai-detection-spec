#!/bin/zsh
# THE PREDECESSOR APP, INSTALLED FOR REAL, BECAUSE THE ALIAS IT REPLACES WAS A PHANTOM.
#
# catalog/agents.yaml carried `bot.molt.mac` and `bot.molt.` for months as identifiers
# "machines that installed the earlier version still report". No such version was ever
# published. Read off the project's own release assets, 243 releases deep, the macOS app
# has shipped under exactly three names:
#
#   Clawdis     v2.0.0-beta2 .. beta5
#   Clawdbot    v2026.1.x            <- this scenario
#   OpenClaw    v2026.2 onward
#
# Never Moltbot. `moltbot` is real as an NPM name and 56-openclaw-retired-names installs
# it, but no .app ever carried that bundle id. The value came from the Homebrew cask's zap
# stanza -- which still lists `bot.molt.*` paths today, and which catalog/agents.yaml
# already names as "exactly how the wrong one got shipped".
#
# So this scenario exists to replace a guess with a fact. The identifier it proves was read
# off Clawdbot.app/Contents/Info.plist inside the shipped 2026.1.23 zip:
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
