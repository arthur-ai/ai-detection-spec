#!/bin/zsh
# 22-cli-installers -- the CLI agents' own installers on macOS, as 84-linux-installers runs
# them on Linux. Each writes under the home directory, where the catalog's path values are:
#
#   opencode    ~/.opencode/bin/opencode    the route is ~/.opencode
#   Grok Build  ~/.grok/bin/grok            likewise ~/.grok
#   Cursor CLI  ~/.local/bin/cursor-agent
#   goose       ~/.local/bin/goose
#   Kiro CLI    ~/.local/bin/kiro-cli
#
# SEPARATE from 21-cli-agents-homebrew, which installs four of these as formulae and casks
# that land elsewhere: two routes for one binary name cannot share a host.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

# Through retry, and an attempt counts only if it left the file the installer should, for
# 84's reasons: a truncated transfer, and Kiro CLI prompting on /dev/tty when a previous
# attempt left its binary behind.
vendor_once() { bash -c "$2" </dev/null && test -e "$1"; }
vendor() { local label="$1"; shift; retry "$label" vendor_once "$@"; }
vendor "the opencode installer" "$HOME/.opencode/bin/opencode" \
  'curl --retry 3 -fsSL https://opencode.ai/install | bash' || true
vendor "the Grok Build installer" "$HOME/.grok/bin/grok" \
  'curl --retry 3 -fsSL https://x.ai/cli/install.sh | bash' || true
vendor "the Cursor CLI installer" "$HOME/.local/bin/cursor-agent" \
  'curl --retry 3 -fsS https://cursor.com/install | bash' || true
# CONFIGURE=false, or the installer starts goose's interactive provider setup.
vendor "the goose installer" "$HOME/.local/bin/goose" \
  'curl --retry 3 -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash' || true
vendor "the Kiro CLI installer" "$HOME/.local/bin/kiro-cli" \
  'curl --retry 3 -fsSL https://cli.kiro.dev/install | bash' || true

echo "--- what landed in the home directory:"
ls -1d ~/.*/ ~/.local/bin/* 2>&1 | sed 's/^/      /'
