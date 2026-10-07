#!/bin/bash
# A bun global, which osquery's npm_packages never looks for: its search list has npm, nvm,
# asdf, fnm, mise and volta, and not ~/.bun. queries/packages.sql reaches it with a
# `directory` constraint per home, and this is the run that proves the constraint is pushed
# down rather than applied after a scan of the default list, which would return nothing.
#
# ONE VARIABLE. 71 proves @google/gemini-cli through npm's own prefix, so the only thing
# this run can be wrong about is the directory. gemini-cli also has no lifecycle script,
# so bun's habit of blocking untrusted postinstall scripts cannot be why a row is missing.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
# The installer's one requirement beyond curl. A base image has no unzip.
command -v unzip >/dev/null 2>&1 || need_pkgs unzip || echo "WARN: unzip did not install"

try_user "the bun installer" 'curl --retry 3 -fsSL https://bun.sh/install | bash' || true
# BY PATH: as_user's PATH does not carry ~/.bun/bin, and nothing here should depend on the
# installer having edited a shell profile.
try_user "bun add -g @google/gemini-cli" '~/.bun/bin/bun add -g @google/gemini-cli' || true

home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
echo "--- bun $(as_user '~/.bun/bin/bun --version' 2>&1)"
# Logged, not asserted: whether the tree is hoisted (dependencies beside the global) or
# isolated (a .bun store plus symlinks) decides how many rows a global costs.
echo "--- the global node_modules:"
as_user_ls "$home/.bun/install/global/node_modules" "$home/.bun/install/global/node_modules/@google" \
  | sed 's/^/      /'
echo "--- as osquery reads it:"
sudo_maybe osqueryi --json \
  "SELECT name, version, path FROM npm_packages WHERE directory = '$home/.bun/install/global'" \
  | sed 's/^/      /' || diagnose osqueryi
