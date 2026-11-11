#!/bin/bash
# Run by bake.sh INSIDE a fresh runner VM, over SSH: what the base image lacks. bake.sh
# installs the guest agent itself and then checks everything this did.
set -euo pipefail
eval "$(/opt/homebrew/bin/brew shellenv)"

# Homebrew's python3 and pip3, first on PATH as on a hosted runner. The scenario job calls
# `pip3 install pyyaml` by name, and the Command Line Tools' python3 is a different, older
# interpreter than the one the scenarios were measured with.
brew install python

# NO UPDATES INSIDE A GUEST. A clone lives for one job, so an update could never finish, and
# its download would compete with the job's on a Wi-Fi link every slot shares. The OS a
# job sees moves when bake.sh moves the pinned base image, and only then.
for key in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates \
           CriticalUpdateInstall ConfigDataInstall; do
  sudo -n defaults write /Library/Preferences/com.apple.SoftwareUpdate "$key" -bool false
done
sudo -n defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

mkdir -p "$HOME/.arthur-runner" "$HOME/Library/LaunchAgents"
