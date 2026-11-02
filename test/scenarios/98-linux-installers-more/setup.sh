#!/bin/bash
# Three terminal coding agents that herdr runs, through their vendors' curl installers.
# Read off this script's runs on 2026-11-02:
#
#   Maki          maki.sh/install.sh                             ~/.local/bin/maki
#   Prime Agent   app.primeintellect.ai/prime-agent/install.sh   ~/.local/bin/prime-agent, ~/.prime
#   Oh My Pi      omp.sh/install, with no bun here, so the       ~/.local/bin/omp; ~/.omp once run
#                 prebuilt binary
#
# ~/.local/bin/omp and ~/.prime are evidence, not values; catalog/agents.yaml says why. So
# ~/.omp is Oh My Pi's only witness here, and omp is run to write it.
#
# SEPARATE from 97-linux-cli-agents-npm-more, which installs Oh My Pi through bun: both put
# an `omp` on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs tar gzip || true

# An attempt counts only if it left the file the installer should, as in 84.
vendor_once() { try_user "$1" "$3" && as_user "test -e $2"; }
vendor() { retry "$1" vendor_once "$@"; }
vendor "the Maki installer" '~/.local/bin/maki' \
  'curl --retry 3 -fsSL https://maki.sh/install.sh | sh' || true
vendor "the Prime Agent installer" '~/.local/bin/prime-agent' \
  'curl --retry 3 -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh' || true
vendor "the Oh My Pi installer" '~/.local/bin/omp' \
  'curl --retry 3 -fsSL https://omp.sh/install | sh' || true

as_user 'timeout 60 omp --version </dev/null' >/dev/null 2>&1 || true
as_user 'timeout 60 omp -p hi </dev/null' >/dev/null 2>&1 || true
echo "--- versions:"
for c in maki prime-agent omp; do
  echo "      $c: $(as_user "timeout 30 $c --version </dev/null" 2>&1 | head -1)"
done
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
