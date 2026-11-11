#!/usr/bin/env bash
# Build arthur-runner-<major>, the image every job on label macos-<major> boots a clone of.
#
#   test/runner-host/bake.sh 15        # or 26
#
# From a digest-pinned Cirrus Labs base image, which already has Homebrew, auto-login and
# user admin/admin, it adds Homebrew python3, passwordless sudo, the guest agent and no
# software updates. It keeps the result only after booting it again and finding the agent
# running in the GUI session. The previous image stays as arthur-runner-<major>-prev.
# docs/macos-runners.md is the runbook; distribute the result with `tart export`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/runner-host/common.sh
source "$HERE/common.sh"

n="${1:?usage: bake.sh <macOS major: 15 or 26>}"
# PINNED BY DIGEST: a moving tag would change the OS under every observation with no diff
# here. Read off ghcr.io on 2026-11-04 (uploaded 2026-10-03 and 2026-10-15). To move one,
# read the new digest the same way and bake again.
case "$n" in
  15) BASE_IMAGE=ghcr.io/cirruslabs/macos-sequoia-base@sha256:eee659985b01e4df2a6c0754bd8d25e54969933c43fdcd4edef8bea337b3d354 ;;
  26) BASE_IMAGE=ghcr.io/cirruslabs/macos-tahoe-base@sha256:4aaa751fa7538902d73c767f27a066fc87e83f183069da4e4b5022863abd4c77 ;;
  *) die "no base image is pinned for macOS $n" ;;
esac
VM_CPUS=$RH_CPUS VM_MEM=$RH_MEM
export BASE_IMAGE VM_CPUS VM_MEM
# shellcheck source=test/lib/vm.sh
source "$HERE/../lib/vm.sh"

image="arthur-runner-$n"
vm="$image-bake"
[ "$(host_macos_major)" -ge "$n" ] \
  || die "this host runs macOS $(host_macos_major), and a guest cannot be newer than its host"
# A slot clones $image between jobs, and renaming it under one would hand that slot half an
# image. Stop them first: host-setup.sh stop.
# grep without -q: under pipefail, -q exits at the first match and the SIGPIPE it leaves
# launchctl makes a match read as none.
if launchctl list | grep com.arthur-ai.runner-slot >/dev/null; then
  die "runner slots are loaded on this host; run host-setup.sh stop first"
fi
vm_require

done_ok=0
cleanup() { [ "$done_ok" = 1 ] || [ "${KEEP_VM:-0}" = 1 ] || vm_destroy "$vm"; }
trap cleanup EXIT
tart delete "$vm" 2>/dev/null || true
vm_create "$vm"
vm_boot "$vm"          # also writes the NOPASSWD sudoers entry the workflow's sudo needs

log "provisioning $vm from $BASE_IMAGE"
# Copied and run as a file, never fed to `bash -s`: a command in it that reads stdin
# would swallow the rest of the script.
vm_put "$vm" "$HERE/bake-guest.sh" /tmp/bake-guest.sh
vm_ssh "$vm" "bash /tmp/bake-guest.sh && rm -f /tmp/bake-guest.sh"
vm_put "$vm" "$HERE/guest-agent.sh" .arthur-runner/guest-agent.sh
plist=$(mktemp "${TMPDIR:-/tmp}/agent.XXXXXX")
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.arthur-ai.runner</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>/Users/$VM_USER/.arthur-runner/guest-agent.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
plutil -lint "$plist" >/dev/null
vm_put "$vm" "$plist" Library/LaunchAgents/com.arthur-ai.runner.plist
rm -f "$plist"

# THE CHECK DECIDES, NOT THE INSTALL. Power off and boot again, the way every clone will,
# and keep the image only if the agent came up on its own, in the GUI session.
log "rebooting $vm to check the agent"
vm_ssh "$vm" "sudo -n shutdown -h now" || true
for _ in $(seq 60); do kill -0 "$(cat "/tmp/arthur-vm-$vm.pid")" 2>/dev/null || break; sleep 2; done
tart stop "$vm" >/dev/null 2>&1 || true
vm_boot "$vm"
session=""
for _ in $(seq 60); do
  session=$(vm_ssh "$vm" "cat ~/.arthur-runner/session 2>/dev/null" || true)
  [ -n "$session" ] && break
  sleep 2
done
[ "$session" = Aqua ] \
  || die "the agent reported session '${session:-nothing}', not Aqua; open -a would fail in jobs"
vm_ssh "$vm" "pgrep -f guest-agent.sh >/dev/null" || die "the agent is not running after login"
vm_ssh "$vm" "sudo -n true" || die "passwordless sudo is not in effect"
vm_ssh "$vm" "/opt/homebrew/bin/python3 -m pip --version >/dev/null" || die "no Homebrew pip3"
free=$(vm_ssh "$vm" "df -g / | awk 'NR==2 {print \$4}'")
# GitHub's hosted M1 runner has 14 GB of disk, and the scenarios were written against it.
[ "$free" -ge 14 ] || die "the guest has ${free} GB free, below the hosted runner's 14"
guest_os=$(vm_ssh "$vm" "sw_vers -productVersion")
# The clones start from this disk, so the check's own traces go.
vm_ssh "$vm" "rm -f ~/.arthur-runner/session ~/.arthur-runner/agent.log"

vm_ssh "$vm" "sudo -n shutdown -h now" || true
for _ in $(seq 60); do kill -0 "$(cat "/tmp/arthur-vm-$vm.pid")" 2>/dev/null || break; sleep 2; done
tart stop "$vm" >/dev/null 2>&1 || true
rm -f "/tmp/arthur-vm-$vm.pid" "/tmp/arthur-vm-$vm.ip"
if tart list --format json | jq -e --arg i "$image" '.[] | select(.Name == $i)' >/dev/null; then
  tart delete "$image-prev" 2>/dev/null || true
  tart rename "$image" "$image-prev"
fi
tart rename "$vm" "$image"
done_ok=1
log "baked $image: macOS $guest_os, ${free} GB free, from $BASE_IMAGE"
