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

PROBE_NAME=99-linux-devin-cli

# ---- PROBE ONLY, never merged: what landed, as annotations readable over REST.
probe_emit() { local b="$2"; b="${b//'%'/%25}"; b="${b//$'\r'/}"; b="${b//$'\n'/%0A}"; echo "::notice title=$1::${b:0:3900}"; }
probe_tag="$PROBE_NAME $( (. /etc/os-release && echo "$ID-$VERSION_ID") )-$(uname -m)"
sudo_maybe osqueryi --json < osquery/dist/discovery-linux.sql > /tmp/probe.json 2>/dev/null || true
probe_emit "ver $probe_tag" "$( for c in maki prime-agent omp devin mastracode command-code; do
  as_user "PATH=\$HOME/.bun/bin:\$PATH; command -v $c >/dev/null && echo $c=\$(command -v $c) \$(timeout 30 $c --version </dev/null 2>&1 | head -2 | tr '\n' ' ')" 2>&1; done )"
probe_emit "rows $probe_tag" "$(grep -E '"kind":"(npm|file|brew)"' /tmp/probe.json | grep -i -E 'omp|mastra|command|devin|maki|prime|pi-coding|earendil' \
  | grep -v -P '@oh-my-pi/(?!pi-coding-agent)' | sed -E 's/.*"id":"([^"]*)".*"kind":"([^"]*)".*"ver":"([^"]*)".*/\2 \1 \3/' | head -40)"
probe_emit "classify $probe_tag" "$(AI_DETECTION_SPEC_TELEMETRY=0 python3 bin/classify /tmp/probe.json 2>&1 | head -40)"
if [ "$PROBE_NAME" = 98-linux-installers-more ] && ! as_user 'test -e ~/.local/bin/prime-agent'; then
  probe_emit "prime $probe_tag" "$(as_user 'curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh' 2>&1 | tail -25; ldd --version 2>&1 | head -1)"
fi
