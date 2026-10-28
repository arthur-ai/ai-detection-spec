#!/bin/zsh
# THE RETIRED NAMES, INSTALLED FOR REAL.
#
# Named for its SUBJECT, not for a vintage. "legacy" says only that something is
# old; `retired` is the word catalog/agents.yaml already uses for these identifiers,
# so the scenario and the data it proves share a vocabulary.
#
# OpenClaw carries four identifiers from its Moltbot/Clawdbot lineage, kept because
# machines that installed the earlier version still report them. They were treated as
# untestable-by-construction -- nothing installs them any more, so no scenario can cover
# one -- and that was wrong. Both retired npm packages are still published:
#
#     clawdbot  2026.1.24-3        moltbot  0.1.0
#
# So the alias is reachable exactly the way the machines that carry it got there: install
# the old package. This is the only scenario in the suite that deliberately installs
# software nobody should be running, and that is the point -- the fleet it exists for is
# the one that installed it before the rename and never upgraded.
#
# NEVER RUN THIS SETUP ON A MANAGED HOST. It installs deliberately outdated software, and
# that is safe only because the guest is disposable, unenrolled and holds no credentials.
# This line used to live in expected.json's known_gaps and so was rendered into the coverage
# report, which is the one place nobody reads before running a script.
#
# SEPARATE from 55-openclaw-npm on purpose. All three packages provide an `openclaw`-ish
# binary and npm would have them fight over the same global bin, so the current name and
# the retired ones cannot share a machine without one masking the other.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_node

# --allow-scripts is refused by older npm, and these packages predate it. Fall back
# rather than fail: the postinstall is not what is being tested, the package NAME is.
retired_once() {
  npm install -g "$1" --allow-scripts="$1" 2>/dev/null || npm install -g "$1" --ignore-scripts
}
for pkg in clawdbot moltbot; do
  retry "npm install -g $pkg" retired_once "$pkg" || echo "WARN: $pkg install failed"
done
npm ls -g --depth=0 2>/dev/null | sed 's/^/  /'
