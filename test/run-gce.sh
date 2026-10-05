#!/usr/bin/env bash
# Run the Linux scenarios on real Compute Engine VMs: one image family per run, and ONE
# FRESH VM PER SCENARIO.
#
#   test/run-gce.sh                                  every family, every linux scenario
#   test/run-gce.sh --family rocky-9                 one family
#   test/run-gce.sh --family debian-12 71-linux-cli-agents
#   KEEP_VM=1 test/run-gce.sh --family debian-12 70-linux-baseline   leave that VM up
#
# WHY A VM WHEN CONTAINERS AND A HOSTED RUNNER ALREADY PASS. Three things neither has:
#
#   * systemd as PID 1 on Debian and Rocky. The hosted runner has it on Ubuntu only and a
#     container never does, so 76-linux-systemd and the systemd marker's `ok` branch had
#     been proved on exactly one family.
#   * OS Login. Accounts come from an NSS module rather than /etc/passwd and a home
#     directory appears on first login -- the case queries/browser.sql's uid source exists
#     for, and one no container can stage. The guest script measures it directly: the old
#     `users` join against the shipped artifact, on a profile owned by the login account.
#   * a shared-core shape. e2-small is what a fleet is full of and what CI has none of,
#     so the wall-clock figures in docs/deployment.md come from here, dated.
#
# ONE VM PER SCENARIO, because the first version of this ran them all on one and every
# `forbid` after 71-linux-cli-agents failed: that scenario installs claude-code and
# codex-cli, and 72 through 78 assert those are absent. The order cannot be fixed either,
# since 71 forbids cursor and 73 installs it. A scenario's contract is a throwaway host,
# which is what CI gives it, and what this now gives it too. The facts and timing run on
# the first scenario's VM only, before it installs anything.
#
# WHAT IT NEEDS: gcloud, authenticated, against a project where you may create instances
# and log in through OS Login as an admin (roles/compute.osAdminLogin: the scenarios need
# sudo). Nothing GCP-specific lands in the tree. This is a test harness, the way test/run.sh
# is a Tart harness; the deployable belongs to whoever wraps the artifacts.
#
#   GCE_PROJECT, GCE_ZONE     default: the active gcloud config, and us-central1-a
#   GCE_MACHINE               default: e2-small
#   GCE_CREATE_FLAGS          extra flags for `instances create`. A project whose org
#                             policy forbids external IPs needs
#                             `--no-address --network <vpc> --subnet <subnet with Cloud NAT>`
#   GCE_SSH_FLAGS             extra flags for ssh and scp, e.g. --tunnel-through-iap
#
# Everything the guest produces comes back to test/artifacts/gce/<family>/<scenario>/: the
# payload, status.txt, the facts file. Observations are recorded INTO THE TREE FROM THE
# HOST, with tools/agent_status.py --record against the fetched payload, the way the CI
# collect job records from uploaded artifacts -- so two families running at once cannot
# overwrite each other's records. A VM run is real-install evidence of the same grade as
# a CI run; it carries no run id because it is nobody's CI.
#
# BASH 3.2, because this runs on the Mac that drives it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ART="$HERE/artifacts/gce"; mkdir -p "$ART"

: "${OSQUERY_VERSION:=5.23.1}"
: "${GCE_ZONE:=us-central1-a}"
: "${GCE_MACHINE:=e2-small}"
: "${KEEP_VM:=0}"
PROJECT_FLAG=()
[ -z "${GCE_PROJECT:-}" ] || PROJECT_FLAG+=(--project "$GCE_PROJECT")

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

families=()
while [ $# -gt 0 ]; do
  case "$1" in
    --family) [ $# -ge 2 ] || usage; families+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    -*) echo "run-gce: unknown flag $1" >&2; usage ;;
    *) break ;;
  esac
done
scenarios=("$@")
[ ${#families[@]} -gt 0 ] || families=(debian-12 ubuntu-2404 rocky-9)
if [ ${#scenarios[@]} -eq 0 ]; then
  for d in "$HERE"/scenarios/*/; do
    n="$(basename "$d")"
    [ -f "$d/expected.json" ] || continue
    [ "$(python3 -c "import json;print(json.load(open('$d/expected.json')).get('platform'))")" = linux ] \
      || continue
    scenarios+=("$n")
  done
fi

# The public image family for each name this script accepts: image project, then family.
# The three families a Compute Engine fleet boots, all x86_64 -- which is also what keeps
# 75-linux-browser from skipping, since Google ships no arm64 Linux Chrome.
image_of() {
  case "$1" in
    debian-12)   echo "debian-cloud debian-12" ;;
    ubuntu-2404) echo "ubuntu-os-cloud ubuntu-2404-lts-amd64" ;;
    rocky-9)     echo "rocky-linux-cloud rocky-linux-9" ;;
    *) return 1 ;;
  esac
}

command -v gcloud >/dev/null 2>&1 || { echo "run-gce: gcloud is required" >&2; exit 1; }
gcloud auth print-access-token >/dev/null 2>&1 \
  || { echo "run-gce: gcloud is not authenticated here. Run: gcloud auth login" >&2; exit 1; }
for f in "${families[@]}"; do
  image_of "$f" >/dev/null || { echo "run-gce: unknown family $f (debian-12, ubuntu-2404, rocky-9)" >&2; exit 1; }
done

# shellcheck disable=SC2086  # GCE_SSH_FLAGS is a flag list by contract
gce_ssh() { local vm="$1"; shift
  gcloud compute ssh "$vm" --zone "$GCE_ZONE" ${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"} \
    --quiet --strict-host-key-checking=no ${GCE_SSH_FLAGS:-} --command "$*"; }
gce_put() { gcloud compute scp --zone "$GCE_ZONE" ${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"} \
    --quiet --strict-host-key-checking=no ${GCE_SSH_FLAGS:-} "$2" "$1:$3"; }
gce_get() { gcloud compute scp --zone "$GCE_ZONE" ${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"} \
    --quiet --strict-host-key-checking=no ${GCE_SSH_FLAGS:-} --recurse "$1:$2" "$3"; }

# The VM is deleted on every exit path unless KEEP_VM=1, including an interrupted run: a
# forgotten e2-small is cheap per hour and not cheap per month.
CURRENT_VM=""
cleanup() {
  [ -n "$CURRENT_VM" ] || return 0
  if [ "$KEEP_VM" = 1 ]; then
    echo "run-gce: leaving $CURRENT_VM up (KEEP_VM=1). Delete it with:"
    echo "  gcloud compute instances delete $CURRENT_VM --zone $GCE_ZONE --quiet"
  else
    echo "run-gce: deleting $CURRENT_VM"
    gcloud compute instances delete "$CURRENT_VM" --zone "$GCE_ZONE" \
      ${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"} --quiet >/dev/null 2>&1 || true
  fi
  CURRENT_VM=""
}
TREE="$ART/tree-$$.tgz"; GUEST="$ART/guest-$$.sh"
finish() { cleanup; rm -f "$TREE" "$GUEST"; }
trap finish EXIT INT TERM

# THE WHOLE TREE, not a scenario subset: setup.sh sources ../../lib, the assertions run
# bin/classify against catalog/, and the guest's own dist/ is what gets measured.
# test/artifacts is excluded because it is per machine and can hold gigabytes of payload.
# Named per process so two families can run from two terminals at once.
#
# COPYFILE_DISABLE, or macOS tar ships an AppleDouble `._name` beside every file that has
# an extended attribute. Those are binary, tools/agent_status.py globs `*/*.json` and
# found `._observed.json`, and the first VM run failed every scenario at the recording
# step with a UnicodeDecodeError -- after the assertions had passed.
COPYFILE_DISABLE=1 tar -C "$ROOT" --exclude ./.git --exclude ./test/artifacts -czf "$TREE" . \
  || { echo "run-gce: could not pack the tree" >&2; exit 1; }

# --- what runs on the guest ----------------------------------------------------------
# One script, shipped and run as the OS Login user. root for the installs and the queries,
# the login account for the OS Login probe, because that account is the subject.
#
#   bash guest.sh <osquery version> <facts|quiet> <scenario>
cat > "$GUEST" <<'GUEST'
#!/bin/bash
# Written by test/run-gce.sh and run on the guest. Not for running by hand.
set -uo pipefail
export AI_DISCOVERY_TELEMETRY=0
V="$1"; MODE="$2"; SC="$3"
REPO=/opt/ai-discovery
OUT=/tmp/ai-discovery-out
sudo rm -rf "$REPO" "$OUT"; sudo mkdir -p "$REPO"; mkdir -p "$OUT"
sudo tar -C "$REPO" -xzf /tmp/tree.tgz
# Belt and braces for the AppleDouble files the host side already suppresses.
sudo find "$REPO" -name '._*' -delete
. /etc/os-release
OS="$ID-$VERSION_ID"; ARCH="$(uname -m)"
printf '%s\n%s\n' "$OS" "$ARCH" > "$OUT/meta"
log() { printf '%s\n' "$*" | tee -a "$OUT/facts.txt"; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
md() { curl -sf -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null; }

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  sudo -E apt-get -qq update >/dev/null 2>&1
  sudo -E apt-get -qq install -y curl ca-certificates python3 python3-yaml >/dev/null 2>&1
  curl -fsSLo /tmp/o.deb "https://pkg.osquery.io/deb/osquery_${V}-1.linux_amd64.deb"
  sudo dpkg -i /tmp/o.deb >/dev/null 2>&1
else
  sudo dnf -q -y install --allowerasing curl python3 python3-pyyaml tar findutils >/dev/null 2>&1
  curl -fsSLo /tmp/o.rpm "https://pkg.osquery.io/rpm/osquery-${V}-1.linux.x86_64.rpm"
  sudo dnf -q -y install /tmp/o.rpm >/dev/null 2>&1
fi
command -v osqueryi >/dev/null 2>&1 || { echo "FAIL: osquery did not install"; exit 1; }
cd "$REPO" || exit 1

log "=== facts"
log "os=$OS arch=$ARCH cpus=$(nproc) mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)MB machine=$(md instance/machine-type | sed 's|.*/||') image=$(md instance/image | sed 's|.*/||')"
log "osquery=$(osqueryi --version 2>/dev/null | awk '{print $NF}') kernel=$(uname -r)"

if [ "$MODE" = facts ]; then
  # --- OS Login: what `users` can and cannot see -------------------------------------
  log "=== OS Login"
  log "enable-oslogin=$(md instance/attributes/enable-oslogin || md project/attributes/enable-oslogin || echo unset)"
  log "nsswitch: $(grep '^passwd:' /etc/nsswitch.conf)"
  me="$(id -un)"
  log "login user=$me uid=$(id -u) home=$HOME"
  if grep -q "^$me:" /etc/passwd; then log "login user IS in /etc/passwd: a local account, not an OS Login one"
  else log "login user is NOT in /etc/passwd: an NSS-only account"; fi
  log "getent passwd=$(getent passwd | wc -l) /etc/passwd=$(wc -l < /etc/passwd) oslogin_cache=$(sudo sh -c 'wc -l < /etc/oslogin_passwd.cache' 2>/dev/null || echo none)"
  log "users table, unconstrained: $(sudo osqueryi --line 'select count(*) as n from users' | awk '{print $NF}')"
  log "users table, uid=$(id -u): $(sudo osqueryi --line "select username, directory from users where uid = $(id -u)" | tr -s '\n ' ' ')"
  log "users table, uid=$(id -u), include_remote=1: $(sudo osqueryi --line "select username, directory from users where uid = $(id -u) and include_remote = 1" 2>&1 | tr -s '\n ' ' ')"
  log "home dirs on disk: $(sudo osqueryi --line "select count(*) as n from file where path like '/home/%/'" | awk '{print $NF}')"
  log "uid list as queries/browser.sql builds it: $(sudo osqueryi --line "select count(*) as n from (select uid from users union select uid from file where path like '/home/%/' or path = '/root/' or path like '/Users/%/')" | awk '{print $NF}')"

  # --- timing, on this shape, before anything is installed ---------------------------
  log "=== timing"
  s=$(date +%s%N); sudo osqueryi --json < dist/discovery-linux.sql > "$OUT/base.json"; rc=$?
  log "composed artifact, cold: $(ms $s)ms exit=$rc rows=$(python3 -c "import json;print(len(json.load(open('$OUT/base.json'))))") bytes=$(wc -c < "$OUT/base.json")"
  s=$(date +%s%N); sudo osqueryi --json < dist/discovery-linux.sql > /dev/null; log "composed artifact, warm: $(ms $s)ms"
  log "scan rows: $(python3 -c "import json;print(' '.join(r['id']+'='+r['extra'] for r in json.load(open('$OUT/base.json')) if r['kind']=='scan'))")"
  log "per kind: $(python3 -c "import json,collections;c=collections.Counter(r['kind'] for r in json.load(open('$OUT/base.json')));print(' '.join(k+'='+str(v) for k,v in sorted(c.items())))")"
  s=$(date +%s%N); sudo bin/discover --deep > "$OUT/deep.json" 2>"$OUT/deep.err"; rc=$?
  log "bin/discover --deep: $(ms $s)ms exit=$rc $(sed -n 1p "$OUT/deep.err")"
  s=$(date +%s%N); sudo bin/discover --write "$OUT/inventory.json" --status "$OUT/status.txt" >/dev/null 2>"$OUT/write.err"; rc=$?
  log "bin/discover --write: $(ms $s)ms exit=$rc"
  log "status.txt: $(cat "$OUT/status.txt" 2>/dev/null || echo '(none written)')"
  log "measure.py --check:"
  sudo python3 tools/measure.py --check 2>&1 | sed 's/^/    /' | tee -a "$OUT/facts.txt"
fi

# --- the scenario -------------------------------------------------------------------
log "=============== $SC on $OS"
sudo "test/scenarios/$SC/setup.sh"; rc=$?
if [ "$rc" = 3 ]; then log "--- $SC SKIP"; exit 3; fi
if [ "$rc" != 0 ]; then log "--- $SC FAIL (setup exit $rc)"; exit 1; fi
if python3 -c "import json,sys;sys.exit(0 if json.load(open('test/scenarios/$SC/expected.json')).get('deep') else 1)"; then
  sudo bin/discover --deep > "$OUT/payload.json" 2>"$OUT/payload.err"
else
  sudo osqueryi --json < dist/discovery-linux.sql > "$OUT/payload.json" 2>"$OUT/payload.err"
fi
[ -s "$OUT/payload.err" ] && { echo '--- osquery stderr:'; sed 's/^/    /' "$OUT/payload.err"; }
result=0
test/assert.sh "$OUT/payload.json" "test/scenarios/$SC/expected.json" || result=1

# --- the OS Login case itself, wherever Chrome landed ----------------------------------
# A real Chrome profile owned by the LOGIN account, which is the one /etc/passwd does not
# hold, and the two counts that tell the old join from the shipped artifact. Runs on the
# 75-linux-browser VM, which is the one with Chrome on it.
if ! grep -q "^$(id -un):" /etc/passwd && command -v google-chrome >/dev/null 2>&1; then
  log "=== OS Login profile probe, as $(id -un) on $OS"
  google-chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --no-first-run --no-default-browser-check \
    --user-data-dir="$HOME/.config/google-chrome" --dump-dom about:blank >/dev/null 2>&1
  ext="$HOME/.config/google-chrome/Default/Extensions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/1.0.0_0"
  mkdir -p "$ext"
  printf '%s\n' '{"name":"Fixture agent extension, OS Login user","version":"1.0.0","manifest_version":3,"permissions":["tabs"],"host_permissions":["<all_urls>"]}' > "$ext/manifest.json"
  log "ext rows under $HOME through the users table alone: $(sudo osqueryi --line "select count(*) as n from users cross join chrome_extensions using (uid) where profile_path like '$HOME/%'" 2>/dev/null | awk '{print $NF}')"
  log "ext rows under $HOME in the shipped artifact: $(sudo osqueryi --json < dist/discovery-linux.sql 2>/dev/null | python3 -c "import json,sys;print(sum(1 for r in json.load(sys.stdin) if r['kind']=='ext' and r['loc'].startswith('$HOME')))")"
fi

if [ "$result" = 0 ]; then log "--- $SC PASS"; else log "--- $SC FAIL"; fi
exit "$result"
GUEST

# One VM, one scenario. Returns the guest's verdict: 0 pass, 3 skip, anything else fail.
run_vm() {
  local fam="$1" sc="$2" mode="$3" proj="$4" imgfam="$5" vm rc i out
  vm="ai-discovery-$fam-${sc%%-*}-$$"
  out="$ART/$fam/$sc"; rm -rf "$out"; mkdir -p "$out"
  echo
  echo "=============== $fam / $sc: $vm ($GCE_MACHINE, $imgfam) in $GCE_ZONE"
  # shellcheck disable=SC2086
  gcloud compute instances create "$vm" --zone "$GCE_ZONE" ${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"} \
      --machine-type "$GCE_MACHINE" --image-family "$imgfam" --image-project "$proj" \
      --metadata enable-oslogin=TRUE --boot-disk-size 20GB \
      --labels purpose=osquery-ai-discovery ${GCE_CREATE_FLAGS:-} --quiet >/dev/null 2>"$out/create.err" \
    || { echo "FAIL: could not create $vm"; sed 's/^/    /' "$out/create.err"; return 1; }
  CURRENT_VM="$vm"

  # OS Login takes a few seconds to accept a key after boot, and the guest agent longer
  # on a cold image. Thirty tries ten seconds apart is a bound, not an expectation.
  for i in $(seq 1 30); do
    gce_ssh "$vm" true >/dev/null 2>&1 && break
    sleep 10
  done
  gce_ssh "$vm" true >/dev/null 2>&1 || { echo "FAIL: no ssh to $vm after 5 minutes"; cleanup; return 1; }
  gce_ssh "$vm" "sudo -n true" >/dev/null 2>&1 \
    || { echo "FAIL: no passwordless sudo on $vm. OS Login needs roles/compute.osAdminLogin."; cleanup; return 1; }

  gce_put "$vm" "$TREE" /tmp/tree.tgz && gce_put "$vm" "$GUEST" /tmp/guest.sh \
    || { echo "FAIL: could not copy the tree to $vm"; cleanup; return 1; }
  gce_ssh "$vm" "bash /tmp/guest.sh $OSQUERY_VERSION $mode $sc" 2>&1 | tee "$out/guest.log"
  rc=${PIPESTATUS[0]}

  gce_get "$vm" /tmp/ai-discovery-out "$out/" >/dev/null 2>&1 \
    || echo "WARN: could not fetch the guest's output; guest.log is all there is"
  cleanup

  # RECORD FROM THE HOST, against the fetched payload, with the guest's own os and arch.
  # Only on a pass: a failed run's matches are not evidence of anything.
  if [ "$rc" = 0 ] && [ -s "$out/ai-discovery-out/payload.json" ]; then
    local gos garch
    gos="$(sed -n 1p "$out/ai-discovery-out/meta")"; garch="$(sed -n 2p "$out/ai-discovery-out/meta")"
    python3 "$ROOT/tools/agent_status.py" --record "$out/ai-discovery-out/payload.json" \
      "$HERE/scenarios/$sc" --platform linux --os "$gos" --arch "$garch" || rc=1
  fi
  return "$rc"
}

run_family() {
  local fam="$1" proj imgfam sc mode=facts rc pass=0 fail=0 skip=0
  read -r proj imgfam <<EOF
$(image_of "$fam")
EOF
  mkdir -p "$ART/$fam"
  for sc in "${scenarios[@]}"; do
    run_vm "$fam" "$sc" "$mode" "$proj" "$imgfam"; rc=$?
    mode=quiet
    case "$rc" in
      0) pass=$((pass+1)) ;;
      3) skip=$((skip+1)) ;;
      *) fail=$((fail+1)) ;;
    esac
  done
  echo
  echo "run-gce: $fam: $pass passed, $fail failed, $skip skipped." \
       "Facts: $ART/$fam/${scenarios[0]}/ai-discovery-out/facts.txt"
  [ "$fail" = 0 ]
}

fails=0
for fam in "${families[@]}"; do
  run_family "$fam" || fails=$((fails+1))
done
echo
echo "run-gce: ${#families[@]} famil$([ ${#families[@]} = 1 ] && echo y || echo ies), $fails with failures."
exit "$fails"
