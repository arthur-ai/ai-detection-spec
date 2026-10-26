# The container branch

An agent in a container leaves nothing on the host that any other query reads. This branch
is the only one that sees it, and it is opt-in because it is the only one that talks to a
daemon.

```console
$ sudo osquery/bin/discover --deep | bin/classify    # base inventory plus containers
$ sudo osquery/bin/container-scan | bin/classify     # containers alone
```

It is worth enabling on fleets that run agents in containers; `catalog/agents.yaml`'s
`images:` and `image_labels:` routes list which agents ship one. Docker is never required: a
machine without it reports `absent`, or `unreadable:<runtime>` when another runtime is
installed, and both are stated outcomes rather than failures.

## Why it runs in its own process

`docker_images` has no timeout. Against a daemon that accepts the connection and never
answers, as Docker Desktop does while starting or when installed and not opened today, the
query never returns, and osquery has no flag to bound it. The only bound is a kill on the
process. So the branch ships as its own artifact, `osquery/dist/discovery-deep.sql`, and
`osquery/bin/container-scan` is the only supported way to run it. It wraps the query in two
things SQL cannot express:

- **A health guard**: one `/_ping` round trip that must return HTTP 200. Neither a socket
  test nor a bare connect is enough, and `curl -s` exits 0 on an HTTP 500.
- **A wall clock**, because a daemon can answer the ping and then stall on the query. A
  killed `osqueryi` prints a valid empty array and exits 0, so the output of a killed query
  is discarded, always.

Its header has the reasoning, and `osquery/test/docker_states.sh` asserts every daemon state
against a fake daemon, with no Docker installed. Timings are in
[COST.md](../queries/COST.md).

## A sleeping Docker is not a broken one

Docker Desktop's Resource Saver stops the VM after five idle minutes and holds the first
request while it resumes: 2.6s measured. The ping budget, `DOCKER_PING_TIMEOUT` or
`--timeout`, is therefore **8s**. It is a ceiling rather than a cost, since a daemon that
answers is read in about a tenth of a second, so only a daemon that never answers pays it. A
shorter budget reported `unhealthy:000` on every idle Mac, having woken it with the probe it
then rejected. A nap longer than 8s has not been measured.

## Every outcome carries a reason

The exit code says what happened: `0` scanned, `2` did not scan, `3` asked and gave up, `1`
could not run. So does stdout, which is all most inventory channels keep: every outcome
prints one `kind=scan` row with id `containers` and one of the spec's outcomes
([SPEC.md §5.2](../../SPEC.md#52-scan-markers)). Without that row a wedged daemon and a
machine with no containers produce the same value. `bin/classify` prints it as
`COULD NOT LOOK` above the findings.

The row does not promise a retry, because the schedule belongs to the deployment. Its `ver`
dates the scan, so a reader comparing two payloads can see whether the condition cleared.

## Three kinds of row, three strengths of claim

| kind | route | what it says | who controls the value |
|---|---|---|---|
| `image` | `images` | the image is **pulled** | whoever ran `docker tag` |
| `container` | `container_images` | a container from it is **running** | whoever ran `docker tag` |
| `ilabel` | `image_labels` | the image's own manifest names its source | **the vendor** |

- **An image name is the weakest identifier here.** `docker tag alpine paulgauthier/aider`
  produces an aider finding, and nothing can tell it from the real image. Names match after
  the normalisation in [SPEC.md §6.4.3](../../SPEC.md#643-exact-normalised).
- **A vendor label is the one a retagger cannot forge.** Only
  `org.opencontainers.image.source` is matched: `title`, `vendor` and `ref.name` are
  inherited from base images and routinely wrong. Current release pipelines set labels and
  old images often carry none, so `images` stays beside this route.
  `catalog/routes.yaml`'s `image_labels` entry has the measurements.
- **A running container is the one route that says something is executing.** Its `extra` is
  the container's command, which a retag cannot fake. It lists running containers only, so a
  stopped agent appears as an `image` and an empty container list is not an empty machine.
  `perms` carries `privileged`.

**Environment variables are never collected.** `env_variables` and `docker_container_envs`
hold API keys, and the row is written on the endpoint, so dropping the column downstream is
too late. `osquery/test/lint.sh` fails on either name.

## Linux

The SQL is the same, because `docker_images` is in osquery's `specs/posix`. What differs is
the runner. Docker Engine has one socket, `/var/run/docker.sock`. Podman, often the default
there, is **named rather than probed**: its socket would pass the health guard and then
return zero images, because `docker_images` does not read Podman's store. So a Podman host
reports `unreadable:podman`, meaning a runtime is installed that this scan does not read. It
does not mean the machine has no containers. The evidence is a socket or binary on disk and
nothing more, since asking Podman would add a dependency and a daemon conversation.
