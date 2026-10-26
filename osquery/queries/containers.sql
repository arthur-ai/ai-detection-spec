-- name: containers
-- description: Container images, running containers and vendor labels, which hide agents every other branch misses
-- tables: docker_images, docker_containers, docker_image_labels
-- min-osquery: 5.10.0
-- cost: expensive
-- platform: posix
--
-- An agent in a container leaves nothing on the host that another branch reads.
--
-- EXPENSIVE, AND IT MUST NEVER REACH A COMPOSED ARTIFACT. docker_images has no timeout of
-- its own: against a daemon that accepts the connection and never answers -- Docker Desktop
-- starting, or installed and not opened today -- this query does not finish, and osquery has
-- no flag to bound it. A bound is a kill on a process, so this ships in
-- dist/discovery-deep.sql and only bin/container-scan runs it, behind a health guard and a
-- wall clock. That file says why each is needed, and test/docker_states.sh asserts every
-- daemon state against test/lib/fake_docker.py. As one arm of a composed query, a wedged
-- daemon would hang or blank the whole inventory.
--
-- posix: the table is in osquery's specs/posix. What differs by platform is the socket,
-- and bin/container-scan owns the candidates.
--
-- Six columns: kind, id, ver, loc, extra, perms. See CONTRIBUTING.md before changing them.
--
-- `id` IS A TAG LIST: one row per image, its tags comma-joined
-- ("alpine:3.20,localbuild-probe:latest"), so a consumer comparing `id` whole matches none of
-- them. The exact-normalised match mode splits it (SPEC.md 6.4.3). `loc` is the image id, a
-- bare 64-hex digest and the costliest column in the payload (queries/COST.md).
SELECT 'image' AS kind, tags AS id, '' AS ver, id AS loc,
       CAST(size_bytes AS TEXT) AS extra, '' AS perms
  FROM docker_images

UNION ALL

-- RUNNING CONTAINERS: the one route that says something is executing. osquery reads
-- /containers/json without all=1, which also lists paused and restarting containers, so
-- the state is filtered here and the `running` claim is exact. Any other agent container is
-- still found by its image. No version is recorded, so `ver` is empty (SPEC.md 5.1). `id`
-- is the full tag, normalised like an image's, so the container_images route reads
-- `images:` values.
--
-- `extra` is the command, which a retag cannot fake: `docker tag alpine paulgauthier/aider`
-- fakes the name, not `/venv/bin/aider`. `perms` carries `privileged`, a capability fact.
-- env_variables is never selected: it holds API keys and this payload leaves the machine.
-- test/lint.sh fails on the name outside comments, here, in dist/ and in the pack.
SELECT 'container' AS kind, c.image AS id, '' AS ver, c.id AS loc,
       c.command AS extra,
       CASE WHEN c.privileged = 1 THEN 'privileged' ELSE '' END AS perms
  FROM docker_containers c
 WHERE c.state = 'running'

UNION ALL

-- OCI LABELS, `source` ONLY: the vendor writes it and it travels in the manifest, so a
-- retagger cannot forge it, while `title`, `vendor` and `ref.name` are inherited from base
-- images. catalog/routes.yaml's image_labels entry has the measurements. Choosing a key is
-- choosing a field, as apps.sql chooses bundle_identifier: it names no agent.
SELECT 'ilabel' AS kind, l.value AS id, '' AS ver, l.id AS loc,
       l.key AS extra, '' AS perms
  FROM docker_image_labels l
 WHERE l.key = 'org.opencontainers.image.source'
