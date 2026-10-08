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

# need_node [min_major]: the macOS helper's contract. Distro streams lag -- Ubuntu 24.04 and
# Debian 12 ship 18, Rocky 9's newest module is 22 -- so a minimum the distro cannot meet
# installs nodejs.org's own build under /usr/local, which as_user's PATH already carries.
need_node() {
  local want="${1:-0}" have arch v
  have=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "$want" -gt 0 ] && [ "$have" -lt "$want" ]; then
    case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
    v=$(curl --retry 3 -fsSL https://nodejs.org/dist/index.json | python3 -c '
import json, sys
print(next(r["version"] for r in json.load(sys.stdin) if r["version"].startswith("v%s." % sys.argv[1])))' "$want") \
      || { echo "WARN: no Node $want release found on nodejs.org" >&2; return 1; }
    # The old npm goes first. A GitHub runner already has Node 20 in /usr/local, and
    # unpacking over it merges two npm trees: the result exits 1 on every install and
    # prints only where its log is. Reproduced in a container with Node 20 under /usr/local.
    sudo_maybe rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack
    curl --retry 3 -fsSL "https://nodejs.org/dist/$v/node-$v-linux-$arch.tar.gz" \
      | sudo_maybe tar -xz -C /usr/local --strip-components=1 \
      || { echo "WARN: Node $v did not unpack" >&2; return 1; }
    hash -r
    return 0
  fi
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

# retry <label> <cmd> [args...]: THREE ATTEMPTS, 15s then 45s apart, judged by the exit.
# CDNs reset and truncate transfers mid-download -- `curl: (18)`, `Connection reset by
# peer` -- and curl's own --retry covers neither. Messages go to stderr, so a caller can
# capture the command's stdout. lib/guest.sh carries a byte-identical copy for the zsh
# scenarios, and test/lint.sh holds the two together.
#
# RUNNING OUT IS A FAILURE, NOT A SKIP. 79 set the rule: skip only on a cause identified as
# nobody's here to fix, because a moved or renamed download is exactly what a scenario
# exists to report. So a caller WARNs and carries on, letting the assertion name what is
# missing, or exits 1 when nothing after it can run. Never exit 3.
retry() {
  local label="$1" wait; shift
  for wait in 15 45 done; do
    "$@" && return 0
    [ "$wait" = done ] && break
    echo "      retrying $label in ${wait}s" >&2; sleep "$wait"
  done
  echo "WARN: $label failed after three attempts" >&2
  return 1
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

# VS Code from Microsoft's own deb or rpm, by family: the same URL shape publishes both, and
# the extension directory osquery reads is the same install either way. Exits 3 (SKIP) where
# Microsoft publishes no package; a download that fails three times exits 1, per retry.
need_vscode() {
  local build ext pkg
  case "$(pm)-$(uname -m)" in
    apt-x86_64)  build=linux-deb-x64   ext=deb ;;
    apt-aarch64) build=linux-deb-arm64 ext=deb ;;
    dnf-x86_64)  build=linux-rpm-x64   ext=rpm ;;
    dnf-aarch64) build=linux-rpm-arm64 ext=rpm ;;
    *) echo "SKIP: no VS Code package for $(pm) on $(uname -m)"; exit 3 ;;
  esac
  # mktemp, keeping the suffix the package manager keys on -- see 75-linux-browser.
  pkg=$(mktemp "/tmp/code.XXXXXX.$ext")
  if [ "$(pm)" = apt ]; then
    # libasound2t64 is Ubuntu 24.04's name for the ALSA library and Debian 12 still says
    # libasound2. apt resolves the deb's dependencies itself when the install goes through
    # apt-get, so this only matters on the dpkg -i fallback.
    need_pkgs libasound2t64 || need_pkgs libasound2 || true
  fi
  retry "the VS Code download" \
    curl --retry 3 -fsSLo "$pkg" "https://update.code.visualstudio.com/latest/$build/stable" \
    || { echo "FAIL: VS Code did not download, so no extension can be installed"; exit 1; }
  if [ "$(pm)" = apt ]; then
    try "installing the VS Code deb" sudo_maybe apt-get -qq install -y "$pkg" \
      || try "dpkg -i for VS Code" sudo_maybe dpkg -i "$pkg" \
      || echo "WARN: VS Code did not install"
  else
    try "installing the VS Code rpm" sudo_maybe dnf -q -y install "$pkg" \
      || echo "WARN: VS Code did not install"
  fi
  rm -f "$pkg"
  code --version --no-sandbox 2>&1 | head -1 || true
}

# install_vscode_ext <id>...: AS THE USER, because extensions live in ~/.vscode/extensions
# and installing as root would leave the /home branch -- the one a fleet has -- unexercised.
# --no-sandbox because there is no display and no user namespace in CI.
#
# Through retry, because the Marketplace fails transiently: a 503 or a truncated VSIX failed
# 78 on all four Linux targets at once, a different extension on each, and the rerun passed.
# Running out of attempts still fails the assertions rather than SKIPping: from in here an
# outage looks like an extension that is gone for good, and a skip would hide the second.
install_vscode_ext() {
  local ext
  for ext in "$@"; do
    retry "installing $ext" \
      try_user "installing $ext" "code --no-sandbox --install-extension $ext --force" || true
  done
}

# install_jb_plugin <dest> <marketplace-id>...: the Marketplace's own zip, unpacked AS THE
# USER into the directory an IDE unpacks it into -- the way 45-claude-extension unpacks the
# Web Store's CRX. jetbrains_plugins is per uid. The zip root IS the plugin directory, and
# that directory name is the identifier, so the vendor ships it rather than the test.
#
# A FAILED DOWNLOAD FAILS THE ASSERTIONS rather than exiting 3, for the reason given above
# install_vscode_ext. Both requests go through retry.
jb_latest_update() {
  curl --retry 3 -fsSL "https://plugins.jetbrains.com/api/plugins/$1/updates?size=1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'
}
install_jb_plugin() {
  local dest="$1" plugin upd; shift
  as_user "mkdir -p '$dest'"
  for plugin in "$@"; do
    upd=$(retry "looking up plugin $plugin" jb_latest_update "$plugin") || continue
    # The download URL answers 301 to /files/<plugin>/<update>/<name>.zip; -L follows it.
    retry "downloading plugin $plugin" try_user "downloading plugin $plugin update $upd" \
      "curl --retry 3 -fsSL -o /tmp/jb-$plugin.zip 'https://plugins.jetbrains.com/plugin/download?updateId=$upd'" \
      || continue
    # python's zipfile rather than unzip: one fewer package on three families.
    try_user "unpacking plugin $plugin" \
      "python3 -c \"import zipfile; zipfile.ZipFile('/tmp/jb-$plugin.zip').extractall('$dest')\"" || true
    as_user "rm -f /tmp/jb-$plugin.zip"
  done
}
