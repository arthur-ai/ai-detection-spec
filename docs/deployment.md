# Running it on a fleet

Everything here is about deploying the queries across machines you manage. The README
covers running them on one machine; this page is the part that only matters at fleet scale.

## Do not put these queries on a synchronous reporting path

`docker_images` has no timeout of its own, and against a daemon that accepts the connection
and never answers the query does not return — so anything that runs it while something waits
for the answer can hang rather than fail.

Run it on a schedule and read the result:

```console
# on a schedule, as root
$ bin/discover --write /var/lib/ai-discovery/inventory.json \
               --status /var/lib/ai-discovery/status.txt

# from wherever you collect, whenever you like
$ cat /var/lib/ai-discovery/inventory.json
$ cat /var/lib/ai-discovery/status.txt
```

Each branch runs in its own bounded process on the write path, which is a reliability choice:
one unavailable table costs one branch rather than the whole inventory. Composed into a single
statement it returns zero rows and a valid empty JSON array, which a consumer cannot tell from
a clean machine.

## `status.txt`, whose vocabulary is a contract

One line:

```
ok 2026-08-31T20:30:29Z rows=775 apps=ok browser=ok containers=ok filesystem=ok packages=ok runtime=ok
```

`ok`, `absent`, `unhealthy:<http-code>`, `timeout:<seconds>`, `error`, `no-cache`,
`stale:<seconds>`. Every payload also carries one dated `kind=scan` row per branch with the
same value, so a consumer that only has the JSON still knows which branches ran and when.

**Judge freshness on that timestamp, not the file's mtime** — redeploying a file resets the
mtime without changing the truth.

## The `python3` stub, which bites only on a fleet

On a Mac without Command Line Tools installed, `/usr/bin/python3` is a **stub**. The scheduled
writer produces nothing at all there, and that surfaces as `no-cache` rather than as an error.
Worth knowing before you read a fleet-wide `no-cache` as a fleet-wide absence of agents.

## What a deployment has to supply

This repo ships osquery materials: the queries, the runner, the guard and the bound. The parts
that belong to *your* management stack are deliberately not here, because they differ per
consumer and would rot in a public repo:

- **A schedule** — a launchd job, an MDM policy, cron.
- **Transport** — whatever moves the file to wherever you read it.
- **Framing**, if your channel has a size or encoding limit. Compressing the JSON is usually
  enough; on a reference Mac 121 KB of rows becomes about 19 KB.
- **Classification at scale.** `bin/classify` is the reference implementation and answers "what
  is on this Mac". For a fleet, collect the rows and match them where the catalog lives, so
  that adding a signature re-matches evidence you already hold instead of requiring a re-scan.

## Two things that are deliberately not prerequisites

**`curl`** is used in exactly one place — the Docker socket health probe inside
`bin/container-scan` — and `/usr/bin/curl` ships with macOS. Naming it as a prerequisite would
make the list look longer than it is without telling anyone anything they can act on.

**Docker** is a property of the machine you are scanning, not a dependency of the scanner. If a
Mac has no Docker, `bin/container-scan` finds no socket and reports `absent` — a stated
outcome, not a failure. See [containers.md](containers.md) for what the container branch buys
you and when it is worth enabling.
