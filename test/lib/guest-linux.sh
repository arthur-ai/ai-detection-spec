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
  # RHEL 9 and Rocky 9 ship Node as a module whose default stream is 16, which the
  # current agent CLIs refuse to install under. Enable the newest stream first. Fedora
  # and the apt family have no modules, and `dnf module list` simply fails there.
  if [ "$(pm)" = dnf ] && dnf module list nodejs >/dev/null 2>&1; then
    sudo_maybe dnf -q -y module enable nodejs:22 >/dev/null 2>&1 || true
  fi
  need_pkgs nodejs npm
  command -v npm >/dev/null 2>&1
}

# A NON-ROOT USER WITH A REAL HOME, because half of what these queries look for is
# per-user. Running everything as root would exercise only the /root branches and leave
# the /home/<user>/ ones -- the ones that matter on a real fleet -- untested, while the
# row counts still looked right.
SCENARIO_USER="${SCENARIO_USER:-dana}"
need_user() {
  # as_user below needs util-linux, which the bare fedora:41 image leaves out. The Fedora
  # scenarios before 80 had it only because something they installed pulled it in; one that
  # installs nothing exits 127 at the first as_user. A no-op where it is already present.
  if [ "$(pm)" = dnf ]; then
    need_pkgs util-linux || echo "WARN: util-linux did not install, so as_user cannot run" >&2
  fi
  id "$SCENARIO_USER" >/dev/null 2>&1 && return 0
  sudo_maybe useradd -m -s /bin/bash "$SCENARIO_USER"
}

# Run a command as that user, in a SCRUBBED environment.
#
# THIS TOOK THREE ATTEMPTS AND EACH FAILURE WAS INSTRUCTIVE, so the reasoning is here
# rather than in the history.
#
#   1. `su - "$user" -c ...` -- the obvious form. On a GitHub runner the command ran as
#      the right user with HOME still pointing at the RUNNER's home, and VS Code said so:
#      `EACCES: permission denied, mkdir '/home/runner/.config/Code/User'`.
#   2. Exporting HOME explicitly. HOME was then correct and the SAME error appeared, which
#      is the useful part: that path is not built from HOME at all. It is
#      $XDG_CONFIG_HOME, which a runner exports pointing at its own home and which sudo's
#      env_keep and a non-login `su` both carry straight through. Chrome's failure was the
#      same leak wearing a stranger disguise -- `chrome_crashpad_handler: --database is
#      required`, exit 133 -- because its crash directory resolves the same way.
#   3. `env -i`, below. Nothing inherited, everything named.
#
# Reproducing it needed the leak reproduced too: a container that does not export XDG_*
# passes every version of this, which is why attempts 1 and 2 looked correct locally.
#
# THE COMMAND ARRIVES ON STDIN, as `bash -s`, so an arbitrary command needs no quoting at
# this level -- the alternative was nesting three layers of quotes inside `env -i ... bash
# -lc '...'` and getting it wrong for whichever scenario used an apostrophe first. Nothing
# these scenarios run reads stdin itself.
as_user() {
  local home
  home="$(getent passwd "$SCENARIO_USER" | cut -d: -f6)"
  [ -n "$home" ] || { echo "as_user: no home for $SCENARIO_USER" >&2; return 1; }
  # cd TO THE USER'S HOME FIRST, which is the other thing dropping `-` cost. A login
  # shell does it; `su` without `-` leaves the caller's cwd in place, which on CI is the
  # repo checkout under /home/runner/work -- a directory the scenario user cannot read.
  #
  # aider is what found this: `aider --just-check-update` died with GitPython's
  # NoSuchPathError, because it looks for a git repository in the CURRENT directory and
  # could not stat it. It never got as far as writing ~/.aider, so the run proved one
  # fewer identifier and the coverage shrink guard refused to record it -- which is the
  # guard working, on a cause three steps upstream of itself.
  { printf 'cd %s || exit 1\n' "$home"; printf '%s\n' "$*"; } \
    | sudo_maybe su "$SCENARIO_USER" -s /bin/bash -c \
    "env -i HOME='$home' USER='$SCENARIO_USER' LOGNAME='$SCENARIO_USER' \
       SHELL=/bin/bash TERM=dumb \
       PATH='$home/.local/bin:$home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
       bash -s"
}

as_user_ls() { sudo_maybe ls -1 "$@" 2>&1; }

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
#
# IT DELEGATES TO as_user AND MUST NOT GROW ITS OWN `su`, which is exactly what it did and
# what cost three CI rounds. as_user was rewritten to scrub the environment with `env -i`
# and this function kept its own `su - "$user" -c`, so every scenario that used try_user --
# which is all of the ones that failed -- still leaked XDG_CONFIG_HOME and still could not
# write. 72 passed the whole time because uv tolerates the leak and VS Code does not, which
# made it look like a per-tool problem rather than one wrong copy of one line.
#
# Two functions doing the same job with one of them wrong is the drift this repo built a
# route registry to end. test/lint.sh now asserts that `su` appears in exactly one place
# in this file.
try_user() {
  local label="$1"; shift
  try "$label" as_user "$@"
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
