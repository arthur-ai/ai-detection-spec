# The container branch

An agent in a container is invisible to every other query here — no `.app` bundle, no
Homebrew entry, no npm global, no dotdir on the host. This is the only branch that sees it,
and it is opt-in because it is the only part of this that talks to a daemon.

```console
$ sudo bin/discover --deep | bin/classify     # base inventory plus containers
$ sudo bin/container-scan --pretty            # containers alone
```

It reads three things: **images** on disk, **containers** running from them, and the
**vendor labels** in each image's manifest. What each is worth as evidence differs, and the
table below says how.

## Why it is opt-in

`docker_images` has no timeout of its own, and against a daemon that accepts the connection
and never answers — Docker Desktop mid-startup, or installed and not opened today — the query
never returns. osquery offers no way to bound it, so the only bound is a kill on the process.

That is why the branch ships as its own artifact (`dist/discovery-deep.sql`) run by its own
process: bounded there, it costs the container rows; bounded inside the composed query it
costs six of the ten seconds and reports success anyway. `queries/COST.md` has the
measurements.

## Every outcome carries a reason

`bin/container-scan` reports which happened in its exit code — `0` scanned, `2` did not scan,
`3` asked and gave up, `1` could not run — and, on every outcome, in a `kind=scan` row.

That row is not decoration: an interrupted `osqueryi` exits 0 having printed a valid empty
array, so without it a wedged daemon and a machine with no containers produce the same value.
`bin/classify` prints it as `COULD NOT LOOK` above the findings.

## Three rows, three strengths of claim

The branch emits three kinds, and they are not interchangeable. A reader who treats them as
one number will over-trust the weakest.

| kind | route | what it means | who controls the value |
|---|---|---|---|
| `image` | `images` | the image is **pulled** | whoever ran `docker tag` |
| `container` | `container_images` | a container from it is **running** | whoever ran `docker tag` |
| `ilabel` | `image_labels` | the image's own manifest says whose it is | **the vendor** |

### An image name is weaker evidence than a bundle id

Image names resolve through the `images:` catalog route — exact match on the repository, tag
stripped, `docker.io/` and Docker Hub's implicit `library/` removed, registry host kept for
everything else.

**An image name is chosen by whoever tagged it**, which no other route here is true of:
`docker tag alpine paulgauthier/aider` produces an aider finding and nothing can tell it from
the real image. Read an image row accordingly.

### A vendor label is the one a retagger cannot forge

`org.opencontainers.image.source` is written by the vendor in their own Dockerfile and
travels in the image manifest. Retagging renames a local reference and adds no labels, so
this is the container equivalent of a bundle id.

**Only `source` is matched, and that is a measurement rather than a preference.** Across
eighteen real images on 2026-09-11, every image carrying `source` carried a correct vendor
URL — while `title`, `vendor` and `ref.name` are inherited from the base image and routinely
wrong. litellm's own image reports `title=wolfi-base`; `sweagent/swe-agent` reports
`ref.name=ubuntu` and nothing else. A route keyed on `title` would offer Ubuntu as an
agent's identity.

**Carrying a label is a fact about a project's release pipeline, not about being an agent.**
The currently published `ghcr.io/openhands/openhands` and `ghcr.io/block/goose` set `source`
properly; `paulgauthier/aider` sets **no labels at all**, and `sweagent/swe-agent` only its
base image's. Those two images are between seven months and two years old, which is the
pattern: modern pipelines inject OCI labels and abandoned ones never did. So this route
covers the agents a fleet is most likely to be running now and misses the stale ones —
which is why `images` stays beside it rather than being replaced by it.

### A running container says something no other route here can

Every other route in this repo — every one — reports **presence**: a bundle on disk, a
package in a manifest, a dotdir. `docker_containers` reports that something is **executing**.

Its `extra` carries the container's command, and that is corroboration the image name cannot
supply for itself: `docker tag alpine paulgauthier/aider` fakes the name and cannot make
`/venv/bin/aider` the thing that runs.

**It lists running containers only.** Measured 2026-09-11 on Docker 28.4.0: two exited
containers produced zero rows. So an agent that is installed but stopped appears as an
`image` and not as a `container`, and an empty container list is not an empty machine.

`perms` carries `privileged`, because a privileged agent container can reach the host and an
unprivileged one cannot. **Environment variables are never collected** — `env_variables` and
the whole `docker_container_envs` table hold `ANTHROPIC_API_KEY` and its like, and this
payload leaves the machine.

## Whether it is worth enabling

Container images are rare in this catalog — `catalog/agents.yaml`'s `images:` route lists
which agents carry one. So `--deep` earns its place on fleets that run agents in containers
and adds little elsewhere.

Docker itself is never required. A machine with no Docker reports `absent`, which is a stated
outcome rather than a failure.

## On Linux, where the socket is simpler and the blind spot is wider

`docker_images` is in osquery's `specs/posix`, so the SQL needs no change at all and
`dist/discovery-deep.sql` is one file for both platforms. What differs is the runner:

- **The socket is `/var/run/docker.sock` and that is usually the only candidate.** Docker
  Engine has no per-user socket, so the two Docker-Desktop-shaped paths
  `bin/container-scan` also probes simply never hit there.
- **Podman is not probed, and on Linux that costs more.** It is often the default there, and
  `/run/podman/podman.sock` would pass the health guard and then return **zero images**,
  because `docker_images` does not read Podman's image store at all. That is a manufactured
  "we looked", which is worse than a gap — so it is recorded as a gap in
  [the blind spots](agents.md) instead of probed.
- **A rootless Podman socket lives under `$XDG_RUNTIME_DIR`**, which the same argument
  covers.

So on a Podman host `--deep` reports `absent` and means it: there is no Docker socket. It is
not saying the machine has no containers, and nothing here can tell you whether it does.
