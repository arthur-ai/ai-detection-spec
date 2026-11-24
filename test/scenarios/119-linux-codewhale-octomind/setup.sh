#!/bin/bash
# Two terminal coding agents through their vendors' curl installers, read off probe run
# 45238894100 on 2026-11-23:
#
#   Codewhale   codewhale.net/install.sh   ~/.local/bin/codewhale (and codew, a hard link
#                                          to it); ~/.codewhale once run, not on --version
#   Octomind    Muvon/octomind install.sh  ~/.local/bin/octomind; its data directory is
#                                          ~/.local/share/octomind, which no route reads
#
# Codewhale is run without a key so it writes ~/.codewhale and stops at provider setup.
# SEPARATE from 115-linux-npm-codewhale-qa, which installs Codewhale from npm: both routes
# put `codewhale` on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs tar gzip || true

# An attempt counts only if it left the file the installer should; 84 says why.
vendor_once() { try_user "$1" "set -o pipefail; $3" && as_user "test -e $2"; }
vendor() { retry "$1" vendor_once "$@"; }
# --no-modify-path keeps Codewhale's out of the user's shell rc, which nothing here reads.
vendor "the Codewhale installer" '~/.local/bin/codewhale' \
  'curl --retry 3 -fsSL https://codewhale.net/install.sh | sh -s -- --no-modify-path' || true
vendor "the Octomind installer" '~/.local/bin/octomind' \
  'curl --retry 3 -fsSL https://raw.githubusercontent.com/muvon/octomind/master/install.sh | bash' || true

# Fails at provider setup with no key, after writing ~/.codewhale.
as_user 'timeout 60 codewhale exec "say hi" </dev/null' >/dev/null 2>&1 || true
echo "--- versions:"
for c in codewhale octomind; do
  echo "      $c: $(as_user "timeout 30 $c --version </dev/null" 2>&1 | head -1)"
done
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
