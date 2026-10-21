#!/usr/bin/env bash
# Run the Linux scenarios on real EC2 instances: one image family per run, ONE FRESH
# INSTANCE PER SCENARIO, reached through SSM.
#
#   test/run-ec2.sh                                    every default family, every linux scenario
#   test/run-ec2.sh --family al2023-arm64              one family
#   test/run-ec2.sh --family ubuntu-2404 71-linux-cli-agents
#   KEEP_VM=1 test/run-ec2.sh --family al2023 70-linux-baseline   leave that instance up
#   EC2_CREDITS=standard EC2_DRAIN_MINUTES=10 test/run-ec2.sh --family al2023 70-linux-baseline
#
# test/run-gce.sh's counterpart, built the same way and for the same reason -- one throwaway
# host per scenario, facts and timing on the first one before anything is installed, and the
# observations recorded from the host. What EC2 has that neither CI nor a Compute Engine VM does:
#
#   * Amazon Linux 2023, the default EC2 image. Fedora-derived, but its own packages and
#     repositories.
#   * Graviton. The arm64 families run on t4g.small; CI's arm64 runner is Ubuntu only.
#   * burstable shapes in both credit modes. T3 and T4g default to unlimited; in standard mode
#     an instance that has spent its CPU credits is held to its baseline, 20% of each vCPU on
#     a .small, which is a scan's worst wall clock. EC2_DRAIN_MINUTES spends the credits before
#     the timing, and every timed step reports the CPU steal it saw, which is how a throttled
#     run shows itself from inside.
#   * ssm-user, the account Session Manager creates on first use. After the facts instance's
#     scenario, one real session as ssm-user plants a state directory in its home, and the
#     shipped artifact must return it.
#
# REACHED THROUGH SSM, NOT INBOUND SSH. ssh and scp ride a Session Manager session
# (AWS-StartSSHSession), so the security group needs no inbound rule and no key pair exists in
# the account: a throwaway key made for this run reaches the image's default user through
# cloud-init, and is deleted with the run.
#
# WHAT IT NEEDS: the AWS CLI and the Session Manager plugin, credentials that may run and
# terminate instances and start sessions, and instances SSM can manage -- through
# EC2_INSTANCE_PROFILE (a profile with AmazonSSMManagedInstanceCore), or through the account's
# Default Host Management Configuration. Nothing AWS-specific lands in the tree. This is a test
# harness, the way test/run-gce.sh is; the deployable belongs to whoever wraps the artifacts.
#
#   AWS_PROFILE, AWS_REGION   the usual. AWS_REGION, or the profile's region, must be set
#   EC2_INSTANCE_PROFILE      instance profile name; empty relies on Default Host Management
#   EC2_SUBNET                a subnet with a route out (pkg.osquery.io, the scenarios'
#                             downloads, the SSM endpoints); default: the default VPC's
#   EC2_SECURITY_GROUP        a group with outbound access and no inbound rule needed.
#                             Default: one made for this run and deleted with it -- not the
#                             VPC's default group, which a hardened account leaves without
#                             even an egress rule (CIS AWS 5.4), so SSM never hears back
#   EC2_PUBLIC_IP             1 (default) for a public address; 0 for a subnet behind a NAT
#   EC2_INSTANCE_TYPE         default: t3.small, or t4g.small for an arm64 family
#   EC2_CREDITS               unlimited or standard; default: the type's default, unlimited
#   EC2_DRAIN_MINUTES         facts instance only: before the timing, keep every vCPU busy
#                             until the instance is throttled, for at most this many minutes
#
# Everything the guest produces comes back to test/artifacts/ec2/<family>/<scenario>/ -- or
# <family>-<credits>/ when EC2_CREDITS is set, so a timing run never overwrites a family run's
# facts: the payload, status.txt, the facts file. Observations are recorded INTO THE TREE FROM
# THE HOST, with tools/agent_status.py --record against the fetched payload, as
# test/run-gce.sh does, one record at a time under a lock -- two families running from two
# terminals record the same scenario's observed.json, and a read-modify-write without one can
# drop the other's. An instance run is real-install evidence of the same grade as a CI run; it
# carries no run id because it is nobody's CI, so where CI holds the same observation with
# one, keep CI's.
#
# BASH 3.2, because this runs on the Mac that drives it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ART="$HERE/artifacts/ec2"; mkdir -p "$ART"

: "${OSQUERY_VERSION:=5.23.1}"
: "${KEEP_VM:=0}"
: "${EC2_PUBLIC_IP:=1}"
: "${EC2_CREDITS:=}"
: "${EC2_DRAIN_MINUTES:=0}"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

families=()
while [ $# -gt 0 ]; do
  case "$1" in
    --family) [ $# -ge 2 ] || usage; families+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    -*) echo "run-ec2: unknown flag $1" >&2; usage ;;
    *) break ;;
  esac
done
scenarios=("$@")
[ ${#families[@]} -gt 0 ] || families=(al2023 al2023-arm64 ubuntu-2404)
if [ ${#scenarios[@]} -eq 0 ]; then
  for d in "$HERE"/scenarios/*/; do
    n="$(basename "$d")"
    [ -f "$d/expected.json" ] || continue
    [ "$(python3 -c "import json;print(json.load(open('$d/expected.json')).get('platform'))")" = linux ] \
      || continue
    scenarios+=("$n")
  done
fi

# The image for each name this script accepts -- the SSM public parameter that always names
# the current one -- then the default instance type and the image's default user. The x86_64
# families are what keeps 75-linux-browser from skipping, since Google ships no arm64 Linux
# Chrome; the arm64 ones are Graviton's.
image_of() {
  case "$1" in
    al2023)            echo "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 t3.small ec2-user" ;;
    al2023-arm64)      echo "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 t4g.small ec2-user" ;;
    ubuntu-2404)       echo "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id t3.small ubuntu" ;;
    ubuntu-2404-arm64) echo "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id t4g.small ubuntu" ;;
    *) return 1 ;;
  esac
}

command -v aws >/dev/null 2>&1 || { echo "run-ec2: the AWS CLI is required" >&2; exit 1; }
command -v session-manager-plugin >/dev/null 2>&1 \
  || { echo "run-ec2: the Session Manager plugin is required: it carries ssh, and the ssm-user session" >&2; exit 1; }
[ -n "${AWS_REGION:-}" ] || AWS_REGION="$(aws configure get region 2>/dev/null)"
[ -n "${AWS_REGION:-}" ] || { echo "run-ec2: set AWS_REGION, or a region on the profile" >&2; exit 1; }
export AWS_REGION
aws sts get-caller-identity >/dev/null 2>&1 \
  || { echo "run-ec2: no AWS credentials here. For an SSO profile: aws sso login" >&2; exit 1; }
for f in "${families[@]}"; do
  image_of "$f" >/dev/null \
    || { echo "run-ec2: unknown family $f (al2023, al2023-arm64, ubuntu-2404, ubuntu-2404-arm64)" >&2; exit 1; }
done
case "$EC2_CREDITS" in ""|unlimited|standard) ;;
  *) echo "run-ec2: EC2_CREDITS is unlimited or standard, not $EC2_CREDITS" >&2; exit 1 ;; esac

# The VPC the instances land in: the subnet's, or the default VPC, which an account may not have.
if [ -n "${EC2_SUBNET:-}" ]; then
  VPC="$(aws ec2 describe-subnets --subnet-ids "$EC2_SUBNET" --query 'Subnets[0].VpcId' --output text 2>/dev/null)"
else
  VPC="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
fi
case "$VPC" in vpc-*) ;;
  *) echo "run-ec2: no VPC to launch into. Set EC2_SUBNET: this region has no default VPC${EC2_SUBNET:+, or $EC2_SUBNET does not exist}" >&2
     exit 1 ;;
esac

# --- the throwaway key, and the transport ---------------------------------------------
# Made per process, so two families can run from two terminals at once, and handed to the
# image's default user by cloud-init: no key pair in the account to clean up after.
KEY="$ART/key-$$"; USERDATA="$ART/user-data-$$"
ssh-keygen -q -t ed25519 -N '' -C "run-ec2-$$" -f "$KEY" \
  || { echo "run-ec2: could not make a key" >&2; exit 1; }
printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$KEY.pub")" > "$USERDATA"

# AWS_PROFILE and AWS_REGION reach the ProxyCommand through the environment. -n on ssh, so a
# command run in a loop never reads this script's stdin.
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30
          -o ServerAliveInterval=30
          -o "ProxyCommand=aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p")
LOGIN=""
ec2_ssh() { local id="$1"; shift; ssh -n "${SSH_OPTS[@]}" "$LOGIN@$id" "$*"; }
ec2_put() { scp -q "${SSH_OPTS[@]}" "$2" "$LOGIN@$1:$3"; }
ec2_get() { scp -q -r "${SSH_OPTS[@]}" "$LOGIN@$1:$2" "$3"; }

# The instance is terminated on every exit path unless KEEP_VM=1, including an interrupted
# run. It is named before it exists: a run-instances call that times out on the client can
# still have launched one, so the name is what cleanup looks it up by when no id came back.
CURRENT_VM=""; CURRENT_NAME=""
cleanup() {
  [ -n "$CURRENT_NAME" ] || return 0
  if [ -z "$CURRENT_VM" ]; then
    CURRENT_VM="$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=$CURRENT_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
  fi
  if [ -z "$CURRENT_VM" ] || [ "$CURRENT_VM" = None ]; then CURRENT_VM=""; CURRENT_NAME=""; return 0; fi
  if [ "$KEEP_VM" = 1 ]; then
    echo "run-ec2: leaving $CURRENT_NAME ($CURRENT_VM) up (KEEP_VM=1). Terminate it with:"
    echo "  aws ec2 terminate-instances --instance-ids $CURRENT_VM"
  else
    echo "run-ec2: terminating $CURRENT_NAME ($CURRENT_VM)"
    # The error is shown, and the state is looked up afterwards, because an instance that
    # outlives a run that reported success is the one nobody comes back for.
    aws ec2 terminate-instances --instance-ids $CURRENT_VM --output text >/dev/null 2>"$ART/terminate-$$.err" \
      || sed 's/^/    /' "$ART/terminate-$$.err"
    # Read a few times before warning: EC2's reads are eventually consistent, and the first
    # describe after a terminate that had succeeded answered `running` four times in about
    # sixty, each a false alarm.
    local st i
    for i in 1 2 3 4 5 6; do
      st="$(aws ec2 describe-instances --instance-ids $CURRENT_VM \
             --query 'Reservations[].Instances[].State.Name' --output text 2>/dev/null)"
      case "$st" in shutting-down*|terminated*) break ;; esac
      sleep 5
    done
    case "$st" in shutting-down*|terminated*) ;;
      *) echo "run-ec2: WARNING: $CURRENT_VM is '$st', not terminating. Terminate it by hand:"
         echo "  aws ec2 terminate-instances --instance-ids $CURRENT_VM" ;;
    esac
  fi
  CURRENT_VM=""; CURRENT_NAME=""
}
TREE="$ART/tree-$$.tgz"; GUEST="$ART/guest-$$.sh"

# THE RUN'S OWN SECURITY GROUP, unless one was named: no inbound rule, and the egress rule AWS
# gives every new group. Deleted at exit once its instances are gone, since a group cannot be
# deleted while a network interface still holds it.
OWN_SG=""; LAUNCHED=""
drop_sg() {
  [ -n "$OWN_SG" ] || return 0
  if [ "$KEEP_VM" = 1 ]; then
    echo "run-ec2: leaving security group $OWN_SG for the kept instance. Delete it after with:"
    echo "  aws ec2 delete-security-group --group-id $OWN_SG"
    return 0
  fi
  # shellcheck disable=SC2086  # a list of instance ids
  [ -z "$LAUNCHED" ] || aws ec2 wait instance-terminated --instance-ids $LAUNCHED 2>/dev/null
  local i
  for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --group-id "$OWN_SG" >/dev/null 2>&1 && { OWN_SG=""; return 0; }
    sleep 10
  done
  echo "run-ec2: WARNING: could not delete security group $OWN_SG. Delete it by hand:"
  echo "  aws ec2 delete-security-group --group-id $OWN_SG"
}
# ONE RECORD AT A TIME across every run-ec2.sh on this machine, since two families record the
# same scenario's observed.json. mkdir is atomic, and the lock is released on every exit path.
LOCK="$ART/.record.lock"; HOLDING_LOCK=0
lock() {
  local i
  for i in $(seq 1 300); do
    mkdir "$LOCK" 2>/dev/null && { HOLDING_LOCK=1; return 0; }
    sleep 1
  done
  echo "run-ec2: $LOCK has been held for 5 minutes. If no run-ec2.sh is recording, remove it." >&2
  return 1
}
unlock() { [ "$HOLDING_LOCK" = 1 ] && rmdir "$LOCK" 2>/dev/null; HOLDING_LOCK=0; }
finish() { cleanup; drop_sg; unlock; rm -f "$TREE" "$GUEST" "$KEY" "$KEY.pub" "$USERDATA" "$ART/terminate-$$.err"; }
# A signal ENDS the run, and cleanup runs once, from EXIT. A handler that only cleaned up would
# return into the loop, and the next scenario would launch without its key or security group.
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -z "${EC2_SECURITY_GROUP:-}" ]; then
  OWN_SG="$(aws ec2 create-security-group --vpc-id "$VPC" --group-name "run-ec2-$$-$(date +%s)" \
    --description "test/run-ec2.sh: no inbound rule, default egress; deleted with the run" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=purpose,Value=osquery-ai-discovery}]' \
    --query GroupId --output text)" \
    || { echo "run-ec2: could not create a security group in $VPC" >&2; exit 1; }
  EC2_SECURITY_GROUP="$OWN_SG"
fi

# THE WHOLE TREE, as test/run-gce.sh ships it and for its reasons: setup.sh sources ../../lib,
# the assertions run bin/classify against catalog/, the guest's own dist/ is what gets
# measured, and test/artifacts is excluded. COPYFILE_DISABLE, or macOS tar adds an AppleDouble
# `._name` beside every file with an extended attribute, and tools/agent_status.py chokes on
# `._observed.json`; --no-xattrs, or it writes them as pax headers instead, and GNU tar on the
# guest prints a warning for every file.
COPYFILE_DISABLE=1 tar -C "$ROOT" --no-xattrs --exclude ./.git --exclude ./test/artifacts -czf "$TREE" . \
  || { echo "run-ec2: could not pack the tree" >&2; exit 1; }

# --- what runs on the guest ----------------------------------------------------------
# One script, shipped and run as the image's default user, with sudo for the installs and
# the queries.
#
#   bash guest.sh <osquery version> <facts|quiet|ssm-user> <scenario> <credits> <drain minutes>
cat > "$GUEST" <<'GUEST'
#!/bin/bash
# Written by test/run-ec2.sh and run on the guest. Not for running by hand.
set -uo pipefail
export AI_DISCOVERY_TELEMETRY=0
V="$1"; MODE="$2"; SC="$3"; CREDITS="${4:-default}"; DRAIN="${5:-0}"
REPO=/opt/ai-discovery
OUT=/tmp/ai-discovery-out
log() { printf '%s\n' "$*" | tee -a "$OUT/facts.txt"; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
imds() {
  local t
  t="$(curl -sf -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)" \
    && curl -sf -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"
}
# CPU steal across a timed step: the share of the CPU the hypervisor kept. A burstable
# instance held to its baseline shows it here and nowhere else from inside.
cpu() { awk '/^cpu /{t=0; for (i = 2; i <= 9; i++) t += $i; print t, $9}' /proc/stat; }
steal() {
  awk -v a="$1" -v b="$(cpu)" 'BEGIN { split(a, x, " "); split(b, y, " "); d = y[1] - x[1]
    printf "steal=%d%%", (d > 0 ? 100 * (y[2] - x[2]) / d : 0) }'
}

# --- ssm-user, after the scenario: Session Manager made the account and the host planted
# ~/.claude as it. ASSERTED: the shipped artifact must return that directory.
if [ "$MODE" = ssm-user ]; then
  cd "$REPO" || exit 1
  log "=== ssm-user"
  log "passwd: $(getent passwd ssm-user || echo 'absent: no session created it')"
  log "users table: $(sudo osqueryi --line "select username, uid, directory from users where username = 'ssm-user'" | tr -s '\n ' ' ')"
  n="$(sudo osqueryi --json < dist/discovery-linux.sql 2>/dev/null | python3 -c "
import json, sys
print(sum(1 for r in json.load(sys.stdin) if r['kind'] == 'file' and r['loc'] == '/home/ssm-user/.claude/'))")"
  log "rows for /home/ssm-user/.claude/ in the shipped artifact: $n"
  if [ "${n:-0}" -ge 1 ] 2>/dev/null; then log "ssm-user probe: PASS"; exit 0; fi
  log "ssm-user probe: FAIL -- the shipped artifact did not return ssm-user's state directory"
  exit 1
fi

sudo rm -rf "$REPO" "$OUT"; sudo mkdir -p "$REPO"; mkdir -p "$OUT"
sudo tar -C "$REPO" -xzf /tmp/tree.tgz
sudo find "$REPO" -name '._*' -delete
. /etc/os-release
OS="$ID-$VERSION_ID"; ARCH="$(uname -m)"
printf '%s\n%s\n' "$OS" "$ARCH" > "$OUT/meta"

# osquery for this architecture: the deb names it amd64/arm64, the rpm x86_64/aarch64.
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  sudo -E apt-get -qq update >/dev/null 2>&1
  sudo -E apt-get -qq install -y curl ca-certificates python3 python3-yaml >/dev/null 2>&1
  curl --retry 3 -fsSLo /tmp/o.deb "https://pkg.osquery.io/deb/osquery_${V}-1.linux_$(dpkg --print-architecture).deb"
  sudo dpkg -i /tmp/o.deb >/dev/null 2>&1
else
  # --allowerasing: Amazon Linux and Rocky ship curl-minimal, which conflicts with curl.
  sudo dnf -q -y install --allowerasing curl python3 python3-pyyaml tar gzip findutils procps-ng >/dev/null 2>&1
  curl --retry 3 -fsSLo /tmp/o.rpm "https://pkg.osquery.io/rpm/osquery-${V}-1.linux.${ARCH}.rpm"
  sudo dnf -q -y install /tmp/o.rpm >/dev/null 2>&1
fi
command -v osqueryi >/dev/null 2>&1 || { echo "FAIL: osquery did not install"; exit 1; }
cd "$REPO" || exit 1

log "=== facts"
log "os=$OS arch=$ARCH cpus=$(nproc) mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)MB type=$(imds instance-type) ami=$(imds ami-id) credits=$CREDITS"
log "osquery=$(osqueryi --version 2>/dev/null | awk '{print $NF}') kernel=$(uname -r)"

if [ "$MODE" = facts ]; then
  # --- accounts: the image's default user is a local one, unlike an OS Login account ---
  log "=== accounts"
  me="$(id -un)"
  if grep -q "^$me:" /etc/passwd; then log "login user $me (uid $(id -u)) is in /etc/passwd"
  else log "login user $me is NOT in /etc/passwd: an NSS-only account"; fi
  log "getent passwd=$(getent passwd | wc -l) /etc/passwd=$(wc -l < /etc/passwd) users table=$(sudo osqueryi --line 'select count(*) as n from users' | awk '{print $NF}')"
  log "users table, uid=$(id -u): $(sudo osqueryi --line "select username, directory from users where uid = $(id -u)" | tr -s '\n ' ' ')"

  # --- spend the CPU credits, so the timing is the baseline's -------------------------
  # Every vCPU busy, a minute at a time, until the hypervisor holds the instance to its
  # baseline -- half the CPU or more stolen in a minute -- or DRAIN minutes have passed.
  # Measured rather than timed, because how many credits a fresh instance starts with is
  # not something to assume.
  if [ "$DRAIN" -gt 0 ] 2>/dev/null; then
    log "=== draining CPU credits: every vCPU busy until throttled, at most ${DRAIN} min"
    m=0; held=no
    while [ "$m" -lt "$DRAIN" ]; do
      c=$(cpu); i=0
      while [ "$i" -lt "$(nproc)" ]; do timeout 60 sh -c 'while :; do :; done' & i=$((i + 1)); done
      wait; m=$((m + 1))
      st="$(steal "$c")"; log "  minute $m: $st"
      [ "${st#steal=}" != "${st}" ] && [ "${st//[!0-9]/}" -ge 50 ] && { held=yes; break; }
    done
    log "drain: $m min, held to the baseline: $held"
  fi

  # --- timing, on this shape, before anything is installed ---------------------------
  log "=== timing"
  c=$(cpu); s=$(date +%s%N); sudo osqueryi --json < dist/discovery-linux.sql > "$OUT/base.json"; rc=$?
  log "composed artifact, cold: $(ms $s)ms $(steal "$c") exit=$rc rows=$(python3 -c "import json;print(len(json.load(open('$OUT/base.json'))))") bytes=$(wc -c < "$OUT/base.json")"
  c=$(cpu); s=$(date +%s%N); sudo osqueryi --json < dist/discovery-linux.sql > /dev/null
  log "composed artifact, warm: $(ms $s)ms $(steal "$c")"
  log "scan rows: $(python3 -c "import json;print(' '.join(r['id']+'='+r['extra'] for r in json.load(open('$OUT/base.json')) if r['kind']=='scan'))")"
  log "per kind: $(python3 -c "import json,collections;c=collections.Counter(r['kind'] for r in json.load(open('$OUT/base.json')));print(' '.join(k+'='+str(v) for k,v in sorted(c.items())))")"
  c=$(cpu); s=$(date +%s%N); sudo bin/discover --deep > "$OUT/deep.json" 2>"$OUT/deep.err"; rc=$?
  log "bin/discover --deep: $(ms $s)ms $(steal "$c") exit=$rc $(sed -n 1p "$OUT/deep.err")"
  c=$(cpu); s=$(date +%s%N); sudo bin/discover --write "$OUT/inventory.json" --status "$OUT/status.txt" >/dev/null 2>"$OUT/write.err"; rc=$?
  log "bin/discover --write: $(ms $s)ms $(steal "$c") exit=$rc"
  log "status.txt: $(cat "$OUT/status.txt" 2>/dev/null || echo '(none written)')"
  log "measure.py --check:"
  sudo python3 tools/measure.py --check 2>&1 | sed 's/^/    /' | tee -a "$OUT/facts.txt"
fi

# --- the scenario -------------------------------------------------------------------
log "=============== $SC on $OS $ARCH"
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
if [ "$result" = 0 ]; then log "--- $SC PASS"; else log "--- $SC FAIL"; fi
exit "$result"
GUEST

# A real Session Manager session, which is what makes the agent create ssm-user, running one
# command as it: a state directory in its home. The plugin ends a session at EOF on its
# stdin, so stdin is held open while the command runs; and AWS-StartNonInteractiveCommand
# execs its command rather than handing it to a shell, hence the sh -c.
ssm_user_session() {
  sleep 20 | aws ssm start-session --target "$1" --document-name AWS-StartNonInteractiveCommand \
    --parameters '{"command":["sh -c \"mkdir -p $HOME/.claude && echo planted $HOME/.claude as $(id -un)\""]}' 2>&1 \
    | grep -E 'planted|rror' | sed 's/^/    /'
}

# One instance, one scenario. Returns the guest's verdict: 0 pass, 3 skip, anything else fail.
run_vm() {
  local fam="$1" sc="$2" mode="$3" param="$4" type="$5" vm id ami root rc i out st drain=0
  vm="ai-discovery-$fam-${sc%%-*}-$$"
  out="$ART/$fam${EC2_CREDITS:+-$EC2_CREDITS}/$sc"; rm -rf "$out"; mkdir -p "$out"
  [ "$mode" = facts ] && drain="$EC2_DRAIN_MINUTES"
  ami="$(aws ssm get-parameter --name "$param" --query Parameter.Value --output text 2>"$out/create.err")" \
    || { echo "FAIL: no image for $fam"; sed 's/^/    /' "$out/create.err"; return 1; }
  root="$(aws ec2 describe-images --image-ids "$ami" --query 'Images[0].RootDeviceName' --output text)"
  echo
  echo "=============== $fam / $sc: $vm ($type, $ami) in $AWS_REGION${EC2_CREDITS:+, $EC2_CREDITS credits}"

  # 20GB rather than the image's 8: the IDE and browser scenarios download a gigabyte or more.
  local args=(--image-id "$ami" --instance-type "$type" --count 1
    --user-data "file://$USERDATA"
    --metadata-options HttpTokens=required,HttpEndpoint=enabled
    --block-device-mappings "DeviceName=$root,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$vm},{Key=purpose,Value=osquery-ai-discovery}]")
  [ -z "${EC2_INSTANCE_PROFILE:-}" ] || args+=(--iam-instance-profile "Name=$EC2_INSTANCE_PROFILE")
  [ -z "${EC2_SUBNET:-}" ] || args+=(--subnet-id "$EC2_SUBNET")
  [ -z "${EC2_SECURITY_GROUP:-}" ] || args+=(--security-group-ids "$EC2_SECURITY_GROUP")
  if [ -n "${EC2_SUBNET:-}" ] && [ "$EC2_PUBLIC_IP" = 1 ]; then args+=(--associate-public-ip-address); fi
  [ -z "$EC2_CREDITS" ] || args+=(--credit-specification "CpuCredits=$EC2_CREDITS")

  CURRENT_NAME="$vm"
  id="$(aws ec2 run-instances "${args[@]}" --query 'Instances[0].InstanceId' --output text 2>"$out/create.err")" \
    || { echo "FAIL: could not launch $vm"; sed 's/^/    /' "$out/create.err"; cleanup; return 1; }
  CURRENT_VM="$id"; LAUNCHED="$LAUNCHED $id"

  # SSM first, then ssh over it: the agent registers within a minute or two of boot, and
  # cloud-init installs the key a little after. Both waits are bounds, not expectations.
  for i in $(seq 1 60); do
    st="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
           --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)"
    [ "$st" = Online ] && break
    sleep 5
  done
  [ "$st" = Online ] || { echo "FAIL: $id never came online in SSM. Does it have an instance profile with AmazonSSMManagedInstanceCore, and outbound access to the SSM endpoints -- an egress rule in its security group, and a route out of its subnet?"; cleanup; return 1; }
  for i in $(seq 1 30); do
    ec2_ssh "$id" true >/dev/null 2>&1 && break
    sleep 10
  done
  ec2_ssh "$id" true >/dev/null 2>&1 || { echo "FAIL: no ssh to $id over SSM after 5 minutes"; cleanup; return 1; }
  ec2_ssh "$id" "sudo -n true" >/dev/null 2>&1 || { echo "FAIL: no passwordless sudo for $LOGIN on $id"; cleanup; return 1; }

  ec2_put "$id" "$TREE" /tmp/tree.tgz && ec2_put "$id" "$GUEST" /tmp/guest.sh \
    || { echo "FAIL: could not copy the tree to $id"; cleanup; return 1; }
  ec2_ssh "$id" "bash /tmp/guest.sh $OSQUERY_VERSION $mode $sc ${EC2_CREDITS:-default} $drain" 2>&1 | tee "$out/guest.log"
  rc=${PIPESTATUS[0]}

  # ssm-user, on the facts instance, once its scenario has asserted: planting a state
  # directory before would put an agent on the baseline.
  if [ "$mode" = facts ] && [ "$rc" != 3 ]; then
    ssm_user_session "$id" | tee -a "$out/guest.log"
    ec2_ssh "$id" "bash /tmp/guest.sh $OSQUERY_VERSION ssm-user $sc" 2>&1 | tee -a "$out/guest.log"
    [ "${PIPESTATUS[0]}" = 0 ] || rc=1
  fi

  # stderr is kept and shown on failure: a WARN with no reason is one nobody can act on.
  ec2_get "$id" /tmp/ai-discovery-out "$out/" >/dev/null 2>"$out/fetch.err" \
    || { echo "WARN: could not fetch the guest's output; guest.log is all there is:"
         sed 's/^/    /' "$out/fetch.err"; }
  cleanup

  # RECORD FROM THE HOST, against the fetched payload, with the guest's own os and arch.
  # Only on a pass: a failed run's matches are not evidence of anything.
  if [ "$rc" = 0 ] && [ -s "$out/ai-discovery-out/payload.json" ]; then
    local gos garch
    gos="$(sed -n 1p "$out/ai-discovery-out/meta")"; garch="$(sed -n 2p "$out/ai-discovery-out/meta")"
    if lock; then
      python3 "$ROOT/tools/agent_status.py" --record "$out/ai-discovery-out/payload.json" \
        "$HERE/scenarios/$sc" --platform linux --os "$gos" --arch "$garch" || rc=1
      unlock
    else
      rc=1
    fi
  fi
  return "$rc"
}

run_family() {
  local fam="$1" param type sc mode=facts rc pass=0 fail=0 skip=0
  read -r param type LOGIN <<EOF
$(image_of "$fam")
EOF
  [ -z "${EC2_INSTANCE_TYPE:-}" ] || type="$EC2_INSTANCE_TYPE"
  mkdir -p "$ART/$fam${EC2_CREDITS:+-$EC2_CREDITS}"
  for sc in "${scenarios[@]}"; do
    run_vm "$fam" "$sc" "$mode" "$param" "$type"; rc=$?
    mode=quiet
    case "$rc" in
      0) pass=$((pass+1)) ;;
      3) skip=$((skip+1)) ;;
      *) fail=$((fail+1)) ;;
    esac
  done
  echo
  echo "run-ec2: $fam: $pass passed, $fail failed, $skip skipped." \
       "Facts: $ART/$fam${EC2_CREDITS:+-$EC2_CREDITS}/${scenarios[0]}/ai-discovery-out/facts.txt"
  [ "$fail" = 0 ]
}

fails=0
for fam in "${families[@]}"; do
  run_family "$fam" || fails=$((fails+1))
done
echo
echo "run-ec2: ${#families[@]} famil$([ ${#families[@]} = 1 ] && echo y || echo ies), $fails with failures."
exit "$fails"
