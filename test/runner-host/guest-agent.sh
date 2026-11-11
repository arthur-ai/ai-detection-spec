#!/bin/bash
# Runs INSIDE a runner VM, at login, as the LaunchAgent com.arthur-ai.runner that bake.sh
# installs. It starts the GitHub runner for exactly one job, then powers the VM off, and
# the host deletes it. docs/macos-runners.md is the runbook.
#
# A LAUNCHAGENT, NOT SSH, because a LaunchAgent runs in the logged-in user's GUI (Aqua)
# session and SSH has none: 50-autonomous runs `open -a`, which needs one, and
# 45-claude-extension/setup.sh records the same limit for Chrome. A GitHub-hosted runner
# runs its jobs in such a session, and the observations must not depend on whose Mac it was.
set -u
STATE="$HOME/.arthur-runner"
mkdir -p "$STATE"
exec >>"$STATE/agent.log" 2>&1
# bake.sh asserts this says Aqua before it keeps the image.
launchctl managername > "$STATE/session" 2>&1

# Both shares are read-only, and the host writes them before the VM boots: the runner
# release in runner/, this job's single-use registration in jit/. Neither exists when
# bake.sh boots the image to check it, and the agent then waits, which is what bake expects.
SHARE="/Volumes/My Shared Files"
until [ -s "$SHARE/jit/config" ] && [ -s "$SHARE/runner/actions-runner.tar.gz" ]; do sleep 2; done

# Homebrew's python3 and pip3 ahead of the system's, as on a hosted runner; the scenario
# job runs `pip3 install pyyaml`. env.sh writes this PATH into the runner's .path, which is
# the environment its jobs get.
eval "$(/opt/homebrew/bin/brew shellenv)"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

power_off() { echo "$(date -u +%FT%TZ) $*"; sudo -n shutdown -h now; exit 1; }
rm -rf "$HOME/actions-runner"
mkdir "$HOME/actions-runner" || power_off "no runner directory"
cd "$HOME/actions-runner" || power_off "no runner directory"
tar -xzf "$SHARE/runner/actions-runner.tar.gz" || power_off "the runner tarball did not unpack"
[ -x ./env.sh ] && ./env.sh >/dev/null

# One job, then the runner deregisters itself and exits. The host sees the registration
# disappear and the VM power off, and deletes the disk.
./run.sh --jitconfig "$(cat "$SHARE/jit/config")"
power_off "run.sh exited $?"
