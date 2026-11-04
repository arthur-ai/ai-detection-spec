#!/bin/zsh
# HERMES DESKTOP FOR macOS, the DMG Nous Research's own stable feed names. Apple Silicon
# only: the vendor ships no Intel build.
#
# The feed is electron-builder's: releases/darwin/stable/stable-mac.yml on the vendor's
# asset host, whose `files` carry the dmg and zip as absolute object keys on that host
# (/releases/tag/<tag>/HermesBundled-<version>-mac-arm64.dmg). The dmg is read from there
# rather than from a pinned URL, so each run installs whatever the feed serves.
#
# A SCENARIO OF ITS OWN for size: the dmg is 1.5GB, the agent's Python and tools inside it.
#
# NOT LAUNCHED, ON PURPOSE. A first launch links ~/.local/bin/hermes into the bundle and
# creates ~/.hermes (probe run 41870942008), both values the hermes entry already carries,
# so a launched app would pass must_find with the bundle id broken. Installed only, the
# bundle id is the one witness.
#
# WARN rather than exit: the assertion names what is missing.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

base=https://hermes-assets.nousresearch.com
feed="$(retry "the Hermes Desktop feed" curl -fsSL "$base/releases/darwin/stable/stable-mac.yml")" || {
  echo "WARN: the Hermes Desktop feed did not answer"; exit 0; }
key="$(print -r -- "$feed" | awk '$1 == "-" && $2 == "url:" && $3 ~ /\.dmg$/ { print $3; exit }')"
case "$key" in
  http*) url="$key" ;;
  /*)    url="$base$key" ;;
  "")    echo "WARN: the feed names no dmg:"; print -r -- "$feed"; exit 0 ;;
  *)     url="$base/releases/darwin/stable/$key" ;;
esac
echo "dmg: $url"
dmg="$(mktemp /tmp/hermes.XXXXXX)"
retry "the Hermes Desktop dmg" curl -fsSL -o "$dmg" "$url" || { echo "WARN: the dmg did not download"; exit 0; }
install_dmg "$dmg" "Hermes Agent.app" || echo "WARN: Hermes Desktop did not install"
rm -f "$dmg"
