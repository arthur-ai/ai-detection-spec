#!/bin/bash
# Run the Linux scenarios in throwaway containers, locally and in CI.
#
#   test/run-linux.sh                              every linux scenario, on the default image
#   test/run-linux.sh 73-linux-deb                 one of them
#   test/run-linux.sh --list                       the names the first form would run
#   LINUX_IMAGE=quay.io/rockylinux/rockylinux:9 test/run-linux.sh   the same, on another image
#
# WHY A CONTAINER AND NOT A VM. test/run.sh uses Tart because a macOS guest needs
# Apple's hypervisor and a signed image. A Linux scenario needs neither: the ubuntu CI job
# runs scenarios directly on a hosted runner with no VM layer at all, so the only thing
# missing is a clean userland, which is what a container is.
#
# THIS IS ALSO HOW CI RUNS THE OTHER FAMILIES. scenarios.yml's container job calls this
# script once per image with the scenarios the scope job selected, instead of one GitHub
# job per (scenario, image): 76 jobs became four, each container is still a clean host,
# and the organisation's concurrent-job cap stops deciding how long the suite takes. That
# job declares `env: SCENARIO_PLATFORM: linux`, which is how tools/ci_scope.py knows it
# runs every Linux scenario on disk -- the same enumeration `--list` prints, and
# test/test_ci_scope.py holds the two together.
#
# WHAT A CONTAINER CANNOT DO, and this is stated here rather than discovered: it has no
# PID 1 systemd and therefore no system bus, so 76-linux-systemd exits 3 (SKIP) here and
# runs for real on the ubuntu CI job. That is a fact about the container. It is ALSO the
# exact state osquery/queries/runtime-linux.sql's kind=scan marker exists to report -- so running
# the suite here exercises the marker's `absent` branch, which the ubuntu runner never
# will. test/run-gce.sh is the path that has systemd, a real boot and OS Login.
#
# THE IMAGE IS AN AXIS, AND THE FAMILY IS READ INSIDE THE CONTAINER. This used to pick
# Fedora when `rpm` appeared in the scenario's name and Ubuntu otherwise, which decided
# the family from a filename and could never run a scenario on a second image. Now the
# image is whatever LINUX_IMAGE says, the prep asks the container whether it has apt-get
# or dnf, and a scenario that cannot run on the family it landed on says so itself with
# exit 3 -- 74 wants dpkg, 77 wants rpm. scenarios.yml runs the same images in CI.
#
# Exit 3 from a setup.sh is SKIP, the same contract test/run.sh has always used.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Every scenario whose expected.json declares linux. tools/ci_scope.py's tree_scenarios
# enumerates the same directories the same way, and test/test_ci_scope.py compares the two.
linux_scenarios() {
  local d n
  for d in "$HERE"/scenarios/*/; do
    n="$(basename "$d")"
    [ -f "$d/expected.json" ] || continue
    [ "$(python3 -c "import json;print(json.load(open('$d/expected.json')).get('platform'))")" = linux ] \
      || continue
    printf '%s\n' "$n"
  done
}
# --list answers before the docker check, so a host without docker can still ask.
if [ "${1:-}" = --list ]; then linux_scenarios; exit 0; fi

OSQUERY_VERSION="${OSQUERY_VERSION:-5.23.1}"
# Docker Hub is blocked daemon-side on some machines here, so the default is a mirror
# that is not. The other images this is run against are the GCE families and the rpm
# control: debian:12, quay.io/rockylinux/rockylinux:9, fedora:41 and amazonlinux:2023 --
# the same four scenarios.yml runs. Docker Hub's own `rockylinux:9` stopped at 9.3; the
# Rocky project's repository on quay.io tracks the current point release.
LINUX_IMAGE="${LINUX_IMAGE:-public.ecr.aws/ubuntu/ubuntu:24.04}"
# Extra `docker run` flags. LINUX_DOCKER_ARGS='--cap-add SYS_PTRACE' gives root in the
# container the right root has on a host to read another user's executable path, which
# 83-linux-claude-running needs and skips without.
LINUX_DOCKER_ARGS="${LINUX_DOCKER_ARGS:-}"
# Where CI collects what this run recorded: one observed-<scenario>--<label>/observed.json
# per scenario that PASSED, copied out of the tree after its container exits. Only what
# this run proved goes there: uploading every committed observed.json would make the
# collect job count scenarios that never ran as reported. Unset locally; the tree is the
# record.
OBSERVED_OUT="${OBSERVED_OUT:-}"
OBSERVED_LABEL="${OBSERVED_LABEL:-$(printf '%s' "$LINUX_IMAGE" | tr '/:' '__')}"

command -v docker >/dev/null || { echo "run-linux: docker is required" >&2; exit 1; }
case "$(uname -m)" in
  arm64|aarch64) DEB_ARCH=arm64 RPM_ARCH=aarch64 ;;
  x86_64|amd64)  DEB_ARCH=amd64 RPM_ARCH=x86_64 ;;
  *) echo "run-linux: unsupported host arch $(uname -m)" >&2; exit 1 ;;
esac

# The repo is mounted READ-WRITE for one reason: agent_status.py --record writes
# test/scenarios/<name>/observed.json, which is the whole output of a run. Nothing else in
# the tree is written by a scenario.
scenarios=("$@")
if [ ${#scenarios[@]} -eq 0 ]; then
  while IFS= read -r n; do scenarios+=("$n"); done < <(linux_scenarios)
fi

# What every scenario needs before setup.sh runs: osquery, python3 with yaml for the
# assertions, curl for the downloads, and sudo so sudo_maybe has something to call on an
# image that ships without it. The output is kept and printed only on failure, because a
# prep that fails behind >/dev/null leaves "osquery did not install" as the whole story.
# The same retry flags as the workflow's own downloads: curl's --retry alone does not
# retry a connect failure, which is how the osquery download failed three cells on
# 2026-10-20.
prep='
log=/tmp/prep.log
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  { apt-get -qq update && apt-get -qq install -y curl ca-certificates python3 python3-yaml sudo procps
    curl --retry 3 --retry-all-errors --retry-delay 5 -fsSLo /tmp/o.deb https://pkg.osquery.io/deb/osquery_'"$OSQUERY_VERSION"'-1.linux_'"$DEB_ARCH"'.deb
    dpkg -i /tmp/o.deb; } >"$log" 2>&1
elif command -v dnf >/dev/null 2>&1; then
  # --allowerasing: Rocky ships curl-minimal, which conflicts with curl, and dnf then
  # fails the WHOLE transaction -- pyyaml included -- while osquery still installs, so the
  # run died at the first assertion with a message about PyYAML rather than about curl.
  # gzip by name: amazonlinux:2023 ships tar without it, so a scenario that unpacks a
  # .tar.gz fails in its setup.
  { dnf -q -y install --allowerasing curl python3 python3-pyyaml tar gzip findutils procps-ng
    curl --retry 3 --retry-all-errors --retry-delay 5 -fsSLo /tmp/o.rpm https://pkg.osquery.io/rpm/osquery-'"$OSQUERY_VERSION"'-1.linux.'"$RPM_ARCH"'.rpm
    dnf -q -y install /tmp/o.rpm; } >"$log" 2>&1
else
  echo "FAIL: neither apt-get nor dnf in this image"; exit 1
fi
command -v osqueryi >/dev/null || { echo "FAIL: osquery did not install"; cat "$log"; exit 1; }
rm -f /tmp/o.deb /tmp/o.rpm
'

# ONE PREP PER IMAGE PER RUN, NOT ONE PER SCENARIO. The prep ran inside every scenario's
# container -- a package transaction and an osquery download each time, nineteen times per
# image in CI -- so it runs once here and the result is committed as the image every
# scenario starts from. Tagged with this shell's pid so two runs on one machine do not
# share a tag, and removed on exit; the next run rebuilds it from the base image.
prepped="ai-discovery-prep:$(printf '%s' "$LINUX_IMAGE" | tr '/:' '__')-$$"
# LINUX_DOCKER_ARGS is a list of flags, split on purpose.
# shellcheck disable=SC2086
cid="$(docker create $LINUX_DOCKER_ARGS "$LINUX_IMAGE" bash -c "$prep")" \
  || { echo "run-linux: could not create a container from $LINUX_IMAGE" >&2; exit 1; }
cleanup() { docker rm -f "$cid" >/dev/null 2>&1; docker rmi -f "$prepped" >/dev/null 2>&1; }
trap cleanup EXIT
echo "=============== preparing $LINUX_IMAGE"
docker start -a "$cid" || { echo "run-linux: prep failed on $LINUX_IMAGE" >&2; exit 1; }
docker commit "$cid" "$prepped" >/dev/null \
  || { echo "run-linux: could not commit the prepared image" >&2; exit 1; }

# Under GitHub Actions each scenario's output folds into a group and the verdict goes to
# the step summary, so a red job names its scenario without a scroll.
in_actions() { [ -n "${GITHUB_ACTIONS:-}" ]; }
note() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf -- '- %s: %s\n' "$1" "$2" >> "$GITHUB_STEP_SUMMARY"; return 0; }
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '### %s\n\n' "$LINUX_IMAGE" >> "$GITHUB_STEP_SUMMARY"
stage() {
  [ -n "$OBSERVED_OUT" ] || return 0
  # record() writes the file on every run that reaches it, so a missing one here is a
  # failure, not a scenario with nothing to say.
  local dst="$OBSERVED_OUT/observed-$1--$OBSERVED_LABEL"
  mkdir -p "$dst" && cp "$HERE/scenarios/$1/observed.json" "$dst/observed.json"
}

pass=0 fail=0 skip=0
for s in "${scenarios[@]}"; do
  exp="$HERE/scenarios/$s/expected.json"
  [ -f "$exp" ] || { echo "run-linux: no such scenario: $s" >&2; fail=$((fail+1)); continue; }
  if in_actions; then echo "::group::$s"; else echo; echo "=============== $s ($LINUX_IMAGE)"; fi

  # LINUX_DOCKER_ARGS is a list of flags, split on purpose.
  # shellcheck disable=SC2086
  docker run --rm $LINUX_DOCKER_ARGS -v "$ROOT:/repo" -w /repo "$prepped" bash -c "
set -uo pipefail
test/scenarios/$s/setup.sh
rc=\$?
[ \$rc = 3 ] && { echo 'SKIP: the scenario reported this environment cannot host it'; exit 3; }
[ \$rc = 0 ] || { echo \"FAIL: setup.sh exited \$rc\"; exit 1; }

# THE SAME CHOICE CI MAKES, read from the same field. A \`deep: true\` scenario asserts on
# an \`image\` row, which only osquery/dist/discovery-deep.sql produces -- run the composed artifact
# for one and it fails on a row count instead of saying the artifact was wrong. In this
# container the deep scenarios exit 3 before reaching here, because there is no daemon;
# the branch is what keeps a local run with a mounted socket honest.
if python3 -c \"import json,sys;sys.exit(0 if json.load(open('test/scenarios/$s/expected.json')).get('deep') else 1)\"; then
  osquery/bin/discover --deep > /tmp/out.json 2>/tmp/err.txt || {
    echo 'FAIL: the deep path did not run'; cat /tmp/err.txt; exit 1; }
else
  osqueryi --json < osquery/dist/discovery-linux.sql > /tmp/out.json 2>/tmp/err.txt || {
    echo 'FAIL: the composed Linux artifact did not run'; cat /tmp/err.txt; exit 1; }
fi
# stderr is printed rather than swallowed: systemd_units logs there and returns zero rows
# while the statement still exits 0, which is the failure the scan marker exists to name.
[ -s /tmp/err.txt ] && { echo '--- osquery stderr:'; sed 's/^/    /' /tmp/err.txt; }

test/assert.sh /tmp/out.json test/scenarios/$s/expected.json || exit 1

# --os carries the DISTRO, not only its release number: \`12\` is Debian to nobody who
# does not already know, and the whole point of a second image is that the record says
# which one proved the identifier. The same expression runs in scenarios.yml. --run-id is
# the GitHub run when there is one, which is what lets a proof outlive the run; locally
# it is empty and the record carries no run.
python3 tools/agent_status.py --record /tmp/out.json test/scenarios/$s \
  --platform linux \
  --os \"\$(. /etc/os-release && printf '%s-%s' \"\${ID:-linux}\" \"\${VERSION_ID:-unknown}\")\" \
  --arch \"\$(uname -m)\" --run-id '${GITHUB_RUN_ID:-}'
"
  rc=$?
  in_actions && echo "::endgroup::"
  case "$rc" in
    0) # A PASS WHOSE EVIDENCE DID NOT STAGE IS NOT A PASS. Nothing would be uploaded,
       # collect would count the scenario pending rather than reported, and the coverage
       # gate would let the run through without the proof it just produced.
       if stage "$s"; then
         echo "--- $s PASS"; pass=$((pass+1)); note "$s" PASS
       else
         echo "--- $s FAIL: passed, but its observation could not be staged for upload"
         fail=$((fail+1)); note "$s" "FAIL (observation not staged)"
         in_actions && echo "::error title=$s on $LINUX_IMAGE::$s passed but its observed.json could not be staged for upload"
       fi ;;
    3) echo "--- $s SKIP"; skip=$((skip+1)); note "$s" SKIP ;;
    *) echo "--- $s FAIL (exit $rc)"; fail=$((fail+1)); note "$s" "FAIL (exit $rc)"
       # An annotation names the scenario on the job page and in the checks tab, so a
       # red job says which of its scenarios failed without the log being opened.
       in_actions && echo "::error title=$s on $LINUX_IMAGE::$s failed (exit $rc); its log is the group named $s" ;;
  esac
done

echo
echo "run-linux: $pass passed, $fail failed, $skip skipped on $LINUX_IMAGE"
[ "$fail" = 0 ] || exit 1
