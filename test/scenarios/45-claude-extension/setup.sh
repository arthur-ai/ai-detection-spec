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
#
# THEN THE BROWSER REGISTERS IT, because a directory on disk that Preferences does not name
# is one Chrome never loads, and browser.sql now says so with `unreferenced`. Launching with
# --load-extension writes the settings entry: from_webstore false, location 8, the path
# relative to Extensions/. That is a sideload, and the row carries `sideloaded:<sha256>`.
#
# CHROME FOR TESTING, NOT THE CASK. Branded Chrome 137 and later ignore --load-extension;
# Google's announcement exempts Chrome for Testing. The profile directory is still
# Google/Chrome, because osquery names the browser from the path.
#
# ONE LAUNCH, WITH THE FLAG, ON A PROFILE THAT DOES NOT EXIST YET. Scaffolding the profile
# first and relaunching with --load-extension ran the extension in a Tart guest and did not
# persist its install record: over SSH Chrome has no keychain ("Encryption is not
# available"), and the entry came back holding service-worker state and no path. A profile
# whose first launch carries the flag persisted it. Measured 2026-10-07, Chrome for Testing
# 155 on macOS 26.6.2: osquery then read referenced 1, from_webstore 'false', and a
# manifest_hash equal to the manifest's SHA-256.
set -u
. "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

EXT_ID=fcoeoabgfenejglbffodgkkbkcdhcgfn
UDD="$HOME/Library/Application Support/Google/Chrome"

# python3 below, and /usr/bin/python3 is a stub until the Command Line Tools are installed.
need_clt || { echo "FAIL: Command Line Tools did not install" >&2; exit 1; }

case "$(uname -m)" in arm64) plat=mac-arm64 ;; *) plat=mac-x64 ;; esac
CFT_INDEX=https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json
url=$(curl --retry 3 -fsSL "$CFT_INDEX" | python3 -c '
import json, sys
d = json.load(sys.stdin)["channels"]["Stable"]["downloads"]["chrome"]
print(next(x["url"] for x in d if x["platform"] == sys.argv[1]))' "$plat") \
  || { echo "FAIL: the Chrome for Testing index did not answer" >&2; exit 1; }
curl --retry 3 -fsSL "$url" -o /tmp/cft.zip || { echo "FAIL: Chrome for Testing download failed" >&2; exit 1; }
rm -rf /tmp/cft && mkdir -p /tmp/cft && unzip -q /tmp/cft.zip -d /tmp/cft
CHROME="/tmp/cft/chrome-$plat/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
[ -x "$CHROME" ] || { echo "FAIL: no Chrome for Testing binary at $CHROME" >&2; exit 1; }

# LET IT RUN, THEN STOP IT, which is 40-browser's sequence. Polling for Default/ and
# killing Chrome the moment it appeared produced zero rows, because the directory exists
# before Local State and Preferences are written, and osquery reads profiles from those.
# -f rather than -x: the process name has spaces in it.
launch() {
  "$CHROME" --headless=new --no-first-run --no-default-browser-check --disable-gpu \
            --user-data-dir="$UDD" "$@" about:blank >>/tmp/chrome.log 2>&1 &
  sleep 20
  pkill -f "Google Chrome for Testing" || true
  sleep 3
}

URL="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=155.0&acceptformat=crx3&x=id%3D${EXT_ID}%26uc"
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
EXT_DIR="$UDD/Default/Extensions/$EXT_ID/${VER}_0"
echo "unpacked $EXT_ID version $VER with its manifest key"
echo "manifest sha256, which osquery reports as manifest_hash: $(shasum -a 256 "$EXT_DIR/manifest.json" | cut -c1-64)"

launch --load-extension="$EXT_DIR"
[ -f "$UDD/Local State" ] || { echo "FAIL: chrome never wrote Local State" >&2; exit 1; }
[ -f "$UDD/Default/Preferences" ] || { echo "FAIL: no Default/Preferences" >&2; exit 1; }
echo "profile written: Local State and Default/Preferences both present"
# THE THING UNDER TEST, so a failure here is red and not a skip: if Chrome did not register
# the directory, the row reads `unreferenced` and the sideloaded path proves nothing.
python3 - "$UDD" "$EXT_ID" "$VER" <<'PY'
import json, os, sys
udd, eid, ver = sys.argv[1:]
for f in ("Secure Preferences", "Preferences"):
    p = os.path.join(udd, "Default", f)
    if not os.path.exists(p):
        continue
    s = json.load(open(p)).get("extensions", {}).get("settings", {}).get(eid)
    if s:
        print(f"settings entry in {f}: path={s.get('path')} location={s.get('location')} "
              f"from_webstore={s.get('from_webstore')} keys={sorted(s)}")
        sys.exit(0 if str(s.get("path", "")).endswith(f"{eid}/{ver}_0") else 1)
sys.exit(1)
PY
if [ $? != 0 ]; then
  echo "FAIL: Chrome did not register the extension. Its log says:" >&2
  grep -i 'extension\|load' /tmp/chrome.log | tail -15 | sed 's/^/      /' >&2
  exit 1
fi
