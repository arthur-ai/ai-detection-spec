#!/bin/bash
# THROWAWAY PROBE, never merged: runs candidate installers and prints what they write.
lib="$(cd "$(dirname "$0")/../../lib" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
main() {
source "$lib/guest-linux.sh"
need_curl
need_user
need_pkgs unzip python3 || true
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
snap() { as_user "find ~ -mindepth 1 -maxdepth 4 -newer /tmp/probe-marker 2>/dev/null | grep -v -E '/\.cache/|/\.npm/' | sort | head -80"; }
for inst in "agy https://antigravity.google/cli/install.sh" "kimi https://code.kimi.com/kimi-code/install.sh" "qoder https://qoder.com/install"; do
  set -- $inst
  touch /tmp/probe-marker; sleep 1
  echo "=== $1 installer $2"
  curl -sS -o /tmp/$1-install.sh -w "HTTP %{http_code}\n" -L "$2"; head -c 600 /tmp/$1-install.sh; echo
  chmod 0644 /tmp/$1-install.sh
  try_user "$1 installer" "bash /tmp/$1-install.sh </dev/null" || true
  echo "--- new files after install"; snap
  as_user "ls -la ~/.local/bin ~/bin 2>/dev/null"
done
touch /tmp/probe-marker; sleep 1
echo "=== versions"
try_user "agy --version" "agy --version </dev/null" || true
try_user "kimi --version" "kimi --version </dev/null" || true
try_user "qodercli --version" "qodercli --version </dev/null" || true
echo "--- new files after version"; snap
echo "=== candidate Chrome extension CRX manifests"
for id in ejcfepkfckglbgocfkanmcdngdijcgld; do
  crx="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=155.0&acceptformat=crx3&x=id%3D${id}%26uc"
  curl -fsSLo /tmp/$id.crx "$crx" || { echo "$id: no CRX"; continue; }
  python3 -I - /tmp/$id.crx "$id" <<'PY'
import io, json, struct, sys, zipfile
raw = open(sys.argv[1], "rb").read()
hlen = struct.unpack("<II", raw[4:12])[1]
z = zipfile.ZipFile(io.BytesIO(raw[12 + hlen:]))
m = json.loads(z.read("manifest.json").decode("utf-8-sig"))
msgs = {}
for loc in ("en", "en_US"):
    try:
        msgs = json.loads(z.read(f"_locales/{loc}/messages.json").decode("utf-8-sig")); break
    except KeyError:
        pass
def tr(v):
    if isinstance(v, str) and v.startswith("__MSG_"):
        return msgs.get(v[6:-2], {}).get("message", v)
    return v
print(sys.argv[2], json.dumps({k: tr(m.get(k)) for k in ("name", "short_name", "version", "author", "homepage_url", "description", "permissions", "host_permissions")}, indent=1))
PY
done

}
main 2>&1 | tee /tmp/probe.out
python3 "$HERE/emit.py" /tmp/probe.out
exit 0
