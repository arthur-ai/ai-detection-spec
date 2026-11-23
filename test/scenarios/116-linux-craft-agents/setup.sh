#!/bin/bash
# CRAFT AGENTS through its vendor's installer, thecraftagents.com/install-app.sh, which puts
# the AppImage at ~/.craft-agent/app/ and a launcher at ~/.local/bin/craft-agents. Read off
# probe run 45238894100 on 2026-11-23 and this scenario's own runs. Its own scenario for the
# download, as 13 was split from 10.
#
# THE INSTALLER CREATES ~/.craft-agent BEFORE IT DOWNLOADS ANYTHING, so that directory alone
# does not say an install finished; the launcher, written last, does, and expected.json pins
# it. Two things stopped the probe's runs short of it, and both are prepared for here:
#   - with a `yq` on PATH it parses the release manifest with jq syntax (`.version // empty`),
#     which the runner's yq, Mike Farah's, rejects: "lexer: invalid input text". It is moved
#     aside, so the installer takes its own grep path.
#   - it verifies the download with `xxd`, which the container images lack.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
# The installer refuses anything but x86_64 on Linux: "Linux currently only supports x64".
[ "$(uname -m)" = x86_64 ] || { echo "SKIP: Craft Agents ships no Linux build for $(uname -m)"; exit 3; }
need_curl
need_user
command -v xxd >/dev/null 2>&1 || need_pkgs xxd || need_pkgs vim-common \
  || echo "WARN: xxd did not install, so the installer's checksum step will fail"
yq=$(command -v yq || true)
[ -z "$yq" ] || sudo_maybe mv "$yq" "$yq.moved-aside"

craft_once() { try_user "$1" "set -o pipefail; $3" && as_user "test -e $2"; }
retry "the Craft Agents installer" craft_once "the Craft Agents installer" \
  '~/.local/bin/craft-agents' \
  'curl --retry 3 -fsSL https://thecraftagents.com/install-app.sh | bash' || true
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* ~/.craft-agent/app/* 2>&1' | sed 's/^/      /'
