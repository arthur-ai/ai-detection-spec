#!/bin/zsh
# META'S TWO MUSE PRODUCTS, each installed the one way it can be unattended.
#
# Muse for Mac. The `muse` cask was disabled on 2026-10-01: muse.ai/api/hatch/app-download/mac
# answers 403 {"error":"not_eligible"} to anyone not signed in to a Meta account, from a US
# address too, and Meta's download page builds its link from a GraphQL call rather than
# serving it in the HTML. The app updates itself through Sparkle, and a Sparkle feed has to
# answer anonymously for the app to update, so the DMG is read off that feed at run time.
# The feed URL is SUFeedURL in the 8.0 build's Info.plist; the enclosure it carries is
# signed and expires within a day, which is why no download URL is written here.
#
# Muse Code. Meta's own installer writes a launcher to ~/.local/bin/muse and then has it
# fetch the binary beside it as muse-bin-<version>, no sign-in needed -- sign-in is first
# run. 84-linux-installers runs the same installer on Linux; this is its only macOS run.
#
# WARN rather than exit, at every step: the assertion names which product is missing, and
# one bad download must not cost the install after it.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

APPCAST='https://www.facebook.com/endo/release/appcast.xml?channel=production'
DMG=/tmp/muse.dmg
# The first <enclosure> is the current build: Sparkle lists newest first, and the feed has
# carried one item each time it was read. Joined to one line because the element spans
# several; `&amp;` is the XML's, not the URL's.
URL=$(curl --retry 3 -fsSL "$APPCAST" | tr -d '\n' | grep -o '<enclosure[^>]*>' | head -1 \
      | grep -o 'url="[^"]*"' | sed 's/^url="//; s/"$//; s/&amp;/\&/g')
if [ -z "$URL" ]; then
  echo "WARN: the Muse appcast carried no enclosure, so Muse for Mac was not installed"
elif ! retry "the Muse DMG" curl -fsSL -o "$DMG" "$URL"; then
  echo "WARN: the Muse DMG download failed"
else
  install_dmg "$DMG" Muse.app || echo "WARN: the Muse DMG did not mount or carried no Muse.app"
fi

retry "the Muse Code installer" sh -c 'curl --retry 3 -fsSL https://dev.meta.ai/install.sh | bash' \
  || echo "WARN: the Muse Code installer failed"
# Both files, or the binary download was refused and only the launcher is here.
ls -la ~/.local/bin 2>/dev/null | grep muse | sed 's/^/  /'
