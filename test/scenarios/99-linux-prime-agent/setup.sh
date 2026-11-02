#!/bin/bash
# Prime Intellect's Prime Agent, through its curl installer. Read off this script's runs on
# 2026-11-02: app.primeintellect.ai/prime-agent/install.sh writes ~/.local/bin/prime-agent
# and ~/.prime, which is evidence, not a value (catalog/agents.yaml says why).
#
# ITS OWN SCENARIO because of a glibc floor. The installer refuses glibc 2.34 -- "the Linux
# builds are compiled against glibc 2.35 (Ubuntu 22.04) and will not start here", measured
# on Rocky 9 and Amazon Linux 2023 -- so this exits 3 there, a fact about the image rather
# than a failed download, and the other agents' installers in 98 still run on both.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
if [ -z "$glibc" ] || [ "$(printf '%s\n2.35\n' "$glibc" | sort -V | head -1)" != 2.35 ]; then
  echo "SKIP: glibc ${glibc:-unknown} is below Prime Agent's 2.35 floor"
  exit 3
fi
need_curl
need_user
need_pkgs tar gzip || true

retry "the Prime Agent installer" try_user "the Prime Agent installer" \
  'curl --retry 3 -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh && test -e ~/.local/bin/prime-agent' || true
echo "--- prime-agent: $(as_user 'timeout 30 ~/.local/bin/prime-agent --version </dev/null' 2>&1 | head -1)"
echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
