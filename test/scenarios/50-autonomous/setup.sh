#!/bin/zsh
# Demo row: OpenClaw (3 devices) - the punchline. An autonomous agent with shell
# access bridged to consumer messaging apps.
#
# Running the real thing is acceptable ONLY here: a disposable VM with no corporate
# data, no MDM enrolment and no credentials. Never on a managed host.
#
# The cask has a macOS floor, recorded in requires.json. Below that floor run.sh and CI
# skip this scenario rather than fail it: the cask refuses to install, and a Tart guest
# cannot be newer than its host.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest.sh"
need_brew
brew install --cask openclaw
# IN THE BACKGROUND, WITH ITS STREAMS CLOSED. On macos-26 since runner image 20261012.601
# (OpenClaw 2026.10.2), `open` launches the app and then never returns on most runs: at
# cancellation the runner's cleanup found OpenClaw, `open` and this zsh all still running.
# In the foreground that held the step to the job's 360-minute limit. The app is what the
# query needs, and it is up either way.
open -a OpenClaw </dev/null >/dev/null 2>&1 &!
launcher=$!
sleep 30
if kill -0 "$launcher" 2>/dev/null; then
  echo "WARN: open -a OpenClaw has not returned after 30s. Its processes:"
  ps -axo pid,ppid,etime,command | grep '[O]penClaw' | sed 's/^/    /'
fi
