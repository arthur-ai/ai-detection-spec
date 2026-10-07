#!/bin/zsh
# 45-claude-extension -- the Claude browser extension, matched by id.
#
# STILL OPEN: two further ids circulate for Anthropic-related extensions and neither is in
# the catalog. Nothing here is blocked on them -- the method below needs only a Web Store
# id, so either one is minutes of work once somebody confirms it is real.
#
# THIS SCENARIO PREVIOUSLY CLAIMED IT COULD NOT BE TESTED WITHOUT MDM. That was wrong,
# and the correction is the interesting part.
#
# The first attempt tried ExtensionInstallForcelist, saw nothing install, and concluded
# Chrome only honours the policy under MDM. Two things were actually wrong: Chrome was
# never launched (`open -a` needs an Aqua session and SSH has none, so no profile existed
# for osquery to read), and forcing an install through the browser's own update flow was
# never necessary in the first place.
#
# What osquery reads is the profile directory on disk. And `identifier` is derived from the
# manifest `key` -- which is exactly why 40-browser records that a hand-planted extension
# reports an EMPTY identifier: unpacked extensions have no key. A CRX from the Web Store
# does. Verified before writing this:
#
#     manifest key -> SHA-256 -> first 16 bytes -> hex mapped 0-f to a-p
#       = fcoeoabgfenejglbffodgkkbkcdhcgfn, which is the catalogued id.
#
# So the real signed artifact is fetched from Google's own update service and unpacked into
# a real profile. That is a weaker claim than "the browser installed it" and a much stronger
# one than "we planted a directory": the bytes are the Web Store's, the key is the
# publisher's, and the id osquery reports is derived rather than asserted.
set -u
. "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

EXT_ID=fcoeoabgfenejglbffodgkkbkcdhcgfn
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
UDD="$HOME/Library/Application Support/Google/Chrome"

need_brew
brew install --cask google-chrome || { echo "FAIL: chrome cask failed" >&2; exit 1; }

# THE SAME SEQUENCE 40-BROWSER USES, deliberately rather than a fresh one. The first
# version of this file polled for Default/ and killed Chrome the moment it appeared, which
# reported "profile created" and still produced zero rows: the DIRECTORY exists before
# Local State and Preferences are written, and osquery enumerates profiles from those, not
# from the Extensions directory alone. --dump-dom made it worse by exiting early.
#
# So: let it run, then stop it, then plant. There was a working method in the tree and
# writing a new one cost a VM boot to discover that.
"$CHROME" --headless=new --no-first-run --no-default-browser-check --disable-gpu \
          --user-data-dir="$UDD" about:blank >/tmp/chrome.log 2>&1 &
sleep 20
pkill -x "Google Chrome" || true
sleep 3
[ -f "$UDD/Local State" ] || { echo "FAIL: chrome never wrote Local State" >&2; exit 1; }
[ -f "$UDD/Default/Preferences" ] || { echo "FAIL: no Default/Preferences" >&2; exit 1; }
echo "profile scaffolded: Local State and Default/Preferences both present"

URL="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=152.0&acceptformat=crx3&x=id%3D${EXT_ID}%26uc"
curl --retry 3 -sL "$URL" -o /tmp/ext.crx || true
# A network failure here is the lab, not the query. Exit 3 = SKIP, per run.sh.
[ -s /tmp/ext.crx ] || { echo "Web Store unreachable; cannot fetch the signed artifact."; exit 3; }

VER=$(python3 - <<'PY'
import struct, zipfile, io, json, pathlib
raw = pathlib.Path("/tmp/ext.crx").read_bytes()
assert raw[:4] == b"Cr24"
hlen = struct.unpack("<II", raw[4:12])[1]
z = zipfile.ZipFile(io.BytesIO(raw[12 + hlen:]))
m = json.loads(z.read("manifest.json"))
# Unpack under the version Chrome would use, and assert the key is present -- without it
# osquery reports an empty identifier and this scenario would prove nothing.
assert m.get("key"), "manifest has no key; identifier would come back empty"
import os
dest = os.path.expanduser("~/Library/Application Support/Google/Chrome/Default/Extensions/"
                          "fcoeoabgfenejglbffodgkkbkcdhcgfn/%s_0" % m["version"])
os.makedirs(dest, exist_ok=True)
z.extractall(dest)
print(m["version"])
PY
) || { echo "FAIL: could not unpack the CRX" >&2; exit 1; }
echo "unpacked $EXT_ID version $VER with its manifest key"
