#!/usr/bin/env bash
# Prepare a Mac to host macOS scenario jobs, and start or stop its slots.
#
#   test/runner-host/host-setup.sh configure   check this Mac, install tools, write the slots
#   test/runner-host/host-setup.sh start       load the slots; each boots VMs for jobs
#   test/runner-host/host-setup.sh stop        unload them; a running job is cut off
#   test/runner-host/host-setup.sh status
#
# Run as the logged-in user the slots run as, never as root: Tart needs that user's unlocked
# login keychain, which only a GUI login gives. docs/macos-runners.md is the runbook, and
# says what goes in $RH_CONF (app.env, app.pem, slots).
#
# WHAT IT ASSERTS, IT DOES NOT CHANGE: FileVault and the password a person types after a
# reboot are that person's to set. What it changes, it then reads back.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/runner-host/common.sh
source "$HERE/common.sh"

AGENT=com.arthur-ai.runner-slot
UID_NOW=$(id -u)
[ "$UID_NOW" != 0 ] || die "run as the user the slots run as, not root"

# slot_lines: "<slot> <label>" per slot in $RH_CONF/slots, comments and blanks dropped.
slot_lines() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$RH_CONF/slots"; }

configure() {
  local fail=0 major sw real slot label n=0 seen=" " plist listeners
  [ "$(uname -m)" = arm64 ] || die "not Apple silicon"
  major=$(sw_vers -productVersion | cut -d. -f1)
  # Softnet needs macOS 26, and a host must be at least as new as its newest guest.
  [ "$major" -ge 26 ] || die "macOS $major; a runner host needs 26 or newer"

  # THE LAPTOPS SIT IN A SHARED BUILDING. FileVault keeps a powered-off or stolen one
  # unreadable, the App key on it included. It also rules out auto-login, so after any
  # reboot a person logs in before the slots return; that is the price, chosen on purpose.
  if ! fdesetup status | grep 'FileVault is On' >/dev/null; then
    log "FAIL: FileVault is off. System Settings > Privacy & Security > FileVault."; fail=1
  fi
  # A positive match, so output this cannot read fails rather than passes. On macOS 26 a
  # lock prints "screenLock delay is <n> seconds" (or "immediate"), and no lock "is off".
  if ! sysadminctl -screenLock status 2>&1 | grep 'screenLock delay is' >/dev/null; then
    log "FAIL: the screen does not lock. System Settings > Lock Screen: require a password."; fail=1
  fi

  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on >/dev/null
  /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep -i enabled >/dev/null \
    || { log "FAIL: the firewall did not turn on"; fail=1; }

  # Never sleep; the display may. Read back, because pmset ignores a key a model lacks.
  sudo pmset -a sleep 0 disksleep 0 powernap 0 displaysleep 10
  [ "$(pmset -g | awk '$1 == "sleep" {print $2}')" = 0 ] || { log "FAIL: sleep is not 0"; fail=1; }
  # The login keychain never locks on its own: Tart cannot start a VM while it is locked.
  # A locked SCREEN leaves it unlocked, which is what lets the slots run behind one.
  security set-keychain-settings "$HOME/Library/Keychains/login.keychain-db"

  [ -x /opt/homebrew/bin/brew ] || die "install Homebrew first: https://brew.sh"
  # openai/tools, where Tart and Softnet moved. The old cirruslabs/cli tap stopped at Tart
  # 2.32.1, and Homebrew 7 refuses to load its formulas.
  /opt/homebrew/bin/brew install openai/tools/tart openai/tools/softnet sshpass
  command -v jq >/dev/null || /opt/homebrew/bin/brew install jq
  # SOFTNET RUNS SETUID ROOT, to set up the bridge, then drops to the caller. A Homebrew
  # upgrade replaces the binary and the bit with it, so run configure again after one.
  sw=$(PATH="/opt/homebrew/bin:$PATH" command -v softnet)
  real=$(readlink -f "$sw")
  sudo chown root:wheel "$real"
  sudo chmod u+s "$real"
  if [ ! -u "$real" ] || [ "$(stat -f %Su "$real")" != root ]; then
    log "FAIL: softnet is not setuid root"; fail=1
  fi

  mkdir -p "$RH_CONF" "$RH_LOGS" "$RH_STATE" "$HOME/Library/LaunchAgents"
  chmod 700 "$RH_CONF" "$RH_STATE"
  [ -f "$RH_CONF/app.pem" ] || die "no $RH_CONF/app.pem, the GitHub App's private key"
  chmod 600 "$RH_CONF/app.pem"
  openssl rsa -in "$RH_CONF/app.pem" -check -noout >/dev/null 2>&1 \
    || { log "FAIL: $RH_CONF/app.pem is not an RSA private key"; fail=1; }
  [ -f "$RH_CONF/app.env" ] || die "no $RH_CONF/app.env (APP_ID, INSTALLATION_ID, RUNNER_GROUP_ID)"
  chmod 600 "$RH_CONF/app.env"
  # shellcheck source=/dev/null
  ( source "$RH_CONF/app.env"; [ -n "${APP_ID:-}" ] && [[ "${INSTALLATION_ID:-}" =~ ^[0-9]+$ ]] \
      && [[ "${RUNNER_GROUP_ID:-1}" =~ ^[0-9]+$ ]] ) \
    || { log "FAIL: app.env needs APP_ID, a numeric INSTALLATION_ID and RUNNER_GROUP_ID"; fail=1; }

  [ -f "$RH_CONF/slots" ] || die "no $RH_CONF/slots: one '<slot> <label>' line per VM, e.g. 'a macos-15'"
  # Remove every slot agent first, so a slot dropped from the file stops existing.
  stop
  rm -f "$HOME/Library/LaunchAgents/$AGENT".*.plist
  while read -r slot label; do
    n=$((n + 1))
    [[ "$slot" =~ ^[a-z0-9-]+$ ]] || die "slot name '$slot' must match [a-z0-9-]+"
    case "$seen" in *" $slot "*) die "slot '$slot' is listed twice" ;; esac
    seen="$seen$slot "
    image_for_label "$label" >/dev/null || die "slot $slot: label '$label' must be macos-<major>"
    tart list --format json | jq -e --arg i "$(image_for_label "$label")" '.[] | select(.Name == $i)' \
      >/dev/null || log "WARN: no image $(image_for_label "$label") yet; bake.sh ${label#macos-} makes it"
    plist="$HOME/Library/LaunchAgents/$AGENT.$slot.plist"
    # LimitLoadToSessionType Aqua: only a GUI login loads these, which is when the keychain
    # Tart needs is unlocked. ExitTimeOut outlasts slot.sh's own clean-up on a stop.
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT.$slot</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HERE/slot.sh</string><string>$slot</string><string>$label</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>ExitTimeOut</key><integer>90</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$RH_LOGS/$slot.log</string>
  <key>StandardErrorPath</key><string>$RH_LOGS/$slot.log</string>
</dict>
</plist>
EOF
    plutil -lint "$plist" >/dev/null || die "wrote an invalid $plist"
  done < <(slot_lines)
  # Apple's licence and Virtualization.framework both stop at two macOS guests per Mac.
  if [ "$n" -lt 1 ] || [ "$n" -gt 2 ]; then
    die "$RH_CONF/slots lists $n slots; a Mac runs one or two"
  fi

  # ANY SERVICE LISTENING ON EVERY INTERFACE IS REACHABLE FROM EVERY VM. Softnet blocks a
  # guest's private-range traffic but lets it reach the bridge's gateway, which is this Mac.
  # On a shared Wi-Fi the other tenants are a second audience. Turn these off, Remote Login
  # included, or know why each one stays.
  listeners=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
              | awk 'NR > 1 && ($9 ~ /^\*:/ || $9 ~ /^0\.0\.0\.0:/ || $9 ~ /^\[::\]:/) {print $1, $9}' \
              | sort -u)
  if [ -n "$listeners" ]; then
    log "WARN: listening on every interface, so reachable from the VMs:"
    printf '%s\n' "$listeners" | sed 's/^/      /'
  fi

  [ "$fail" = 0 ] || die "fix the FAIL lines above and run configure again"
  log "configured $n slot(s). Next: bake.sh if an image is missing, then host-setup.sh start."
}

# Every slot is tried, and any that did not load fails the command. An `a && b` here
# failed the command only when the slot that did not load was the last one.
start() {
  local plist label rc=0
  for plist in "$HOME/Library/LaunchAgents/$AGENT".*.plist; do
    [ -f "$plist" ] || die "no slots are configured; run configure first"
    label=$(basename "$plist" .plist)
    if launchctl print "gui/$UID_NOW/$label" >/dev/null 2>&1; then
      log "$label is already running"
    elif launchctl bootstrap "gui/$UID_NOW" "$plist"; then
      log "started $label"
    else
      log "FAIL: $label did not start; is this user logged in at the screen, not over SSH?"
      rc=1
    fi
  done
  return "$rc"
}

stop() {
  local plist label
  for plist in "$HOME/Library/LaunchAgents/$AGENT".*.plist; do
    [ -f "$plist" ] || continue
    label=$(basename "$plist" .plist)
    launchctl bootout "gui/$UID_NOW/$label" 2>/dev/null && log "stopped $label" || true
  done
}

status() {
  local plist label
  for plist in "$HOME/Library/LaunchAgents/$AGENT".*.plist; do
    [ -f "$plist" ] || { echo "no slots configured"; return 0; }
    label=$(basename "$plist" .plist)
    if launchctl print "gui/$UID_NOW/$label" >/dev/null 2>&1; then
      echo "$label: loaded"
    else
      echo "$label: not loaded"
    fi
    tail -3 "$RH_LOGS/${label##*.}.log" 2>/dev/null | sed 's/^/    /'
  done
  echo "VMs:"
  tart list --format json | jq -r '.[] | select(.Source == "local") | "    \(.Name)  \(.State)"'
  echo "runner cache: $(cat "$RH_STATE/runner/VERSION" 2>/dev/null || echo empty)"
}

case "${1:-}" in
  configure) configure ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "usage: host-setup.sh configure|start|stop|status" >&2; exit 2 ;;
esac
