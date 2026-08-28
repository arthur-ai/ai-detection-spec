#!/bin/zsh
# Sourced by scenario setup.sh scripts. Each scenario declares what it needs.
#
# On a GitHub-hosted macOS runner these are all preinstalled and every function is a
# no-op, which is most of why running scenarios on the runner is cheaper than in a VM.
# On a bare Tart image (the local development path) they install what is missing.

need_clt() {
  xcode-select -p >/dev/null 2>&1 && return 0
  echo "--- installing Command Line Tools"
  # The usual `xcode-select --install` opens a GUI dialog, which is useless over SSH.
  # This is the documented headless route: the placeholder makes the CLT package visible
  # to softwareupdate, which can then install it non-interactively.
  sudo -n touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local label
  label=$(softwareupdate -l 2>/dev/null | grep -B1 -E 'Command Line (Developer|Tools)' \
          | awk -F'* ' '/\*/ {print $2}' | sed 's/^Label: //' | tail -1)
  [ -n "$label" ] && sudo -n softwareupdate -i "$label" --verbose
  sudo -n rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  xcode-select -p >/dev/null 2>&1
}

need_brew() {
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; return 0; fi
  need_clt || { echo "FAIL: Command Line Tools are a Homebrew prerequisite" >&2; return 1; }
  echo "--- installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

need_node() { command -v npm >/dev/null && return 0; need_brew && brew install node; }
