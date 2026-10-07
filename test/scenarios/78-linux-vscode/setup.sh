#!/bin/bash
# THE SCENARIO THAT RETIRES A BLIND SPOT. docs/blind-spots.yaml said "VS Code extensions
# -- osquery has no table for them at all", which was true when it was written and false
# from osquery 5.11.0. Cline ships as a VS Code extension first, so it was invisible on
# its primary route while the catalog listed it under npm.
#
# Continue is installed too, asserted beside Cline: both are bring-your-own-model
# extensions that edit code, so a matcher that found one and not the other would be
# drawing a distinction nothing in the tree justifies.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"
need_curl
need_user
need_vscode
install_vscode_ext saoudrizwan.claude-dev continue.continue
# as_user, NOT try_user: `try` is quiet on success by design, so wrapping an
# INFORMATIONAL command in it printed a header with nothing under it.
echo "--- extensions the CLI reports:"
as_user 'code --no-sandbox --list-extensions --show-versions' 2>&1 | sed 's/^/      /' || true
echo "--- extensions on disk:"
home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)
as_user_ls "$home/.vscode/extensions" | head -10 || diagnose code
