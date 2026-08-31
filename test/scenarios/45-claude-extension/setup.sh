#!/bin/bash
# 45-claude-extension -- the Claude browser extension, matched by id.
#
# THIS SCENARIO CANNOT MANUFACTURE ITS OWN SUBJECT, and that is a property of Chrome
# rather than of the harness. A Web Store install can be forced only through
# ExtensionInstallForcelist, which Chrome honours only when it arrives as an MDM-delivered
# managed policy. An unenrolled Tart guest has no MDM: the policy is written, Chrome's
# updater wakes, fetches nothing, and every claimed id reports absent. Measured on macOS
# 26.6.2 / Chrome 152 -- the updater returned 0 having fetched nothing.
#
# Planting a fixture is NOT a substitute here, and 40-browser's known_gaps records why:
# osquery derives `identifier` from the manifest key, which an unpacked or sideloaded
# extension does not carry, so a planted extension reports an EMPTY identifier. A scenario
# built on one would assert that the matcher handles '' -- the opposite of what it exists
# to prove, and it would pass while proving nothing.
#
# So: assert when a real install is present, exit 3 (SKIP) when it is not. The
# id-matching logic itself is covered without a VM in test/test_matcher.py, against rows
# captured from a real install.
set -u
. "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"

CLAUDE_EXT=fcoeoabgfenejglbffodgkkbkcdhcgfn

# Ask the same table the shipping query asks, rather than looking for a directory: the
# question is what osquery REPORTS, and a directory on disk is not the same claim.
have=$(osqueryi --json \
  "SELECT identifier FROM users CROSS JOIN chrome_extensions USING (uid)
    WHERE identifier = '$CLAUDE_EXT';" 2>/dev/null | grep -c "$CLAUDE_EXT")

if [ "${have:-0}" -eq 0 ]; then
  echo "No real Claude extension install on this host."
  echo "Chrome will not force-install from the Web Store without an MDM-delivered policy,"
  echo "and a planted extension reports an empty identifier (see 40-browser known_gaps)."
  exit 3
fi

echo "Real Claude extension install present: $CLAUDE_EXT ($have row(s))"
