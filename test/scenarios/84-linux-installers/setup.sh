#!/bin/bash
# THE VENDORS' OWN CURL INSTALLERS: the route each of these agents documents first, and the
# one no package manager records. Every one lands where the enumeration already reaches --
# a file directly under ~/.local/bin, or a top-level ~/.<dir>/ -- so this scenario needed
# catalog values and nothing in queries/. Read off the installers on 2026-10-07:
#
#   opencode    ~/.opencode/bin/opencode    the route is ~/.opencode; bin/ is a level too deep
#   Grok Build  ~/.grok/bin/grok            likewise ~/.grok
#   Cursor CLI  ~/.local/bin/cursor-agent   a link into ~/.local/share/cursor-agent/versions/
#   goose       ~/.local/bin/goose
#   Kiro CLI    ~/.local/bin/kiro-cli       beside kiro-cli-chat and kiro-cli-term
#   Pi          ~/.pi/agent/install/        npm ci into a prefix npm_packages never reads,
#                                           so the route is ~/.pi. Read on 2026-10-19
#
# Cursor and Grok also write ~/.local/bin/agent and ~/.grok/bin/agent. A name that generic
# identifies nothing, so neither is catalogued.
#
# SEPARATE from 71-linux-cli-agents, which installs opencode from npm: two routes for one
# binary name cannot share a host.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
# opencode and Kiro CLI unzip their archive; goose's tarball needs bzip2.
need_pkgs unzip bzip2 tar || true
# Pi's installer wants Node 22.19 or newer and, with no terminal to ask on, exits rather
# than install it.
need_node 22 || echo "WARN: Node 22 did not install"

# Through retry, and an attempt counts only if it left the file the installer should.
# Run locally, Cursor's package and VS Code both arrived truncated -- `curl: (18)` -- and no
# installer here retries a partial transfer. Checking the file matters for Kiro CLI too: its
# installer prompts on /dev/tty when a previous attempt left the binary behind. Running out
# still fails the assertion, which names the agent.
vendor_once() { try_user "$1" "$3" && as_user "test -e $2"; }
vendor() { retry "$1" vendor_once "$@"; }
vendor "the opencode installer" '~/.opencode/bin/opencode' \
  'curl --retry 3 -fsSL https://opencode.ai/install | bash' || true
vendor "the Grok Build installer" '~/.grok/bin/grok' \
  'curl --retry 3 -fsSL https://x.ai/cli/install.sh | bash' || true
vendor "the Cursor CLI installer" '~/.local/bin/cursor-agent' \
  'curl --retry 3 -fsS https://cursor.com/install | bash' || true
# CONFIGURE=false, or the installer starts goose's interactive provider setup.
vendor "the goose installer" '~/.local/bin/goose' \
  'curl --retry 3 -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash' || true
vendor "the Kiro CLI installer" '~/.local/bin/kiro-cli' \
  'curl --retry 3 -fsSL https://cli.kiro.dev/install | bash' || true
vendor "the Pi installer" '~/.pi/agent/bin/pi' \
  'curl --retry 3 -fsSL https://pi.dev/install.sh | sh' || true

echo "--- what landed in the user's home:"
as_user 'ls -1d ~/.*/ ~/.local/bin/* 2>&1' | sed 's/^/      /'
