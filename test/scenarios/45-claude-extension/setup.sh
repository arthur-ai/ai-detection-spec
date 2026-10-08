#!/bin/zsh
# 45-claude-extension -- the browser-agent extensions, matched by id. Claude's came first.
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

# EVERY BROWSER AGENT THE CATALOG MATCHES BY ID, not only Claude's -- the name predates the
# list, and it is kept because the workflow, the docs and this scenario's observed.json key on it.
#   fcoeoabgfenejglbffodgkkbkcdhcgfn  Claude
#   eanggfilgoajaocelnaflolkadkeghjp  HARPA AI
#   ofpnmcalabcbjgholdjcjblkibolbppb  Monica
#   difoiogjjojoaoomphldepapgpbgkhkb  Sider
#   camppjleccjaphfdbohjdohecfnoikec  Merlin
EXT_IDS=(fcoeoabgfenejglbffodgkkbkcdhcgfn eanggfilgoajaocelnaflolkadkeghjp ofpnmcalabcbjgholdjcjblkibolbppb
         difoiogjjojoaoomphldepapgpbgkhkb camppjleccjaphfdbohjdohecfnoikec)
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

# No answer for ANY id is the lab, not the query: exit 3 = SKIP, per run.sh. No answer for
# SOME of them is an extension the Web Store stopped serving, and that must stay red -- the
# agent's must_find fails and names it.
DIRS=()
for EXT_ID in $EXT_IDS; do
  URL="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=155.0&acceptformat=crx3&x=id%3D${EXT_ID}%26uc"
  curl --retry 3 -sL "$URL" -o "/tmp/$EXT_ID.crx" || true
  [ -s "/tmp/$EXT_ID.crx" ] || { echo "WARN: the Web Store returned nothing for $EXT_ID"; continue; }

  # THE KEY IS WRITTEN THE WAY CHROME WRITES IT. Without a manifest `key` osquery reports
  # an EMPTY identifier. Claude ships one; HARPA and Monica do not, because Chrome's own
  # unpacker copies the publisher key out of the CRX header into the installed manifest.
  # This does the same: the developer proof is the one whose SHA-256 begins with the
  # header's signed crx_id, and the id it derives must be the one requested.
  VER=$(python3 - "$EXT_ID" <<'PY'
import base64, hashlib, io, json, os, struct, sys, zipfile
eid = sys.argv[1]
raw = open("/tmp/%s.crx" % eid, "rb").read()
assert raw[:4] == b"Cr24", "not a CRX3"
hlen = struct.unpack("<II", raw[4:12])[1]

def fields(buf):
    # Length-delimited protobuf fields, which is all of a CRX3 header that matters here.
    i = 0
    while i < len(buf):
        tag = shift = 0
        while True:
            b = buf[i]; i += 1; tag |= (b & 0x7F) << shift; shift += 7
            if b < 0x80: break
        if tag & 7 == 0:
            while buf[i] >= 0x80: i += 1
            i += 1
            continue
        n = shift = 0
        while True:
            b = buf[i]; i += 1; n |= (b & 0x7F) << shift; shift += 7
            if b < 0x80: break
        yield tag >> 3, buf[i:i + n]
        i += n

proofs, crx_id = [], b""
for num, val in fields(raw[12:12 + hlen]):
    if num in (2, 3):                 # sha256_with_rsa, sha256_with_ecdsa
        proofs += [v for n, v in fields(val) if n == 1]
    elif num == 10000:                # signed_header_data
        crx_id = next((v for n, v in fields(val) if n == 1), b"")
z = zipfile.ZipFile(io.BytesIO(raw[12 + hlen:]))
m = json.loads(z.read("manifest.json").decode("utf-8-sig"))
injected = not m.get("key")
if injected:
    dev = [k for k in proofs if hashlib.sha256(k).digest()[:16] == crx_id]
    assert dev, "no developer key in the CRX header"
    m["key"] = base64.b64encode(dev[0]).decode()
derived = "".join(chr(97 + int(c, 16))
                  for c in hashlib.sha256(base64.b64decode(m["key"])).hexdigest()[:32])
assert derived == eid, "key derives %s, not %s" % (derived, eid)
dest = os.path.expanduser("~/Library/Application Support/Google/Chrome/Default/Extensions/"
                          "%s/%s_0" % (eid, m["version"]))
os.makedirs(dest, exist_ok=True)
z.extractall(dest)
if injected:
    with open(os.path.join(dest, "manifest.json"), "w") as f:
        json.dump(m, f, indent=2)
print(m["version"])
PY
) || { echo "FAIL: could not unpack the CRX for $EXT_ID" >&2; exit 1; }
  DIRS+=("$UDD/Default/Extensions/$EXT_ID/${VER}_0")
  echo "unpacked $EXT_ID version $VER; manifest sha256, which osquery reports as manifest_hash: $(shasum -a 256 "${DIRS[-1]}/manifest.json" | cut -c1-64)"
done
[ ${#DIRS} -gt 0 ] || { echo "Web Store unreachable; cannot fetch any signed artifact."; exit 3; }

launch --load-extension="${(j:,:)DIRS}"
[ -f "$UDD/Local State" ] || { echo "FAIL: chrome never wrote Local State" >&2; exit 1; }
[ -f "$UDD/Default/Preferences" ] || { echo "FAIL: no Default/Preferences" >&2; exit 1; }
echo "profile written: Local State and Default/Preferences both present"
# THE THING UNDER TEST, so a failure here is red and not a skip: if Chrome did not register
# a directory, its row reads `unreferenced` and the sideloaded path proves nothing.
python3 - "$UDD" $DIRS <<'PY'
import json, os, sys
udd, dirs = sys.argv[1], sys.argv[2:]
settings = {}
for f in ("Secure Preferences", "Preferences"):
    p = os.path.join(udd, "Default", f)
    if os.path.exists(p):
        for eid, s in json.load(open(p)).get("extensions", {}).get("settings", {}).items():
            settings.setdefault(eid, (f, s))
bad = 0
for d in dirs:
    eid, ver = d.split("/")[-2:]
    f, s = settings.get(eid, (None, {}))
    ok = str(s.get("path", "")).endswith(f"{eid}/{ver}")
    print(f"{eid}: settings entry in {f}: path={s.get('path')} location={s.get('location')} "
          f"from_webstore={s.get('from_webstore')}{'' if ok else '  <-- NOT REGISTERED'}")
    bad += not ok
sys.exit(1 if bad else 0)
PY
if [ $? != 0 ]; then
  echo "FAIL: Chrome did not register every extension. Its log says:" >&2
  grep -i 'extension\|load' /tmp/chrome.log | tail -15 | sed 's/^/      /' >&2
  exit 1
fi
