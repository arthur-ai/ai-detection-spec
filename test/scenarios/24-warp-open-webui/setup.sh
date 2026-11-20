#!/bin/zsh
# The Warp app and Open WebUI on macOS, installed and not run, beside Arc, which the catalog
# declines.
#
#   Warp         cask `warp`, the app; its Agent CLI is 22's
#   Open WebUI   cask `open-webui`, the desktop app; and `uv tool install open-webui`, which
#                names its tool directory for the package (SPEC.md 6.4.6)
#   Arc          cask `arc`, The Browser Company's browser, asserted to claim nothing
#
# Every cask installs on the oldest macOS in the scenarios.yml matrix (10's floor rule). Read
# off the Homebrew API on 2026-11-20: warp declares no floor, arc and open-webui >= 13.
# Open WebUI declares Python >=3.11,<3.13, so uv is told 3.12.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
# THE ROW NAMES NO TAP, so each cask token is a value only while homebrew-core has no formula
# of the same name: 22 says why it is asserted this way.
for t in warp open-webui; do
  if brew info "homebrew/core/$t" >/dev/null 2>&1; then
    echo "FAIL: homebrew/core now has a \`$t\`, which the cask's value would claim"; exit 1
  fi
done
# Through retry, for 13's reason: a CDN can reset a transfer mid-download. Running out WARNs,
# so the assertion names the missing app.
for c in warp arc open-webui; do
  retry "$c" brew install --cask "$c" || true
done
retry "uv" brew install uv || true
retry "uv tool install open-webui" uv tool install --python 3.12 open-webui \
  || echo "WARN: open-webui did not install"
for app in Warp Arc "Open WebUI"; do
  if [ -d "/Applications/$app.app" ]; then
    echo "  $app: $(plutil -extract CFBundleIdentifier raw "/Applications/$app.app/Contents/Info.plist")"
  else
    echo "WARN: no /Applications/$app.app"
  fi
done
if [ -d ~/.local/share/uv/tools/open-webui ]; then echo "  landed: ~/.local/share/uv/tools/open-webui"
else echo "WARN: no uv tool directory for open-webui"; fi
