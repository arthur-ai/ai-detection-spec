#!/bin/zsh
# THE LAST KIRO CLI BUILD THAT SHIPPED A macOS APP, INSTALLED FOR REAL.
#
# Kiro CLI was `Kiro CLI.app` on macOS through 2.37.1 and is a standalone binary after it.
# Measured 2026-11-10 against the vendor's bucket: `<version>/Kiro CLI.dmg` answers 200
# for 2.37.1 and 403 for 3.0.0 and 3.1.0, and latest/manifest.json (3.1.0) lists a zip and
# a tar.gz for macOS and no dmg. The `kiro-cli` cask switched to the binary on 2026-10-31
# (Homebrew/homebrew-cask 18e09a4d9b), and 21-cli-agents-homebrew stopped producing the
# bundle id. Read off Kiro CLI.app/Contents/Info.plist inside this DMG on 2026-11-10:
#
#   CFBundleIdentifier         com.amazon.codewhisperer
#   CFBundleShortVersionString 2.37.1
#   LSMinimumSystemVersion     10.13         binary: x86_64 and arm64
#
# NEVER RUN THIS SETUP ON A MANAGED HOST. It installs deliberately outdated software, which
# is safe only because the guest is disposable, unenrolled and holds no credentials.
#
# A DIRECT DOWNLOAD, NOT A CASK: Homebrew keeps no versioned casks. The URL is the vendor's
# own. The sha256 was computed from that download on 2026-11-10; no cask recorded one for
# this file, because the cask left the dmg at 2.37.0. It is checked so that a different
# file served from the same URL shows up as a missing id instead of passing on a build
# this header does not describe.
#
# WARN rather than exit on a failed download or hash: the assertion is where a missing app
# should be reported, because it names which one.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

VER=2.37.1
SHA=3477707d09191f52c1d117dd92d79a6e57a793d577868cf5ce89315981314743
URL="https://desktop-release.q.us-east-1.amazonaws.com/${VER}/Kiro%20CLI.dmg"
DMG="/tmp/kiro-cli-${VER}.dmg"

# retry says so itself when the download fails for the third time.
if retry "Kiro CLI ${VER} download" curl -fsSL -o "$DMG" "$URL"; then
  if [ "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" != "$SHA" ]; then
    echo "WARN: Kiro CLI ${VER} sha256 is not the one this scenario read, so it was not installed"
  else
    install_dmg "$DMG" "Kiro CLI.app" || echo "WARN: Kiro CLI ${VER} did not mount or copy"
  fi
fi
