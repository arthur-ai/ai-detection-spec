#!/bin/zsh
# Demo row: OpenClaw (3 devices) - the punchline. An autonomous agent with shell
# access bridged to consumer messaging apps.
#
# Running the real thing is acceptable ONLY here: a disposable VM with no corporate
# data, no MDM enrolment and no credentials. Never on a managed host.
#
# Requires macOS 15+. See requires.json - run.sh skips this scenario rather than
# failing it when the guest is older, because a Tart guest cannot be newer than the
# host and the OpenClaw cask refuses to install below Sequoia.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install --cask openclaw
open -a OpenClaw 2>/dev/null || true
sleep 30
