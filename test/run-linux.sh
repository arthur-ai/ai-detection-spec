#!/bin/bash
# Run the Linux scenarios locally, in throwaway containers.
#
#   test/run-linux.sh                 every linux scenario
#   test/run-linux.sh 73-linux-deb    one of them
#
# WHY A CONTAINER AND NOT A VM. test/run.sh uses Tart because a macOS guest needs
# Apple's hypervisor and a signed image. A Linux scenario needs neither: the CI jobs run
# these directly on a hosted ubuntu runner with no VM layer at all, so the only thing
# missing locally is a clean userland, which is what a container is.
#
# WHAT A CONTAINER CANNOT DO, and this is stated here rather than discovered: it has no
# PID 1 systemd and therefore no system bus, so 76-linux-systemd exits 3 (SKIP) here and
# runs for real in CI. That is a fact about the container. It is ALSO the exact state
# queries/runtime-linux.sql's kind=scan marker exists to report -- so running the suite
# here exercises the marker's `absent` branch, which the CI runner never will.
#
# Exit 3 from a setup.sh is SKIP, the same contract test/run.sh has always used.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

OSQUERY_VERSION="${OSQUERY_VERSION:-5.23.1}"
# Docker Hub is blocked daemon-side on some machines here, so the default is a mirror
# that is not. Override for a different base.
UBUNTU_IMAGE="${UBUNTU_IMAGE:-public.ecr.aws/ubuntu/ubuntu:24.04}"
FEDORA_IMAGE="${FEDORA_IMAGE:-registry.fedoraproject.org/fedora:41}"

command -v docker >/dev/null || { echo "run-linux: docker is required" >&2; exit 1; }
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=amd64 ;;
  *) echo "run-linux: unsupported host arch $(uname -m)" >&2; exit 1 ;;
esac

# The repo is mounted READ-WRITE for one reason: agent_status.py --record writes
# test/scenarios/<name>/observed.json, which is the whole output of a run. Nothing else in
# the tree is written by a scenario.
scenarios=("$@")
if [ ${#scenarios[@]} -eq 0 ]; then
  for d in "$HERE"/scenarios/*/; do
    n="$(basename "$d")"
    [ -f "$d/expected.json" ] || continue
    [ "$(python3 -c "import json;print(json.load(open('$d/expected.json')).get('platform'))")" = linux ] \
      || continue
    scenarios+=("$n")
  done
fi

pass=0 fail=0 skip=0
for s in "${scenarios[@]}"; do
  exp="$HERE/scenarios/$s/expected.json"
  [ -f "$exp" ] || { echo "run-linux: no such scenario: $s" >&2; fail=$((fail+1)); continue; }
  fam=$(python3 -c "
import json
d=json.load(open('$exp'))
print('fedora' if 'rpm' in d['description'].lower() or 'rpm' in '$s' else 'ubuntu')")
  echo
  echo "=============== $s ($fam)"
  if [ "$fam" = fedora ]; then
    image="$FEDORA_IMAGE"
    prep="dnf -q -y install curl python3 python3-pyyaml tar findutils >/dev/null 2>&1
          case \"$ARCH\" in arm64) R=aarch64 ;; *) R=x86_64 ;; esac
          curl -fsSLo /tmp/o.rpm https://pkg.osquery.io/rpm/osquery-$OSQUERY_VERSION-1.linux.\$R.rpm
          rpm -i --nodeps /tmp/o.rpm >/dev/null 2>&1"
  else
    image="$UBUNTU_IMAGE"
    prep="export DEBIAN_FRONTEND=noninteractive
          apt-get -qq update >/dev/null 2>&1
          apt-get -qq install -y curl ca-certificates python3 python3-yaml sudo >/dev/null 2>&1
          curl -fsSLo /tmp/o.deb https://pkg.osquery.io/deb/osquery_$OSQUERY_VERSION-1.linux_$ARCH.deb
          dpkg -i /tmp/o.deb >/dev/null 2>&1"
  fi

  docker run --rm -v "$ROOT:/repo" -w /repo "$image" bash -c "
set -uo pipefail
$prep
command -v osqueryi >/dev/null || { echo 'FAIL: osquery did not install'; exit 1; }

test/scenarios/$s/setup.sh
rc=\$?
[ \$rc = 3 ] && { echo 'SKIP: the scenario reported this environment cannot host it'; exit 3; }
[ \$rc = 0 ] || { echo \"FAIL: setup.sh exited \$rc\"; exit 1; }

osqueryi --json < dist/discovery-linux.sql > /tmp/out.json 2>/tmp/err.txt || {
  echo 'FAIL: the composed Linux artifact did not run'; cat /tmp/err.txt; exit 1; }
# stderr is printed rather than swallowed: systemd_units logs there and returns zero rows
# while the statement still exits 0, which is the failure the scan marker exists to name.
[ -s /tmp/err.txt ] && { echo '--- osquery stderr:'; sed 's/^/    /' /tmp/err.txt; }

test/assert.sh /tmp/out.json test/scenarios/$s/expected.json || exit 1

python3 tools/agent_status.py --record /tmp/out.json test/scenarios/$s \
  --platform linux \
  --os \"\$(. /etc/os-release && printf '%s' \"\${VERSION_ID:-unknown}\")\" \
  --arch \"\$(uname -m)\"
"
  rc=$?
  case "$rc" in
    0) echo "--- $s PASS"; pass=$((pass+1)) ;;
    3) echo "--- $s SKIP"; skip=$((skip+1)) ;;
    *) echo "--- $s FAIL"; fail=$((fail+1)) ;;
  esac
done

echo
echo "run-linux: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
