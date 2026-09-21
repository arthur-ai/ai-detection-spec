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

**`cat` is the integration, and it is the one to reach for.** `bin/discover --cache` does the
same thing with a parse check in front of it, so a half-written file is caught rather than
forwarded as a machine that reported nothing — but the parser is `osqueryi`, and a collector
that has no osquery on it should just read the file. That is what the payload is shaped for.

Each branch runs in its own bounded process on the write path, which is a reliability choice:
one unavailable table costs one branch rather than the whole inventory. Composed into a single
statement it returns zero rows and a valid empty JSON array, which a consumer cannot tell from
a clean machine.

## One file, when your platform can host a script and not a package

A release attaches nine loose files, and they only work in the layout this repo has:
`bin/container-scan` resolves `dist/discovery-deep.sql` relative to its own parent, and
`bin/discover` sources `bin/container-scan`. Putting files in a fixed place on a managed
machine is the part a management platform is worst at — it wants a package, which on macOS
wants code signing, notarization and a PPPC profile. Hosting a script and running it on a
schedule is the part every one of them does well.

So: the layout, inside one script.

```console
$ python3 tools/bundle.py --platform darwin        # or download it from the release
wrote artifacts/ai-discovery-darwin.sh (37 KB, 5 files, darwin)

$ ./artifacts/ai-discovery-darwin.sh --write /var/lib/ai-discovery/inventory.json \
                                    --status /var/lib/ai-discovery/status.txt
```

Every argument goes straight through to `bin/discover`, so everything on this page works
unchanged. **It installs nothing**: the payload is extracted to a private temp directory,
run, and removed — including when the run fails, and including when it is interrupted.

**It costs two prerequisites: `base64` and `tar`.** `bin/discover` and `bin/container-scan`
hold to a closed list of utilities so that what an endpoint needs is what a stock machine
has, and the extraction preamble adds those two to it. Both are stock on macOS and on every
Linux base image this repo has run on, and the cost is opt-in — unpacking `bin/` and `dist/`
yourself needs neither — but it is a real widening rather than a detail.

**One platform per bundle, and each refuses the other by name.** The composed artifacts name
disjoint sets of tables and `bin/discover` picks by `uname -s`, so a bundle claiming both
would be tested on whichever one built it. The wrong one exits 1 saying which artifact it
carries, before it unpacks anything.

**`catalog/` and `bin/classify` are not in it.** The endpoint enumerates and matches nothing;
the classifier runs where you collect. That is what lets a new signature re-match evidence
you already have, and it is why the machine being inventoried never carries the signatures
it is supposed to enumerate past.

### Wrapping it

A reporting channel usually wants something of its own: fixed output paths, a wire format, a
size budget, a particular exit status. None of that is a fact about osquery and none of it is
in here. `--driver` is the seam:

```console
$ python3 tools/bundle.py --platform darwin --driver ./my-collector.sh
```

The bundle then runs `my-collector.sh` instead of `bin/discover`, with `AI_DISCOVERY_ROOT`
pointing at the extracted tree and the arguments passed through. What it does with them —
where it writes, what it frames, what it reports when the payload is too big for its channel
— is yours, and stays yours through a version bump of this repo.

## `status.txt`, whose vocabulary is a contract

One line:

```
ok 2026-08-31T20:30:29Z rows=775 apps=ok browser=ok containers=ok filesystem=ok packages=ok runtime=ok
```

`ok`, `absent`, `unhealthy:<http-code>`, `timeout:<seconds>`, `error`, `no-cache`. Every
payload also carries one dated `kind=scan` row per branch with the same value, so a consumer
that only has the JSON still knows which branches ran and when.

`stale:<seconds>` used to be listed here and is retired: nothing emitted it. Judge staleness
from the marker row's `ver`, which holds the unix time of the scan — that is what
`bin/classify` does, and it lets the reader pick the threshold rather than the writer.

**Judge freshness on that timestamp, not the file's mtime** — redeploying a file resets the
mtime without changing the truth.

## On Linux, which is the same shape with three differences

`bin/discover` picks its artifact from `uname -s`, so every command on this page works
unchanged. Three things differ and are worth knowing before you deploy:

- **The composed artifact is per platform, and there is no unqualified one.**
  `dist/discovery-darwin.sql` and `dist/discovery-linux.sql` name disjoint sets of tables.
  Feed one to the other platform's `osqueryi` and you get `[\n\n]` and exit 1 — five bytes
  of valid, empty, plausible JSON. It does exit non-zero, which is the only reason that
  state is recoverable, so **check the exit status** if you invoke `osqueryi` yourself
  rather than going through `bin/discover`.
- **The pack needs no per-platform version.** `dist/ai-discovery.conf` carries every
  platform's queries, each with osqueryd's own `platform` field, and osqueryd schedules only
  the ones that apply. One pack, any fleet. `bin/discover --write` filters the same way.
- **One branch reports whether it could look at all.** `systemd_units` returns zero rows and
  exits 0 when osquery cannot reach the system bus, so the Linux artifact carries a
  `kind=scan` row for it: `ok` when units were read, `absent` when there is no bus,
  `unhealthy:no-units` when there is a bus and no units — which no real systemd host
  produces. Read it the way you read the container marker, because "no agent units" and
  "we could not read the unit list" are different answers.

## The `python3` stub, which used to bite only on a fleet

On a Mac without Command Line Tools installed, `/usr/bin/python3` is a **stub**: it prints an
install prompt on stderr and exits 1 with empty stdout. The scheduled writer was built on it
and produced nothing at all there.

**This page said that surfaced as `no-cache`. It did not.** The `no-cache` marker row — the
one thing that tells a reader the writer never ran — was itself emitted by `python3`, so on
the machine this section describes it surfaced as **silence**, which a collector that records
stdout and discards the exit status reads as a machine with nothing on it. The reason and the
failure shared an interpreter, and the reason lost.

Neither endpoint script uses `python3` now. `bin/discover` and `bin/container-scan` are bash
and `osqueryi`; marker rows are built by `printf`, so the row that says the writer never ran
needs nothing that could have been what stopped it, and the documents they read are parsed by
the same SQLite that wrote them. `test/lint.sh` greps for a reintroduction, and
`test/docker_states.sh` runs every mode with `python3` and `python` stubbed out and asserts
neither was called.

`bin/classify` is still Python and still runs off the endpoint, where a missing interpreter
is one operator's problem rather than a fleet-wide condition.

## What a deployment has to supply

This repo ships osquery materials: the queries, the runner, the guard and the bound. The parts
that belong to *your* management stack are deliberately not here, because they differ per
consumer and would rot in a public repo:

- **A schedule** — a launchd job, a systemd timer, an MDM policy, cron.
- **Transport** — whatever moves the file to wherever you read it.
- **Framing**, if your channel has a size or encoding limit. Compressing the JSON is usually
  enough; on a reference Mac 121 KB of rows becomes about 19 KB. The 30KB figure this repo
  keeps to is a **Jamf Extension Attribute convention and self-imposed on both platforms** —
  Linux has no such channel at all, so do not restate it as a limit there.
- **Classification at scale.** `bin/classify` is the reference implementation and answers "what
  is on this machine". For a fleet, collect the rows and match them where the catalog lives, so
  that adding a signature re-matches evidence you already hold instead of requiring a re-scan.

## Two things that are deliberately not prerequisites

**`curl`** is used in exactly one place — the Docker socket health probe inside
`bin/container-scan` — and `curl` ships with macOS and with every Linux base image we have
run this on. Naming it as a prerequisite would
make the list look longer than it is without telling anyone anything they can act on.

**Docker** is a property of the machine you are scanning, not a dependency of the scanner. If a
machine has no Docker, `bin/container-scan` finds no socket and reports `absent` — a stated
outcome, not a failure. See [containers.md](containers.md) for what the container branch buys
you and when it is worth enabling.
