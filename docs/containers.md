# The container branch

An agent in a container is invisible to every other query here — no `.app` bundle, no
Homebrew entry, no npm global, no dotdir on the host. This is the only branch that sees it,
and it is opt-in because it is the only part of this that talks to a daemon.

```console
$ sudo bin/discover --deep | bin/classify     # base inventory plus container images
$ sudo bin/container-scan --pretty            # containers alone
```

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

## An image name is weaker evidence than a bundle id

Image names resolve through the `images:` catalog route — exact match on the repository, tag
stripped, `docker.io/` and Docker Hub's implicit `library/` removed, registry host kept for
everything else.

**An image name is chosen by whoever tagged it**, which no other route here is true of:
`docker tag alpine paulgauthier/aider` produces an aider finding and nothing can tell it from
the real image. Read an image row accordingly.

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
