#!/bin/bash
# THROWAWAY PROBE, never merged: runs candidate installers and prints what they write.
lib="$(cd "$(dirname "$0")/../../lib" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
main() {
source "$lib/guest-linux.sh"
need_curl
need_node 24 || echo "WARN: node 24 did not install"
need_user
need_pkgs unzip python3 || true
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
snap() { as_user "find ~ -mindepth 1 -maxdepth 4 -newer /tmp/probe-marker 2>/dev/null | grep -v -E '/\.cache/|/\.npm/' | sort | head -80"; }
echo "node $(node --version 2>&1)"

echo "=== npm @deepseek-ai/dsh"
touch /tmp/probe-marker; sleep 1
sudo_maybe npm install -g --no-fund --no-audit @deepseek-ai/dsh 2>&1 | tail -15
npm ls -g --depth=0 --json 2>&1 | head -30
pfx=$(npm prefix -g); ls -la "$pfx/bin" 2>&1 | grep -i -E "dsh|deepseek"
cat "$pfx/lib/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k:d.get(k) for k in ("name","version","bin","engines","repository","homepage","os","optionalDependencies")})'
try_user "dsh --version" "dsh --version </dev/null" || true
echo "--- new files after --version"; snap
touch /tmp/probe-marker; sleep 1
as_user "timeout 40 dsh --profile headless hi </dev/null" 2>&1 | tail -8
echo "--- new files after headless"; snap
as_user 'ls -1d ~/.*/ 2>&1'

echo "=== opencode v2 installer"
touch /tmp/probe-marker; sleep 1
curl -sS -o /tmp/oc2.sh -w "HTTP %{http_code}\n" -L https://opencode.ai/v2/install; head -c 400 /tmp/oc2.sh; echo
chmod 0644 /tmp/oc2.sh
try_user "opencode v2 installer" "bash /tmp/oc2.sh </dev/null" || true
echo "--- new files after install"; snap

echo "=== candidate Chrome extension CRX manifests"
for id in hehggadaopoacecdllhhajmbjkdcmajg; do
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
keys = ("name", "short_name", "version", "author", "homepage_url", "description", "permissions",
        "optional_permissions", "host_permissions", "side_panel", "externally_connectable")
print(sys.argv[2], json.dumps({k: tr(m.get(k)) for k in keys}, indent=1)[:3000])
print("content_scripts:", json.dumps(m.get("content_scripts"))[:600])
PY
done
}
main 2>&1 | tee /tmp/probe.out
python3 "$HERE/emit.py" /tmp/probe.out
exit 0
