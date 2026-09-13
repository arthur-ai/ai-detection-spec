-- name: containers
-- description: Container images, running containers and vendor labels, which hide agents every other branch misses
-- tables: docker_images, docker_containers, docker_image_labels
-- min-osquery: 5.10.0
-- cost: expensive
-- platform: posix
--
-- POSIX, not darwin: docker_images lives in osquery's specs/posix, so it exists on Linux
-- too and the composed deep artifact is one file for both platforms. The RUNNER is what
-- carries the platform-specific part -- bin/container-scan's socket candidates -- not the
-- SQL. Verified: the table is registered on Ubuntu 24.04 and Fedora 41.
--
-- Emits the six-column contract: kind, id, ver, loc, extra, perms.
--
-- `id` IS A LIST, and it is the only branch here where that is true. osquery returns ONE
-- row per image, and an image with several tags has them comma-joined into `tags` --
-- measured: "alpine:3.20,localbuild-probe:latest". Every `:latest` alongside a version tag
-- is such an image, so this is ordinary rather than exotic, and a consumer comparing `id`
-- whole matches none of the tags. bin/classify splits it in image_repos().
--
-- `loc` is the image ID: a bare 64-character hex digest, with no `sha256:` prefix (osquery
-- strips the one the Docker API sends). It is also the most expensive column in the payload
-- -- a digest does not compress -- at about 89 bytes per row framed. See queries/COST.md.
-- Branches within this file are joined with UNION ALL, and the build joins files
-- the same way. See CONTRIBUTING.md before changing the column list.

-- An agent in a container is invisible to every other query here: no .app bundle, no
-- Homebrew entry, no npm global, no dotdir on the host. This is the only branch that
-- sees it.
--
-- MARKED expensive, SO IT IS NOT IN THE COMPOSED ARTIFACTS. The build composes it into
-- dist/discovery-deep.sql, which bin/container-scan runs in a process of its own, behind a
-- round-trip health check and a wall-clock kill. bin/discover --deep is that plus the base
-- inventory. The reason is that this table's cost is not bounded by anything we control:
--
--   Docker state                          osquery cost      bin/container-scan
--   no socket file                        0.49s  fails fast   skips,   exit 2, 0.18s
--   stale socket, nothing listening       0.36s  refused      skips,   exit 2, 0.19s
--   socket accepts, daemon never replies  >45s   UNBOUNDED    skips,   exit 2, 0.19s
--   daemon answers 500                    0.45s  zero rows    skips,   exit 2, 0.20s
--   pings 200, then never serves          >45s   UNBOUNDED    KILLED,  exit 3, 7.36s
--   daemon healthy                        0.44s  rows         scans,   exit 0, 0.51s
--
-- The unbounded rows are what matter, and they are worse than previously recorded. The
-- figure in the ticket was 10.4s, measured against real Docker Desktop -- but that
-- ceiling is Docker's own socket layer giving up, not osquery's. The table has NO
-- timeout of its own, so against a daemon that simply holds the connection, this query
-- does not finish.
--
-- A ten-second collection budget was never the constraint. Unbounded was. So the
-- constraint moved out of the SQL, which cannot express one, and into the runner, which
-- can: osquery offers no flag to bound a query (5.23.1 -- --docker_socket is the only
-- docker flag, --alarm_timeout is shutdown-only with a 10s floor, --schedule_timeout is
-- osqueryd's schedule), and the only bound that exists on the machines this runs on is a
-- kill on the process.
--
-- THIS FILE IS STILL `expensive` AND STILL MUST NOT REACH A COMPOSED ARTIFACT. A kill
-- belongs to a process, and there is no process to bound when this SQL is one arm of a
-- UNION ALL inside somebody else's query: bounding it there discards the 750-odd rows the
-- other branches have already produced. Re-declaring it `slow` would fold it into the
-- composed file, where nothing bounds it and one wedged daemon blanks the whole inventory.
--
-- That state is not exotic. It is Docker Desktop mid-startup, and Docker Desktop
-- installed-but-not-running, which is the ordinary condition of a developer Mac that
-- has not opened Docker today.
--
-- THE GUARD MUST BE A FULL ROUND TRIP, AND MUST CHECK THE STATUS CODE -- AND THAT IS
-- STILL NOT ENOUGH. Measured, per state, on whether each guard lets this branch run:
--
--                       absent  refuse  hang   error  wedge   healthy
--   connect() only      skip    skip    RUN    RUN    RUN     RUN     <- stalls forever
--   curl -s             skip    skip    skip   RUN    RUN     RUN     <- silent zero rows
--   HTTP 200 required   skip    skip    skip   skip   RUN     RUN     <- still stalls
--   200 + wall clock    skip    skip    skip   skip   KILLED  RUN     <- correct
--
-- connect() is wrong because osquery blocks on the READ, not the connect: the probe
-- succeeds in 0.000s against a daemon that never answers. `curl -s` is wrong because it
-- exits 0 on an HTTP 500, and a 500 daemon yields zero rows -- which is indistinguishable
-- from a machine with no containers, and is the silent failure this project keeps
-- meeting. Only requiring a 200 separates "nothing there" from "we could not look".
--
-- A HEALTH CHECK IS NECESSARY AND IT IS NOT SUFFICIENT. `wedge` -- 200 on /_ping, silence
-- on /images/json -- passes every probe in that table. It is Docker Desktop with a live
-- API and an engine that is not serving, which is the ordinary condition of a Mac that is
-- starting Docker, and the window between the probe and the query is small but not zero.
-- The guard closes four states of six. The wall-clock kill closes the fifth.
--
-- And the kill cannot trust what it killed -- for two different reasons now, depending on
-- which arms are in the statement. Both measured on 5.23.1:
--
--   docker_images alone        SIGTERM ends it, it exits **0**, and it prints "[\n\n]\n" --
--                              a valid, parseable, EMPTY JSON array. A wrapper reading the
--                              child's exit code and stdout reports a Mac with no
--                              containers about a daemon that never sent a byte.
--   with either arm below      SIGTERM IS IGNORED. Only SIGKILL ends it, wait status 137,
--                              and the output is zero bytes.
--
-- The first is a plausible lie and the second is a hang, and bin/container-scan is immune
-- to both for the same reason: it discards the output because IT fired the kill, and for no
-- other reason, and it escalates to SIGKILL on a deadline. Neither behaviour is inspected.
-- test/docker_states.sh asserts both, and CLAUDE.md's "the kill decides, not the child" is
-- exactly this.
--
-- test/docker_states.sh asserts every row of both tables above, with no Docker installed,
-- against test/lib/fake_docker.py.
--
-- Whoever simplifies this back to `test -S /var/run/docker.sock` will reintroduce an
-- unbounded stall on the most common state, and nothing will error.
SELECT 'image' AS kind, tags AS id, '' AS ver, id AS loc,
       CAST(size_bytes AS TEXT) AS extra, '' AS perms
  FROM docker_images

UNION ALL

-- RUNNING CONTAINERS, which is a different question from the one above and the only place
-- in this repo that answers it. Every other route reports PRESENCE: a bundle on disk, a
-- package in a manifest, a dotdir. This reports that something is executing right now.
--
-- RUNNING ONLY. Measured 2026-09-11 on Docker 28.4.0: two exited containers produced ZERO
-- rows here, because osquery reads /containers/json without `all=1`. So this never
-- replaces the image branch -- an agent that is installed but stopped appears there and
-- not here -- and a reader must not take an empty container list for an empty machine.
--
-- `image` carries the FULL TAG, verified on that host ("paulgauthier/aider:latest"), so
-- bin/classify's image_repo() normalises it exactly as it does a docker_images tag. That
-- is why the catalog needs no second list of names for this route.
--
-- `extra` is the COMMAND, and it is the point of the branch beyond liveness. An image name
-- is chosen by whoever tagged it, but what a container actually runs is not cosmetic in the
-- same way, so `docker tag alpine paulgauthier/aider` fakes the name and cannot fake
-- `/venv/bin/aider`. It is corroboration the `images` route cannot supply for itself.
--
-- `perms` carries `privileged` because it is a capability fact, in the column this
-- contract already reserves for capability facts. A privileged agent container can reach
-- the host, and an unprivileged one cannot. env_variables is NOT selected here and must never
-- be: it holds ANTHROPIC_API_KEY and its like, and this payload leaves the machine.
SELECT 'container' AS kind, c.image AS id, c.state AS ver, c.id AS loc,
       c.command AS extra,
       CASE WHEN c.privileged = 1 THEN 'privileged' ELSE '' END AS perms
  FROM docker_containers c

UNION ALL

-- OCI LABELS, AND ONLY `source`. A label is written by the vendor in their own Dockerfile
-- and travels in the manifest, which makes it the one container identifier a retagger does
-- not control -- catalog/routes.yaml's `image_labels` entry carries the reasoning and the
-- measurements.
--
-- WHY ONLY `source`. Measured across thirteen real images on 2026-09-11: `title`, `vendor`
-- and `ref.name` are INHERITED FROM THE BASE IMAGE and routinely wrong -- litellm reports
-- title=wolfi-base, sweagent/swe-agent reports ref.name=ubuntu and nothing else. Emitting
-- those would put "ubuntu" forward as an agent's identity. `source` was correct on every
-- image that carried one, so it is the only key worth a row.
--
-- NO CATALOG LIVES HERE. Selecting one label key is choosing a FIELD, the way the apps
-- query chooses bundle_identifier -- it names no agent, and tools/check_no_catalog.py
-- still passes. The rows are evidence whether or not anything claims them.
SELECT 'ilabel' AS kind, l.value AS id, '' AS ver, l.id AS loc,
       l.key AS extra, '' AS perms
  FROM docker_image_labels l
 WHERE l.key = 'org.opencontainers.image.source'
