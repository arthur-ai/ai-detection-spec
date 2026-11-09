#!/bin/zsh
# THROWAWAY PROBE, never merged: finds Opera Neon's current macOS download and prints what
# it installs, so catalog values are read off a real install.
HERE="$(cd "$(dirname "$0")" && pwd)"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'
main() {
source "$HERE/../../lib/guest.sh"
need_brew
touch /tmp/probe-marker
echo "=== brew info opera-neon"
brew info --cask opera-neon 2>&1 | head -20
echo "=== download links on operaneon.com and opera.com"
for page in https://www.operaneon.com/ https://www.operaneon.com/download https://www.opera.com/download https://www.opera.com/neon; do
  curl -sSL -A "$UA" -m 30 -o /tmp/page.html -w "$page HTTP %{http_code} -> %{url_effective}\n" "$page"
  grep -oiE 'https?://[^"'"'"' <>]*(neon|download|\.dmg|\.exe)[^"'"'"' <>]*' /tmp/page.html | sort -u | head -40
done
echo "=== candidate endpoints"
for u in 'https://net.geo.opera.com/opera_neon/stable/mac' 'https://net.geo.opera.com/opera_neon/stable/mac?utm_source=operaneon' \
         'https://download.opera.com/download/get/?partner=www&opsys=MacOS&product=Opera%20Neon' \
         'https://net.geo.opera.com/neon/stable/mac' 'https://get.geo.opera.com/pub/opera_neon/'; do
  curl -sS -A "$UA" -m 30 -o /dev/null -L -w "$u HTTP %{http_code} -> %{url_effective} type %{content_type} bytes %{size_download}\n" -r 0-0 "$u"
done
}
main 2>&1 | tee /tmp/probe.out
python3 "$HERE/emit.py" /tmp/probe.out
exit 0
