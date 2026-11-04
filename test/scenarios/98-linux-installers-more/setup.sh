#!/bin/bash
# Three terminal coding agents that herdr runs, through their vendors' curl installers.
# Read off this script's runs on 2026-11-02:
#
#   Maki        maki.sh/install.sh       ~/.local/bin/maki
#   Devin CLI   cli.devin.ai/install.sh  ~/.local/bin/devin; --version writes no state directory
#   Oh My Pi    omp.sh/install, with no bun here, so the prebuilt binary:
#                                        ~/.local/bin/omp, and ~/.omp once run
#
# ~/.local/bin/omp is evidence, not a value; catalog/agents.yaml says why. So ~/.omp is Oh My
# Pi's only witness here, and omp is run to write it.
#
# SEPARATE from 97-linux-cli-agents-npm-more, which installs Devin CLI from npm and Oh My Pi
# through bun: both routes put the same command on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs tar gzip || true

# An attempt counts only if it left the file the installer should, and pipefail makes a
# failed curl count as a failed attempt; 84 says why.
vendor_once() { try_user "$1" "set -o pipefail; $3" && as_user "test -e $2"; }
vendor() { retry "$1" vendor_once "$@"; }
# MAKI'S INSTALLER ASKS THE GITHUB API FOR ITS LATEST TAG, unauthenticated, and that API
# allows 60 requests an hour per IP, which a shared runner's IP can have spent: it answered
# 403 and the install failed on 3ed647bd (ubuntu-24.04) and bf8376ba (debian-12). The
# installer takes the tag as its first argument, so the tag is read off github.com's
# releases/latest redirect, which that limit does not count, and its own lookup stays the
# fallback. Rejected: passing GITHUB_TOKEN, which it also honors, because it would put a
# credential into every container that runs a vendor's script.
maki_tag="$(curl --retry 3 -fsSL -o /dev/null -w '%{url_effective}' \
  https://github.com/tontinton/maki/releases/latest \
  | sed -n 's#.*/releases/tag/\([A-Za-z0-9._-]*\)$#\1#p')" || maki_tag=""
[ -n "$maki_tag" ] \
  || echo "WARN: no tag from github.com/tontinton/maki/releases/latest; Maki's installer looks it up" >&2
vendor "the Maki installer" '~/.local/bin/maki' \
  "curl --retry 3 -fsSL https://maki.sh/install.sh | sh -s -- $maki_tag" || true
# DEVIN'S INSTALLER ENDS BY RUNNING `devin setup`, which asks to log in and, without a TTY,
# exits 1 with "Login canceled" after the binary is in place (every image, run 41772215488).
# So its exit status is not the verdict here; the file is. Without this, vendor() retried a
# finished install twice more and reported it failed above a passing must_find.
vendor "the Devin CLI installer" '~/.local/bin/devin' \
  'curl --retry 3 -fsSL https://cli.devin.ai/install.sh | bash || test -e ~/.local/bin/devin' || true
vendor "the Oh My Pi installer" '~/.local/bin/omp' \
  'curl --retry 3 -fsSL https://omp.sh/install | sh' || true

# omp fails without credentials after writing ~/.omp.
as_user 'timeout 60 omp --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 omp -p hi </dev/null' >/dev/null 2>&1 || true
echo "--- versions:"
for c in maki devin omp; do
  echo "      $c: $(as_user "timeout 30 $c --version </dev/null" 2>&1 | head -1)"
done
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
