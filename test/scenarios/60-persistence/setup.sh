#!/bin/zsh
# Carries the `daemon` and `port` branches for the whole suite.
#
# Both are first-GUI-launch side effects of OpenClaw and Ollama, and SSH has no Aqua
# session to trigger them. 50-autonomous additionally cannot run below Sequoia. Rather
# than leave two branches permanently unverified - which is the exact state that made
# this harness necessary - they are exercised here with inert fixtures.
#
# The plist is NEVER LOADED and points at /usr/bin/true. That is the point: osquery's
# launchd table reads plists out of the standard directories rather than asking a
# running launchd what is scheduled. This scenario asserts that behaviour instead of
# assuming it, which the design explicitly called out as needing confirmation.
#
# It carries the REAL label because the query matches on the label prefix.
set -e
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.openclaw.gateway</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
PLIST

# A listener on the OpenClaw gateway port, so `port` has something to attribute. The
# query joins listening_ports to processes, so this must be a real process holding a
# real socket - not a fixture file.
nohup nc -l 18789 >/dev/null 2>&1 &
sleep 3
lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null || { echo "FAIL: nothing listening on 18789" >&2; exit 1; }
