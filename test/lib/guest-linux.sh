#!/bin/bash
# Sourced by the Linux scenario setup.sh scripts. The sibling of lib/guest.sh, and a
# sibling rather than a widening of it: that file is zsh and Homebrew end to end, and
# nothing in it has a Linux branch worth writing.
#
# On a GitHub-hosted ubuntu-24.04 runner most of this is preinstalled and the functions
# are no-ops, which is why the Linux scenarios run directly on the runner with no VM at
# all. In a container -- the local development path, test/run-linux.sh -- they install
# what is missing.
#
# BASH, NOT ZSH. A managed Mac has bash 3.2 and that constrains bin/; these scripts only
# ever run on Linux, where bash is 5.x. test/lint.sh dispatches `bash -n` or `zsh -n` on
# the shebang rather than assuming one shell for every scenario.

# One package manager, resolved once. Every distro function below goes through this.
pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  else echo unknown; fi
}

need_pkgs() {
  case "$(pm)" in
    apt) export DEBIAN_FRONTEND=noninteractive
         sudo_maybe apt-get -qq update >/dev/null 2>&1
         sudo_maybe apt-get -qq install -y "$@" >/dev/null 2>&1 ;;
    dnf) sudo_maybe dnf -q -y install "$@" >/dev/null 2>&1 ;;
    *)   echo "WARN: no known package manager for $*" >&2; return 1 ;;
  esac
}

# A container runs as root with no sudo installed; a CI runner is a non-root user with
# passwordless sudo. Both are normal, so neither is assumed.
sudo_maybe() {
  if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi
}

need_curl() { command -v curl >/dev/null 2>&1 || need_pkgs curl ca-certificates; }

need_node() {
  command -v npm >/dev/null 2>&1 && return 0
  need_pkgs nodejs npm
  command -v npm >/dev/null 2>&1
}

need_uv() {
  command -v uv >/dev/null 2>&1 && return 0
  need_curl
  # The vendor's installer, which is how uv is actually installed on Linux. It writes to
  # ~/.local/bin, which is also one of the paths queries/filesystem-linux.sql globs -- so
  # uv itself shows up as an unmatched `file` row, correctly, being no kind of agent.
  curl -fsSL https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1
}

# A NON-ROOT USER WITH A REAL HOME, because half of what these queries look for is
# per-user. Running everything as root would exercise only the /root branches and leave
# the /home/<user>/ ones -- the ones that matter on a real fleet -- untested, while the
# row counts still looked right.
SCENARIO_USER="${SCENARIO_USER:-dana}"
need_user() {
  id "$SCENARIO_USER" >/dev/null 2>&1 && return 0
  sudo_maybe useradd -m -s /bin/bash "$SCENARIO_USER"
}

# Run a command as that user, with a login shell so ~/.local/bin is on PATH.
as_user() { sudo_maybe su - "$SCENARIO_USER" -c "$*"; }

# EVERY FAILURE CARRIES ITS REASON. `<cmd> || echo "WARN: it failed"` was the pattern here,
# and it cost a full CI round trip to learn nothing: two scenarios failed on a runner with
# "WARN: install failed" and the actual error had been redirected to /dev/null, so the log
# said only that something had gone wrong. That is the same defect as an empty result that
# looks like a clean machine, applied to the test harness.
#
# `try` keeps the quiet output of the passing case -- a scenario that printed every apt line
# would bury its own assertions -- and prints EVERYTHING on failure, with the exit code.
# A failure is still not fatal: the scenario carries on so the assertion names the missing
# agent rather than the setup aborting and naming nothing.
try() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    echo "WARN: $label failed (exit $rc). Its output follows, because a warning with no"
    echo "      reason is indistinguishable from one nobody can act on:"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
  return "$rc"
}

# The same, for something that has to run as the scenario user.
try_user() {
  local label="$1"; shift
  try "$label" sudo_maybe su - "$SCENARIO_USER" -c "$*"
}

# What a scenario should print when it could not do its job, so the log says which of the
# environment or the software was at fault.
diagnose() {
  echo "--- diagnostics: id=$(id -un) user=$SCENARIO_USER home=$(getent passwd "$SCENARIO_USER" | cut -d: -f6)"
  echo "--- PATH=$PATH"
  for c in "$@"; do
    printf -- "--- %s: %s\n" "$c" "$(command -v "$c" || echo 'not on PATH')"
  done
}
