#!/bin/bash
# THE ONE SCENARIO THAT PULLS A REAL CONTAINER IMAGE, and it exists because
# `paulgauthier/aider` was the last identifier in the catalog whose evidence was a captured
# row rather than a live install.
#
# WHY IT NEEDED A SCENARIO OF ITS OWN. containers.sql is `cost: expensive`, so it is
# deliberately absent from osquery/dist/discovery-linux.sql -- which is the artifact every other
# scenario asserts against. No amount of installing could make an `image` row appear there.
# So this scenario asserts against `osquery/bin/discover --deep`, the only supported way to run the
# deep artifact, declared by `"deep": true` in expected.json.
#
# WHAT osquery/test/docker_states.sh DOES NOT COVER. That suite serves captured images through a
# fake socket and is the better test of the RUNNER -- every daemon state, the guard, the
# bound. What it cannot prove is that the catalogued name is still the name Docker Hub
# serves today. A pull is the only thing that proves that, and it is the same class of
# claim as `aider-chat` versus `aider`: a name read off a vendor page and never fetched is
# a guess with a comment beside it.
set -e
source "$(cd "$(dirname "$0")/../../lib" && pwd)/guest-linux.sh"

command -v docker >/dev/null 2>&1 || {
  echo "SKIP: no docker client. This is a FACT ABOUT THE RUNNER: a hosted ubuntu-24.04"
  echo "      ships a running daemon, and test/run-linux.sh's container does not."
  exit 3
}
docker info >/dev/null 2>&1 || { echo "SKIP: docker client present, no reachable daemon"; exit 3; }

# THE PULL IS THE INSTALL. Not `docker save`/`load` of something built here: the point is
# that the registry still serves this repository under this name.
#
# A RATE LIMIT IS A SKIP, NOT A FAILURE. Anonymous Docker Hub pulls are limited per source
# IP and hosted runners share addresses, so this can fail for a reason nobody in this repo
# can act on -- and a suite that goes red for that trains people to ignore it. Any OTHER
# pull failure is a real failure: a moved or renamed repository is exactly what this
# scenario is for, and swallowing it would restore the silence it was written to remove.
out="$(docker pull paulgauthier/aider:latest 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ]; then
  printf '%s\n' "$out" | tail -3
  case "$out" in
    *toomanyrequests*|*"rate limit"*|*"too many requests"*)
      echo "SKIP: Docker Hub rate-limited this runner's IP"; exit 3 ;;
    *) echo "FAIL: the pull failed for a reason this repo must answer for"; exit 1 ;;
  esac
fi
echo "--- pulled:"; docker image inspect paulgauthier/aider:latest --format '{{.RepoTags}} {{.Id}}'

# THE NEGATIVE CONTROLS, and they need a SEPARATE IMAGE ID to mean anything.
#
# docker_images returns ONE ROW PER IMAGE ID with the tags COMMA-JOINED, which bin/classify
# splits in image_repos(). Tagging the aider image itself would therefore put the fork name
# and the real name in the SAME row, and a row that matched would prove nothing about which
# name matched. Measured while writing this: alias tags produced the single row
# `paulgauthier/aider-fork:latest,paulgauthier/aider:latest`.
#
# `paulgauthier/aider-fork` is the load-bearing one: it has `paulgauthier/aider` as a
# PREFIX, so it is the assertion that the route compares whole repository names rather than
# substrings. `aider2` is the same test one character cheaper.
try "a small unrelated image to carry the control tags" \
  docker pull alpine:3.20 || { echo "SKIP: could not pull the control image"; exit 3; }
docker tag alpine:3.20 paulgauthier/aider-fork:latest
docker tag alpine:3.20 paulgauthier/aider2:latest
echo "--- controls (one row, distinct id from aider):"
docker image inspect alpine:3.20 --format '{{.RepoTags}}'

# --- THE REST OF THE CONTAINER-ROUTE CATALOG ------------------------------------------
#
# THIS COSTS CI TIME AND THE TRADE IS DELIBERATE. These four images are ~5.7GB on top of
# aider's 5.8GB, which roughly doubles this scenario's pull. The alternative was to
# catalogue the names off a registry manifest and never fetch them, and that is the exact
# shape of claim this repo has been wrong about twice -- `bot.molt.mac` and npm `aider`.
# A signature nothing pulls is a guess with a comment beside it. Trim this list by
# REMOVING SIGNATURES, never by leaving a signature untested.
#
# EACH PULL IS INDIVIDUALLY OPTIONAL, because one registry having a bad day must not lose
# the other three. `try` reports and continues; the assertions below decide what was
# actually proved, and expected.json holds the agents to `>=` rather than exact counts.
for repo in \
  ghcr.io/openhands/openhands:latest \
  ghcr.io/all-hands-ai/openhands:latest \
  ghcr.io/block/goose:latest \
  sweagent/swe-agent:latest
do
  try "pull $repo" docker pull "$repo" || echo "  (continuing -- one registry is not the suite)"
done
echo "--- pulled agent images:"
docker images --format '  {{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' \
  | grep -Ei 'openhands|goose|swe-agent|aider' || true

# --- A RUNNING CONTAINER, which is a different row and a different claim ---------------
#
# The container route sees running containers only (osquery/queries/containers.sql says
# why). So an image pull alone can never exercise
# the `container_images` route, and without this the whole branch would be dead code that
# lint could not see.
#
# goose because it is the smallest catalogued agent image (455MB), and `sleep` because the
# point is to make the daemon report a RUNNING container from a catalogued image, not to
# run an agent that would want credentials and a model endpoint. The row's `extra` carries
# the command, so the output records plainly that this is a probe rather than a real agent
# session -- see osquery/docs/containers.md on why the command is corroboration and not identity.
if docker image inspect ghcr.io/block/goose:latest >/dev/null 2>&1; then
  docker rm -f goose-probe >/dev/null 2>&1 || true
  try "run a catalogued agent image as a container" \
    docker run -d --name goose-probe --entrypoint sleep ghcr.io/block/goose:latest 600
  # THE NEGATIVE CONTROL FOR THE CONTAINER ROUTE, and it needs to be a running container
  # rather than another tag: `paulgauthier/aider-fork` already proves the IMAGE route
  # compares whole repository names, and this proves the container route does too. Without
  # it, a container route that matched on a prefix would pass every assertion here.
  docker rm -f impostor-probe >/dev/null 2>&1 || true
  try "run the near-miss tag as a container, which must NOT be claimed" \
    docker run -d --name impostor-probe --entrypoint sleep paulgauthier/aider-fork:latest 600
  echo "--- running containers:"
  docker ps --format '  {{.Names}} {{.Image}} {{.Status}}'
else
  echo "  goose image absent, so no container probe -- the container assertions will not be met"
fi
