#!/bin/bash
# THE BROWSER AGENTS, MATCHED BY ID, ON LINUX: 45-claude-extension's method, which
# 104-windows-browser ports to Windows. The Web Store's signed CRX, unpacked into a real
# profile the way Chrome unpacks it (test/lib/unpack_crx.py), then registered by Chrome for
# Testing launched once with --load-extension, a flag branded Chrome 137 and later refuse.
# The profile is branded Chrome's, ~/.config/google-chrome, which is where osquery looks.
#
# APART FROM 75-linux-browser, which plants an extension with no manifest key and forbids
# claude-in-chrome: its empty id is the control, and these real ids are read against it.
set -e
lib="$(cd "$(dirname "$0")/../../lib" && pwd)"
source "$lib/guest-linux.sh"
# Decided before anything is installed, as 75 does.
[ "$(uname -m)" = x86_64 ] || { echo "SKIP: Google ships no Linux $(uname -m) Chrome build"; exit 3; }
need_curl
need_user
# unzip rather than python's zipfile, which drops the execute bits Chrome needs.
need_pkgs unzip python3 || true
need_chrome
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
udd="$home/.config/google-chrome"

index=https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json
url=$(curl --retry 3 -fsSL "$index" | python3 -c 'import json, sys
print(next(d["url"] for d in json.load(sys.stdin)["channels"]["Stable"]["downloads"]["chrome"]
           if d["platform"] == "linux64"))') \
  || { echo "FAIL: the Chrome for Testing index did not answer"; exit 1; }
retry "the Chrome for Testing download" curl --retry 3 -fsSLo /tmp/cft.zip "$url" \
  || { echo "FAIL: Chrome for Testing did not download"; exit 1; }
rm -rf /tmp/cft && unzip -q /tmp/cft.zip -d /tmp/cft
cft=/tmp/cft/chrome-linux64/chrome
[ -x "$cft" ] || { echo "FAIL: no Chrome for Testing at $cft"; exit 1; }
# The scenario user cannot read the checkout (lib/guest-linux.sh, as_user), so the unpacker
# goes where it can.
install -m 0644 "$lib/unpack_crx.py" /tmp/unpack_crx.py

# Claude, HARPA AI, Monica, Sider, Merlin: every browser agent the catalog matches by id. No
# answer for ANY id is the network, so SKIP. No answer for SOME is an extension the Web Store
# stopped serving, which must stay red: its agent's must_find fails and names it.
dirs=()
for id in fcoeoabgfenejglbffodgkkbkcdhcgfn eanggfilgoajaocelnaflolkadkeghjp \
          ofpnmcalabcbjgholdjcjblkibolbppb difoiogjjojoaoomphldepapgpbgkhkb \
          camppjleccjaphfdbohjdohecfnoikec; do
  crx="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=155.0&acceptformat=crx3&x=id%3D${id}%26uc"
  retry "the CRX for $id" curl --retry 3 -fsSLo "/tmp/$id.crx" "$crx" || continue
  chmod 0644 "/tmp/$id.crx"
  ver=$(as_user "python3 /tmp/unpack_crx.py /tmp/$id.crx $id '$udd/Default/Extensions'") \
    || { echo "FAIL: could not unpack the CRX for $id"; exit 1; }
  dirs+=("$udd/Default/Extensions/$id/${ver}_0")
  echo "unpacked $id version $ver"
done
[ ${#dirs[@]} -gt 0 ] || { echo "SKIP: the Web Store returned no CRX; no signed artifact to unpack"; exit 3; }

# One launch, with the flag, on a profile that does not exist yet; let it run, then stop it.
# 75 says why each flag is there. timeout's 124 is the stop, not a failure.
joined=$(IFS=,; echo "${dirs[*]}")
try_user "Chrome for Testing, loading the extensions" \
  "timeout 25 $cft --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
     --no-first-run --no-default-browser-check --user-data-dir='$udd' \
     --load-extension='$joined' about:blank; [ \$? = 124 ]" || true
as_user "test -f '$udd/Default/Preferences'" \
  || { echo "FAIL: Chrome for Testing wrote no Default/Preferences"; exit 1; }
echo "--- extensions Chrome registered:"
as_user "python3 -c 'import json; s = json.load(open(\"$udd/Default/Preferences\")).get(\"extensions\", {}).get(\"settings\", {}); print(\"\n\".join(sorted(s)))'" \
  | sed 's/^/      /' || true
