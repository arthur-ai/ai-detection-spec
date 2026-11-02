#!/bin/bash
# Devin CLI, Cognition's terminal agent, through its curl installer. Read off this script's
# runs on 2026-11-02: cli.devin.ai/install.sh writes ~/.local/bin/devin, and --version writes
# no state directory.
#
# SEPARATE from 97-linux-cli-agents-npm-more, which installs Devin CLI from npm: both put a
# `devin` on PATH.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_pkgs tar gzip || true

retry "the Devin CLI installer" try_user "the Devin CLI installer" \
  'curl --retry 3 -fsSL https://cli.devin.ai/install.sh | bash && test -e ~/.local/bin/devin' || true
echo "--- devin: $(as_user 'timeout 30 ~/.local/bin/devin --version </dev/null' 2>&1 | head -1)"
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
