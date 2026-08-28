#!/usr/bin/env bash
# Thin wrapper over Tart. Every VM is an ephemeral clone of a pinned base image,
# so runs are repeatable and nothing persists between scenarios.
set -euo pipefail

# A guest cannot be newer than its host or the VM will not boot -- verified the hard way
# here: a Sequoia guest would not start on a Sonoma 14.6 host.
#
# So pick the NEWEST guest this host can actually run rather than hardcoding one. A
# hardcoded old guest silently skips every scenario needing a newer OS, and a skip nobody
# notices is how 50-autonomous (OpenClaw needs Sequoia) stayed unverified.
#
# Apple's versioning is not contiguous: Sonoma 14, Sequoia 15, then Tahoe jumps to 26.
image_for_macos() {
  case "$1" in
    ''|*[!0-9]*) echo "ghcr.io/cirruslabs/macos-sonoma-base:latest" ;;
    *) if   [ "$1" -ge 26 ]; then echo "ghcr.io/cirruslabs/macos-tahoe-base:latest"
       elif [ "$1" -ge 15 ]; then echo "ghcr.io/cirruslabs/macos-sequoia-base:latest"
       else                       echo "ghcr.io/cirruslabs/macos-sonoma-base:latest"
       fi ;;
  esac
}
host_macos_major() { sw_vers -productVersion 2>/dev/null | cut -d. -f1; }

# Pin to a digest before CI.
: "${BASE_IMAGE:=$(image_for_macos "$(host_macos_major)")}"
: "${VM_USER:=admin}"
: "${VM_PASS:=admin}"
: "${VM_CPUS:=4}"
: "${VM_MEM:=8192}"

vm_require() {
  echo "host macOS $(sw_vers -productVersion) -> guest $(basename "$BASE_IMAGE")"
  command -v tart >/dev/null || { echo "tart not found: brew install cirruslabs/cli/tart" >&2; exit 1; }
  command -v sshpass >/dev/null || { echo "sshpass not found: brew install sshpass" >&2; exit 1; }
}

vm_pull()   { tart list | grep -q "$(basename "$BASE_IMAGE")" || tart pull "$BASE_IMAGE"; }
vm_create() { tart clone "$BASE_IMAGE" "$1"; tart set "$1" --cpu "$VM_CPUS" --memory "$VM_MEM"; }

vm_boot() {
  tart run --no-graphics "$1" >/dev/null 2>&1 &
  echo $! > "/tmp/arthur-vm-$1.pid"
  local ip="" i=0
  until [ -n "$ip" ] || [ $i -ge 60 ]; do ip=$(tart ip "$1" 2>/dev/null || true); sleep 2; i=$((i+1)); done
  [ -n "$ip" ] || { echo "VM $1 never got an IP" >&2; return 1; }
  echo "$ip" > "/tmp/arthur-vm-$1.ip"
  i=0; until vm_ssh "$1" true 2>/dev/null || [ $i -ge 60 ]; do sleep 2; i=$((i+1)); done
  vm_ssh "$1" true || { echo "SSH to $1 never came up" >&2; return 1; }

  # Do the password dance exactly once, here, so every later sudo can use -n and leave
  # stdin free. `echo pw | sudo -S cmd < file` is a trap: the pipe and the redirect both
  # claim sudo's stdin, and the loser silently feeds the wrong bytes to the wrong process.
  vm_ssh "$1" "echo '$VM_PASS' | sudo -S sh -c \
      'echo \"$VM_USER ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/arthur-test && chmod 440 /etc/sudoers.d/arthur-test'" \
    || { echo "could not enable passwordless sudo on $1" >&2; return 1; }
  vm_ssh "$1" "sudo -n true" || { echo "passwordless sudo not in effect on $1" >&2; return 1; }
}

vm_ssh() {
  local name="$1"; shift
  sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$VM_USER@$(cat "/tmp/arthur-vm-$name.ip")" "$@"
}

vm_put() {
  local name="$1" src="$2" dst="$3"
  sshpass -p "$VM_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$src" "$VM_USER@$(cat "/tmp/arthur-vm-$name.ip"):$dst"
}

vm_destroy() {
  local name="$1"
  [ -f "/tmp/arthur-vm-$name.pid" ] && kill "$(cat "/tmp/arthur-vm-$name.pid")" 2>/dev/null || true
  sleep 2; tart delete "$name" 2>/dev/null || true
  rm -f "/tmp/arthur-vm-$name.pid" "/tmp/arthur-vm-$name.ip"
}
