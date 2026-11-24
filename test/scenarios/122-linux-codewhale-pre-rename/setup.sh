#!/bin/bash
# CODEWHALE BEFORE ITS RENAME: npm's `deepseek-tui`, which installs `deepseek`, read off probe
# run 45468880057 on 2026-11-24.
#
# 0.8.39 IS PINNED: it is the last deepseek-tui that ships the agent. `latest` is a
# deprecation notice that declares no bin, which the catalog and known_gaps say, so a
# `latest` that declares one again fails here.
#
# ITS OWN SCENARIO, apart from 94's other previous names, because its prebuilt binary needs
# glibc 2.39: Ubuntu 24.04 has it, and on Rocky 9, at 2.34, the postinstall refuses and npm
# removes the package. A host below 2.39 SKIPs.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
if [ -z "$glibc" ] || [ "$(printf '%s\n' 2.39 "$glibc" | sort -V | head -1)" != 2.39 ]; then
  echo "SKIP: deepseek-tui 0.8.39's binary needs glibc 2.39, and this host has ${glibc:-none}"
  exit 3
fi
need_curl
need_user
# 18 because the package declares node >=18.
need_node 18 || echo "WARN: Node 18 did not install"

latest=$(npm view deepseek-tui@latest version 2>/dev/null || true)
if [ -z "$latest" ]; then
  echo "WARN: npm did not answer for deepseek-tui@latest, so its missing bin is unchecked"
elif [ -n "$(npm view "deepseek-tui@$latest" bin 2>/dev/null)" ]; then
  echo "FAIL: deepseek-tui@$latest declares a bin, so it is no longer only a notice"; exit 1
fi
retry "npm install -g deepseek-tui@0.8.39" try "npm install -g deepseek-tui@0.8.39" \
  sudo_maybe npm install -g --no-fund --no-audit deepseek-tui@0.8.39 || true
echo "--- the globals npm recorded:"
npm ls -g --depth=0 2>/dev/null | sed 's/^/      /'

# RUN ONCE, WITHOUT A KEY, where it stops. expected.json holds ~/.deepseek, which its message
# names for the key, unwritten: the catalog declines that directory as one no install
# produced. The binary links libdbus, which a bare container image lacks, and a run that
# never reached the key check says nothing about the directory, so that case WARNs.
need_pkgs libdbus-1-3 || need_pkgs dbus-libs || true
out=$(as_user 'timeout 60 deepseek exec "say hi" </dev/null' 2>&1 || true)
printf '%s\n' "$out" | tail -2 | sed 's/^/      /'
case "$out" in
  *.deepseek/config.toml*) ;;
  *) echo "WARN: deepseek did not reach its key check, so ~/.deepseek's absence is unproved here" ;;
esac
