#!/bin/zsh
# OPERA NEON through the installer Opera's site serves, which fetches the current build and
# writes /Applications/Opera Neon.app. No cask exists. Its own job for the download, as 13
# was split from 10.
#
# THE INSTALLER LAUNCHES THE BROWSER even under --launchbrowser=0 (probe run 42675163069),
# and a running browser adds a `proc` row that names the agent, which would pass must_find
# with the `app` row gone. So every process under the bundle is stopped and waited for, and
# expected.json forbids the `proc` row: a browser still running fails the run. One SIGTERM
# sent 15s after Info.plist appeared left it running in run 44776625750.
#
# WARN rather than exit: the assertion names what is missing.
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

app="/Applications/Opera Neon.app"
plist="$app/Contents/Info.plist"
# argv[0] under the bundle, anchored: the installer's own command lines may name the path.
browser='^/Applications/Opera Neon\.app/'
work="$(mktemp -d /tmp/neon.XXXXXX)"

# One attempt, for retry: fetch the installer, run it, and wait for the browser it launches
# or for its own exit, whichever is first. Its output is kept, and printed when it fails.
install_neon() {
  local inst n
  rm -rf "$work/installer"
  curl -fsSL -o "$work/setup.zip" 'https://net.geo.opera.com/opera_neon/stable/mac' || return 1
  ditto -x -k "$work/setup.zip" "$work/installer" || return 1
  "$work/installer/Opera Neon Installer.app/Contents/MacOS/Opera Neon Installer" \
    --silent --runimmediately --launchbrowser=0 >"$work/installer.log" 2>&1 &
  inst=$!
  for n in $(seq 1 120); do
    pgrep -f "$browser" >/dev/null && break
    kill -0 "$inst" 2>/dev/null || break
    sleep 5
  done
  [ -f "$plist" ] && return 0
  pkill -f "$work/installer/" 2>/dev/null
  echo "      the installer left no $app. Its output:" >&2
  tail -20 "$work/installer.log" | sed 's/^/      /' >&2
  return 1
}

# Stop the installer and the browser, and hold until nothing under the bundle has run for
# ten seconds: the installer may start the browser after it is first seen to be stopped.
# SIGKILL from the tenth second. Non-zero if something is still running after a minute.
stop_neon() {
  local n quiet=0
  for n in $(seq 1 30); do
    pkill -f "$work/installer/" 2>/dev/null
    if pgrep -f "$browser" >/dev/null; then
      quiet=0
      if [ "$n" -gt 5 ]; then pkill -9 -f "$browser"; else pkill -f "$browser"; fi
    else
      quiet=$((quiet + 1))
      [ "$quiet" -ge 5 ] && return 0
    fi
    sleep 2
  done
  return 1
}

retry "the Opera Neon install" install_neon
if ! stop_neon; then
  echo "WARN: Opera Neon is still running:"
  pgrep -fl "$browser" | cut -c1-160 | sed 's/^/      /'
fi
rm -rf "$work"
if [ -f "$plist" ]; then
  for key in CFBundleIdentifier CFBundleShortVersionString; do
    plutil -extract "$key" raw "$plist" | sed "s/^/  $key /"
  done
fi
exit 0
