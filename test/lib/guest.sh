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
    "$(curl --retry 3 -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

# need_node [min_major]
#
# WITH NO ARGUMENT THIS IS PRESENCE-ONLY, which is what it has always been and what four
# of its five callers want. That default is deliberate: a scenario that just needs `npm`
# on PATH should not start upgrading the runner's toolchain underneath itself.
#
# The presence-only test is also what broke 55-openclaw-npm. GitHub's macOS images ship a
# Homebrew node@22, so `command -v npm` succeeded and nothing ever asked which node that
# was. openclaw 2026.9.3, published 2026-09-08 13:06Z, raised its engines floor from
# `>=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0` to `>=24.16.0 <25 || >=26.1.0`; the
# runner's 22.23.2 stopped qualifying and the package's own preinstall refused to install.
# The scheduled run three hours earlier had fetched 2026.9.2 and passed, so the suite went
# red with no commit behind it. A version floor is the part that was missing.
#
# UPGRADING MEANS THE UNVERSIONED `node`, NOT `node@24`. Both satisfy openclaw, but node@24
# is keg-only, so its globals land under /opt/homebrew/opt/node@24/lib/node_modules instead
# of /opt/homebrew/lib/node_modules -- and whether osquery's npm_packages enumerates that
# prefix is unverified. Guessing wrong there returns zero npm rows, which is a machine with
# no globals wearing the same face as a machine we installed one on. The unversioned
# formula links into the prefix the failing install already named in its own error, so the
# detection surface stays the one the green runs measured.
#
# A MAJOR FLOOR CANNOT EXPRESS openclaw's range and this does not pretend to: `<25`
# excludes the 25 line outright, and the floor says nothing about patch levels either.
# Homebrew's node is 26.8.2 as of 2026-09-10 and satisfies the `>=26.1.0` arm. If it ever
# lands on a major or patch openclaw refuses, openclaw's preinstall names the version and
# the reason and setup.sh exits 1 -- loud, which is the property being defended here, not
# a guarantee that the floor alone is sufficient.
need_node() {
  local min=${1:-0} have=''
  if command -v npm >/dev/null 2>&1; then
    # `node -v | sed` and not `node -v` alone: with no node on PATH the pipeline is still
    # sed's exit status, so this yields an empty string rather than tripping `set -e` in
    # the caller before the check below can say what was wrong.
    have=$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')
    if [ "$min" -eq 0 ]; then return 0; fi
    if [ -n "$have" ] && [ "$have" -ge "$min" ]; then return 0; fi
    echo "--- node ${have:-unknown} is below the $min this scenario needs; upgrading"
  fi
  need_brew || return 1
  # Tolerant, because the VERIFICATION BELOW IS THE GATE, not these three. `brew install`
  # on an already-current formula and `brew link` on an already-linked one both exit
  # non-zero for reasons that are not failures, and a `set -e` caller would take the exit
  # for one. Whether node actually moved is decided by asking node.
  brew install node || brew upgrade node || true
  # --overwrite because node@22 arrives LINKED on the runner despite being keg-only: it
  # owns /opt/homebrew/bin/node, and the new node has to take that symlink from it.
  brew link --overwrite node >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  have=$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')
  if [ -z "$have" ] || [ "$have" -lt "$min" ]; then
    echo "FAIL: need node major >= $min, have ${have:-none} after installing Homebrew node" >&2
    return 1
  fi
  node -v | sed 's/^/  node /'
}
