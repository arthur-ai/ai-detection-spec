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
array, so without it a wedged daemon and a Mac with no containers produce the same value.
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

Docker itself is never required. A Mac with no Docker reports `absent`, which is a stated
outcome rather than a failure.
