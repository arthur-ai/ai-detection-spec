#!/usr/bin/env bash
# Run the Linux scenarios on real Compute Engine VMs, one per image family GCE boots.
#
#   test/run-gce.sh                                  every family, every linux scenario
#   test/run-gce.sh --family rocky-9                 one family
#   test/run-gce.sh --family debian-12 71-linux-cli-agents
#   KEEP_VM=1 test/run-gce.sh --family debian-12     leave the VM up for inspection
#
# WHY A VM WHEN CONTAINERS AND A HOSTED RUNNER ALREADY PASS. Three things neither has:
#
#   * systemd as PID 1 on Debian and Rocky. The hosted runner has it on Ubuntu only and a
#     container never does, so 76-linux-systemd and the systemd marker's `ok` branch had
#     been proved on exactly one family.
#   * OS Login. Accounts come from an NSS module rather than /etc/passwd and a home
#     directory appears on first login -- the case queries/browser.sql's uid source exists
#     for, and one no container can stage. The guest script below measures it directly:
#     the old `users` join against the shipped artifact, on a profile owned by the login
#     account.
#   * a shared-core shape. e2-small is what a fleet is full of and what CI has none of,
#     so the wall-clock figures in docs/deployment.md come from here, dated.
#
# WHAT IT NEEDS: gcloud, authenticated, against a project where you may create instances
# and log in through OS Login as an admin (roles/compute.osAdminLogin: the scenarios need
# sudo). Nothing GCP-specific lands in the tree. This is a test harness, the way test/run.sh
# is a Tart harness; the deployable belongs to whoever wraps the artifacts.
#
#   GCE_PROJECT, GCE_ZONE     default: the active gcloud config, and us-central1-a
#   GCE_MACHINE               default: e2-small
#   GCE_CREATE_FLAGS          extra flags for `instances create`, e.g. --no-address
#   GCE_SSH_FLAGS             extra flags for ssh and scp, e.g. --tunnel-through-iap
#
# Everything the guest produces comes back to test/artifacts/gce/<family>/: the payloads,
# status.txt, a facts file, and each passing scenario's observed.json, which is also
# written into test/scenarios/ the way test/run.sh does. A VM run is real-install evidence
# of the same grade as a CI run; it carries no run id because it is nobody's CI.
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
trap cleanup EXIT INT TERM

# THE WHOLE TREE, not a scenario subset: setup.sh sources ../../lib, the assertions run
# bin/classify against catalog/, and --record is tools/agent_status.py. test/artifacts is
# excluded because it is per machine and can hold gigabytes of payload.
tar -C "$ROOT" --exclude ./.git --exclude ./test/artifacts -czf "$ART/tree.tgz" . \
  || { echo "run-gce: could not pack the tree" >&2; exit 1; }

# --- what runs on the guest ----------------------------------------------------------
# One script, shipped and run as the OS Login user. root for the installs and the queries,
# the login account for the OS Login probe, because that account is the subject.
cat > "$ART/guest.sh" <<'GUEST'
#!/bin/bash
# Written by test/run-gce.sh and run on the guest. Not for running by hand.
set -uo pipefail
export AI_DISCOVERY_TELEMETRY=0
V="$1"; shift
REPO=/opt/ai-discovery
OUT=/tmp/ai-discovery-out
sudo rm -rf "$REPO" "$OUT"; sudo mkdir -p "$REPO"; mkdir -p "$OUT/observed"
sudo tar -C "$REPO" -xzf /tmp/tree.tgz
. /etc/os-release
OS="$ID-$VERSION_ID"; ARCH="$(uname -m)"
log() { printf '%s\n' "$*" | tee -a "$OUT/facts.txt"; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
md() { curl -sf -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null; }
rows() { python3 -c "import json,sys;print(sum(1 for r in json.load(open('$1')) if r['kind']==sys.argv[1]))" "$2"; }

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  sudo -E apt-get -qq update >/dev/null 2>&1
  sudo -E apt-get -qq install -y curl ca-certificates python3 python3-yaml >/dev/null 2>&1
  curl -fsSLo /tmp/o.deb "https://pkg.osquery.io/deb/osquery_${V}-1.linux_amd64.deb"
  sudo dpkg -i /tmp/o.deb >/dev/null 2>&1
else
  sudo dnf -q -y --allowerasing install curl python3 python3-pyyaml tar findutils >/dev/null 2>&1
  curl -fsSLo /tmp/o.rpm "https://pkg.osquery.io/rpm/osquery-${V}-1.linux.x86_64.rpm"
  sudo dnf -q -y install /tmp/o.rpm >/dev/null 2>&1
fi
command -v osqueryi >/dev/null 2>&1 || { echo "FAIL: osquery did not install"; exit 1; }
cd "$REPO" || exit 1

log "=== facts"
log "os=$OS arch=$ARCH cpus=$(nproc) mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)MB machine=$(md instance/machine-type | sed 's|.*/||') image=$(md instance/image | sed 's|.*/||')"
log "osquery=$(osqueryi --version 2>/dev/null | awk '{print $NF}') kernel=$(uname -r)"

# --- OS Login: what `users` can and cannot see -----------------------------------------
log "=== OS Login"
log "enable-oslogin=$(md instance/attributes/enable-oslogin || md project/attributes/enable-oslogin || echo unset)"
log "nsswitch: $(grep '^passwd:' /etc/nsswitch.conf)"
me="$(id -un)"
log "login user=$me uid=$(id -u) home=$HOME"
if grep -q "^$me:" /etc/passwd; then log "login user IS in /etc/passwd: a local account, not an OS Login one"
else log "login user is NOT in /etc/passwd: an NSS-only account"; fi
log "getent passwd=$(getent passwd | wc -l) /etc/passwd=$(wc -l < /etc/passwd) oslogin_cache=$(sudo wc -l < /etc/oslogin_passwd.cache 2>/dev/null || echo none)"
log "users table, unconstrained: $(sudo osqueryi --line 'select count(*) as n from users' | awk '{print $NF}')"
log "users table, uid=$(id -u): $(sudo osqueryi --line "select username, directory from users where uid = $(id -u)" | tr -s '\n ' ' ')"
log "home dirs on disk: $(sudo osqueryi --line "select count(*) as n from file where path like '/home/%/'" | awk '{print $NF}')"
log "uid list as queries/browser.sql builds it: $(sudo osqueryi --line "select count(*) as n from (select uid from users union select uid from file where path like '/home/%/' or path = '/root/' or path like '/Users/%/')" | awk '{print $NF}')"

# --- timing, on this shape --------------------------------------------------------------
log "=== timing"
s=$(date +%s%N); sudo osqueryi --json < dist/discovery-linux.sql > "$OUT/base.json"; rc=$?
log "composed artifact: $(ms $s)ms exit=$rc rows=$(python3 -c "import json;print(len(json.load(open('$OUT/base.json'))))") bytes=$(wc -c < "$OUT/base.json")"
log "scan rows: $(python3 -c "import json;print(' '.join(r['id']+'='+r['extra'] for r in json.load(open('$OUT/base.json')) if r['kind']=='scan'))")"
log "per kind: $(python3 -c "import json,collections;c=collections.Counter(r['kind'] for r in json.load(open('$OUT/base.json')));print(' '.join(k+'='+str(v) for k,v in sorted(c.items())))")"
s=$(date +%s%N); sudo bin/discover --deep > "$OUT/deep.json" 2>"$OUT/deep.err"; rc=$?
log "bin/discover --deep: $(ms $s)ms exit=$rc $(sed -n 1p "$OUT/deep.err")"
s=$(date +%s%N); sudo bin/discover --write "$OUT/inventory.json" --status "$OUT/status.txt" >/dev/null 2>"$OUT/write.err"; rc=$?
log "bin/discover --write: $(ms $s)ms exit=$rc"
log "status.txt: $(cat "$OUT/status.txt" 2>/dev/null || echo '(none written)')"
log "measure.py --check:"
sudo python3 tools/measure.py --check 2>&1 | sed 's/^/    /' | tee -a "$OUT/facts.txt"

# --- the scenarios ----------------------------------------------------------------------
pass=0 fail=0 skip=0
for sc in "$@"; do
  log "=============== $sc on $OS"
  sudo "test/scenarios/$sc/setup.sh"; rc=$?
  if [ "$rc" = 3 ]; then log "--- $sc SKIP"; skip=$((skip+1)); continue; fi
  if [ "$rc" != 0 ]; then log "--- $sc FAIL (setup exit $rc)"; fail=$((fail+1)); continue; fi
  if python3 -c "import json,sys;sys.exit(0 if json.load(open('test/scenarios/$sc/expected.json')).get('deep') else 1)"; then
    sudo bin/discover --deep > "$OUT/$sc.json" 2>"$OUT/$sc.err"
  else
    sudo osqueryi --json < dist/discovery-linux.sql > "$OUT/$sc.json" 2>"$OUT/$sc.err"
  fi
  [ -s "$OUT/$sc.err" ] && { echo '--- osquery stderr:'; sed 's/^/    /' "$OUT/$sc.err"; }
  if test/assert.sh "$OUT/$sc.json" "test/scenarios/$sc/expected.json" \
     && sudo python3 tools/agent_status.py --record "$OUT/$sc.json" "test/scenarios/$sc" \
          --platform linux --os "$OS" --arch "$ARCH"; then
    cp "test/scenarios/$sc/observed.json" "$OUT/observed/$sc.json" 2>/dev/null || true
    log "--- $sc PASS"; pass=$((pass+1))
  else
    log "--- $sc FAIL"; fail=$((fail+1))
  fi
done

# --- the OS Login case itself ----------------------------------------------------------
# A real Chrome profile owned by the LOGIN account, which is the one /etc/passwd does not
# hold, and the two counts that tell the old join from the shipped artifact. Needs Chrome,
# which 75-linux-browser installs; without it the probe says so rather than passing.
log "=== OS Login profile probe"
if grep -q "^$me:" /etc/passwd; then
  log "not run: the login user is a local account, so there is nothing OS Login about it"
elif ! command -v google-chrome >/dev/null 2>&1; then
  log "not run: no Chrome on this VM. Include 75-linux-browser in the scenario list."
else
  google-chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --no-first-run --no-default-browser-check \
    --user-data-dir="$HOME/.config/google-chrome" --dump-dom about:blank >/dev/null 2>&1
  ext="$HOME/.config/google-chrome/Default/Extensions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/1.0.0_0"
  mkdir -p "$ext"
  printf '%s\n' '{"name":"Fixture agent extension, OS Login user","version":"1.0.0","manifest_version":3,"permissions":["tabs"],"host_permissions":["<all_urls>"]}' > "$ext/manifest.json"
  log "ext rows under $HOME through the users table alone: $(sudo osqueryi --line "select count(*) as n from users cross join chrome_extensions using (uid) where profile_path like '$HOME/%'" | awk '{print $NF}')"
  log "ext rows under $HOME in the shipped artifact: $(sudo osqueryi --json < dist/discovery-linux.sql | python3 -c "import json,sys;print(sum(1 for r in json.load(sys.stdin) if r['kind']=='ext' and r['loc'].startswith('$HOME')))")"
fi

log "run-gce guest: $pass passed, $fail failed, $skip skipped on $OS"
[ "$fail" = 0 ]
GUEST

run_family() {
  local fam="$1" proj imgfam vm rc i
  read -r proj imgfam <<EOF
$(image_of "$fam")
EOF
  vm="ai-discovery-$fam-$$"
  echo
  echo "=============== $fam: $vm ($GCE_MACHINE, $imgfam) in $GCE_ZONE"
  # shellcheck disable=SC2086
  gcloud compute instances create "$vm" --zone "$GCE_ZONE" ${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"} \
      --machine-type "$GCE_MACHINE" --image-family "$imgfam" --image-project "$proj" \
      --metadata enable-oslogin=TRUE --boot-disk-size 20GB \
      --labels purpose=osquery-ai-discovery ${GCE_CREATE_FLAGS:-} --quiet >/dev/null \
    || { echo "FAIL: could not create $vm"; return 1; }
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

  gce_put "$vm" "$ART/tree.tgz" /tmp/tree.tgz && gce_put "$vm" "$ART/guest.sh" /tmp/guest.sh \
    || { echo "FAIL: could not copy the tree to $vm"; cleanup; return 1; }
  gce_ssh "$vm" "bash /tmp/guest.sh $OSQUERY_VERSION ${scenarios[*]}" 2>&1 | tee "$ART/$fam.log"
  rc=${PIPESTATUS[0]}

  rm -rf "$ART/$fam"; mkdir -p "$ART/$fam"
  gce_get "$vm" /tmp/ai-discovery-out "$ART/$fam/" >/dev/null 2>&1 \
    || echo "WARN: could not fetch the guest's output; the log above is all there is"
  # The observations, into the tree, as test/run.sh does for a VM run.
  for f in "$ART/$fam"/ai-discovery-out/observed/*.json; do
    [ -f "$f" ] || continue
    cp "$f" "$HERE/scenarios/$(basename "$f" .json)/observed.json"
  done
  cleanup
  return "$rc"
}

fails=0
for fam in "${families[@]}"; do
  run_family "$fam" || fails=$((fails+1))
done
echo
echo "run-gce: ${#families[@]} famil$([ ${#families[@]} = 1 ] && echo y || echo ies), $fails failed." \
     "Facts and payloads are under test/artifacts/gce/<family>/ai-discovery-out/."
exit "$fails"
