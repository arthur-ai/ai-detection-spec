#!/usr/bin/env bash
# One VM slot on a runner host. Forever: register a just-in-time runner for one job, boot a
# fresh clone of the label's image to run it, delete the clone. host-setup.sh writes the
# LaunchAgent that runs one of these per slot; docs/macos-runners.md is the runbook.
#
#   slot.sh <slot> <label>        e.g. slot.sh a macos-15
#
# A NEW VM FOR EVERY JOB. Scenarios install real software and 00-baseline asserts a clean
# machine, so a second job on the same disk would assert on the first one's installs.
#
# THE HOST WATCHES GITHUB, NOT THE GUEST. Whether the runner came online, took a job and
# finished is read from the runners API. The guest runs whatever a pull request wrote, so
# nothing it could write is read here: both of its shares are mounted read-only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/runner-host/common.sh
source "$HERE/common.sh"

slot="${1:?usage: slot.sh <slot> <label>}"
label="${2:?usage: slot.sh <slot> <label>}"
[[ "$slot" =~ ^[a-z0-9-]+$ ]] || die "slot '$slot' must match [a-z0-9-]+"
image=$(image_for_label "$label") || die "label '$label' names no image; it must be macos-<major>"

# Generous, and not yet measured on these laptops: boot, log in, unpack the runner, connect.
BOOT_BOUND=300
# Above scenarios.yml's job timeout-minutes, so GitHub's own bound fires first and this one
# only catches a guest that stopped answering.
JOB_BOUND=$((90 * 60))
# An idle runner is recycled, so the disk it boots and the runner it runs stay current.
IDLE_BOUND=$((12 * 3600))
POLL=30

[ -f "$RH_CONF/app.env" ] || die "no $RH_CONF/app.env; docs/macos-runners.md says what goes in it"
# shellcheck source=/dev/null
source "$RH_CONF/app.env"
: "${APP_ID:?app.env sets no APP_ID}" "${INSTALLATION_ID:?app.env sets no INSTALLATION_ID}"
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
[[ "$RUNNER_GROUP_ID$INSTALLATION_ID" =~ ^[0-9]+$ ]] || die "app.env: RUNNER_GROUP_ID and INSTALLATION_ID are numbers"

work="$RH_STATE/slots/$slot"
mkdir -p "$work" "$RH_LOGS"
RH_TMP="$work/tmp"
rm -rf "$RH_TMP"
mkdir -m 700 "$RH_TMP"
RH_AUTH="$RH_TMP/auth"
: > "$RH_AUTH"
TOKEN_AT=0
VM="" VM_PID=""

# sleep that a signal interrupts, so `host-setup.sh stop` is not kept waiting by a backoff.
nap() { sleep "$1" & wait $! || true; }

fresh_token() { [ $(( $(date +%s) - TOKEN_AT )) -lt 3000 ] || app_token; }

# Delete the VMs this slot left behind when it, or the host, stopped mid-job.
reap() {
  local v
  for v in $(tart list --format json | jq -r --arg p "rh-$slot-" \
               '.[] | select(.Name | startswith($p)) | .Name'); do
    tart stop "$v" >/dev/null 2>&1 || true
    tart delete "$v" && log "deleted leftover VM $v"
  done
}

# Deregister this slot's runner unless it is gone already. An ephemeral runner deregisters
# itself after its job; one that never got a job, or whose VM was stopped, does not.
drop_runner() {
  local id code
  id=$(cat "$work/runner-id" 2>/dev/null || true)
  [ -n "$id" ] || return 0
  fresh_token || return 1
  code=$(gh_call DELETE "/orgs/$ORG/actions/runners/$id" /dev/null)
  case "$code" in
    204|404) rm -f "$work/runner-id" ;;
    *) log "WARN: could not deregister runner $id ($code); the next pass tries again"; return 1 ;;
  esac
}

stop_vm() {
  [ -n "$VM" ] || return 0
  tart stop "$VM" --timeout 30 >/dev/null 2>&1 || true
  if [ -n "$VM_PID" ]; then
    kill "$VM_PID" 2>/dev/null || true
    wait "$VM_PID" 2>/dev/null || true
  fi
  tart delete "$VM" >/dev/null 2>&1 || log "WARN: could not delete $VM; the next pass reaps it"
  VM="" VM_PID=""
}

on_exit() { stop_vm; drop_runner || true; rm -rf "$RH_TMP"; }
trap on_exit EXIT
trap 'log "stopping"; exit 0' TERM INT

# THE GROUP DECIDES WHO MAY RUN HERE, so it is read, not assumed. These are org runners, and
# a group open to every repository would let any public repository in the org send a job to
# these laptops. Nothing registers until the group serves this repository alone, and allows
# public repositories, without which this one cannot use it.
check_group() {
  local g repos
  g=$(gh_json GET "/orgs/$ORG/actions/runner-groups/$RUNNER_GROUP_ID") || return 1
  if [ "$(printf '%s' "$g" | jq -r .visibility)" != selected ]; then
    log "ERROR: runner group $RUNNER_GROUP_ID is visible to '$(printf '%s' "$g" | jq -r .visibility)'" \
        "repositories; restrict it to $ORG/$REPO"
    return 1
  fi
  if [ "$(printf '%s' "$g" | jq -r .allows_public_repositories)" != true ]; then
    log "ERROR: runner group $RUNNER_GROUP_ID does not allow public repositories, and $REPO is one"
    return 1
  fi
  repos=$(gh_json GET "/orgs/$ORG/actions/runner-groups/$RUNNER_GROUP_ID/repositories?per_page=100" \
          | jq -r '[.repositories[].full_name] | sort | join(",")') || return 1
  if [ "$repos" != "$ORG/$REPO" ]; then
    log "ERROR: runner group $RUNNER_GROUP_ID serves [$repos]; it must serve $ORG/$REPO alone"
    return 1
  fi
}

# runner_state: "online true", "online false", "offline false", "gone" or "unknown".
runner_state() {
  local code
  code=$(gh_call GET "/orgs/$ORG/actions/runners/$1" "$RH_TMP/runner.json")
  case "$code" in
    200) jq -r '"\(.status) \(.busy)"' "$RH_TMP/runner.json" ;;
    404) echo gone ;;
    *) echo unknown ;;   # GitHub or the Wi-Fi blinked; judge on the next poll
  esac
}

# one_job: register, boot, watch, clean up. 0 when the slot did its work, whether it ran a
# job or sat idle until recycled; 1 when something is broken and the loop should back off.
one_job() {
  local jit id share vm t0 now st online=0 busy_at=0 gone_at=0 why=""
  reap
  drop_runner || return 1
  curl -fsS -m 10 -o /dev/null "$API/zen" || { log "GitHub does not answer; is the Wi-Fi up?"; return 1; }
  app_token || return 1
  check_group || return 1
  refresh_runner_cache || true
  [ -s "$RH_STATE/runner/actions-runner.tar.gz" ] || { log "ERROR: no runner in the cache"; return 1; }

  # Every label explicitly: a just-in-time runner carries only the labels it is given.
  jit=$(gh_json POST "/orgs/$ORG/actions/runners/generate-jitconfig" "$(jq -cn \
          --arg n "$(scutil --get LocalHostName 2>/dev/null || hostname -s)-$slot-$(date +%s)" \
          --argjson g "$RUNNER_GROUP_ID" --arg l "$label" \
          '{name: $n, runner_group_id: $g, labels: ["self-hosted", "macOS", "ARM64", $l]}')") \
    || return 1
  id=$(printf '%s' "$jit" | jq -r .runner.id)
  [[ "$id" =~ ^[0-9]+$ ]] || { log "ERROR: the JIT answer named no runner"; return 1; }
  printf '%s\n' "$id" > "$work/runner-id"

  # Readable by the guest: a share keeps its host modes, and the guest's user need not be
  # this one. The registration is single-use and the job could read it from the runner
  # anyway; nothing else is in the share.
  share="$work/jit"
  rm -rf "$share"
  mkdir -m 755 "$share"
  printf '%s' "$jit" | jq -r .encoded_jit_config > "$share/config"
  chmod 644 "$share/config"

  vm="rh-$slot-$(date +%s)"
  tart clone "$image" "$vm" || { log "ERROR: could not clone $image; has bake.sh run?"; return 1; }
  VM=$vm
  tart set "$vm" --cpu "$RH_CPUS" --memory "$RH_MEM" || { log "ERROR: could not size $vm"; return 1; }
  tart run --no-graphics --net-softnet \
    --dir="runner:$RH_STATE/runner:ro" --dir="jit:$share:ro" "$vm" \
    >>"$RH_LOGS/$slot.tart.log" 2>&1 &
  VM_PID=$!
  t0=$(date +%s)
  log "booted $vm for runner $id ($label)"

  while kill -0 "$VM_PID" 2>/dev/null; do
    nap "$POLL"
    now=$(date +%s)
    fresh_token || true
    st=$(runner_state "$id")
    case "$st" in
      "online false") online=1 ;;
      "online true") online=1; [ "$busy_at" != 0 ] || { busy_at=$now; log "$vm took a job"; } ;;
      gone) [ "$gone_at" != 0 ] || gone_at=$now ;;
    esac
    # Each bound names what broke. The ERROR ones back the loop off.
    if [ "$gone_at" != 0 ] && [ $((now - gone_at)) -gt 180 ]; then
      why="its runner is gone and it did not power off"; break
    elif [ "$busy_at" != 0 ] && [ $((now - busy_at)) -gt "$JOB_BOUND" ]; then
      why="ERROR: its job ran past ${JOB_BOUND}s"; break
    elif [ "$online" = 0 ] && [ "$gone_at" = 0 ] && [ $((now - t0)) -gt "$BOOT_BOUND" ]; then
      why="ERROR: its runner never came online in ${BOOT_BOUND}s; read $RH_LOGS/$slot.tart.log"; break
    elif [ "$busy_at" = 0 ] && [ "$gone_at" = 0 ] && [ $((now - t0)) -gt "$IDLE_BOUND" ]; then
      why="idle for ${IDLE_BOUND}s; recycling"; break
    fi
  done
  [ -z "$why" ] || log "stopping $vm: $why"
  # A job shorter than one poll can start and finish between two, and the runner is gone
  # before the loop saw it online. Gone means it ran.
  [ "$online" = 1 ] || [ "$(runner_state "$id")" != gone ] || gone_at=$(date +%s)
  stop_vm
  drop_runner || true
  rm -rf "$share"
  case "$why" in ERROR:*) return 1 ;; esac
  if [ "$online" = 0 ] && [ "$gone_at" = 0 ]; then
    log "ERROR: $vm powered off before its runner came online"
    return 1
  fi
  log "$vm done"
}

log "slot $slot serving $label from $image"
fails=0
while :; do
  if one_job; then
    fails=0
  else
    fails=$((fails + 1))
    wait_s=$((30 * fails))
    [ "$wait_s" -le 900 ] || wait_s=900
    log "pass failed, $fails in a row; next in ${wait_s}s"
    nap "$wait_s"
  fi
done
