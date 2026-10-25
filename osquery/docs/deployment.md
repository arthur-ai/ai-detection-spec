# Running it on a fleet

Everything here is about deploying the queries across machines you manage. The README
covers running them on one machine; this page is the part that only matters at fleet scale.

Paths on this page are the release layout: `bin/`, `dist/` and `catalog/` side by side, as a
deployment unpacks them. In a clone, `discover`, `container-scan` and `dist/` are under `osquery/`.

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

The loose files a release attaches only work in one layout, `bin/`, `dist/` and `catalog/` side by side:
`bin/container-scan` resolves `dist/discovery-deep.sql` relative to its own parent, and
`bin/discover` sources `bin/container-scan`. Putting files in a fixed place on a managed
machine is the part a management platform is worst at — it wants a package, which on macOS
wants code signing, notarization and a PPPC profile. Hosting a script and running it on a
schedule is the part every one of them does well.

So: the layout, inside one script.

```console
$ python3 osquery/tools/bundle.py --platform darwin   # or download it from the release
wrote artifacts/ai-discovery-darwin.sh (46 KB, 6 files, darwin)

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

**`catalog/` and `bin/classify` are not in it; `dist/signatures.sql` is.** The enumeration
matches nothing and the classifier runs where you collect — that is what lets a new
signature re-match evidence you already have. The one file that does name agents is the
catalog rendered into SQL, carried so that `--names` can print a line on a machine that can
host nothing but this script; see [One line for an Extension Attribute](#one-line-for-an-extension-attribute).

### Wrapping it

A reporting channel usually wants something of its own: fixed output paths, a wire format, a
size budget, a particular exit status. None of that is a fact about osquery and none of it is
in here. `--driver` is the seam:

```console
$ python3 osquery/tools/bundle.py --platform darwin --driver ./my-collector.sh
```

The bundle then runs `my-collector.sh` instead of `bin/discover`, with `AI_DISCOVERY_ROOT`
pointing at the extracted tree and the arguments passed through. Your driver owns the exit
status. What it does with them — where it writes, what it frames, what it reports when the
payload is too big for its channel — is yours, and stays yours through a version bump here.

Your driver is inside the payload once it is bundled, so anything you had that checked your
own collector by reading it needs a way back in:

```console
$ python3 osquery/tools/bundle.py --platform darwin --member driver ./my-bundle.sh
```

That is a supported interface, not a debugging trick — `read_member()` in Python is the same
thing. Reaching into the file yourself is how a consumer ends up pinned to an internal detail,
which this project has already done to one downstream repo by removing `bin/discover --framed`.

## Getting the agent names as one line (Jamf Extension Attributes)

A Jamf Extension Attribute stores one text value per Mac, and Smart Groups and searches work
on that value. `bin/discover --names` is built for it. It matches the inventory against the
catalog on the machine and prints the agent names as one line:

```console
$ bin/discover --names --cache /var/lib/ai-discovery/inventory.json
Claude Code 2.0.1, Cursor 1.7.44; ok 2026-10-05T13:20:11Z rows=775 apps=ok browser=ok containers=absent filesystem=ok homebrew=ok native-messaging=ok packages=ok ports=ok runtime=ok vscode=ok
```

That command is the whole Extension Attribute script. It reads the file written by the
scheduled `bin/discover --write` from the top of this page.

The line has two parts, separated by `; `:

- **Before the `; `**: the agents found, with a version where one was available, or `none`
  if nothing was found.
- **After the `; `**: the same status line that goes into `status.txt`. It tells you whether
  every part of the scan worked.

So a Smart Group can match `contains "Cursor"` to find machines with Cursor, and another can
match `contains "degraded"` to find machines where part of the scan failed. A machine that
reports `none; degraded ...` found no agents, but could not check everything, so it is not
the same as a clean machine.

`--names` works with the other flags too. `bin/discover --names` runs the scan directly,
`--names --deep` includes containers, and `--names --write PATH --status TXT` writes the files
and prints the line. The one-file bundle accepts it as well.

A few things to know:

- If the scheduled writer has never run, `--names --cache` prints
  `none; degraded <time> rows=1 inventory=no-cache` and exits 1.
- If the summary itself fails, nothing is printed and the exit code is 1. It never prints
  `none` for a machine it could not read.
- The version shown is one of the versions seen in the evidence for that agent, not
  necessarily the highest if several are installed. Some
  evidence, like a config directory, has no version, so an agent can appear without one.

The names come from `dist/signatures.sql`, which is the catalog converted to SQL by
`osquery/tools/render_match.py`. **When the catalog gains a signature, you have to redeploy that file
for `--names` to pick it up.** The JSON inventory does not have this problem, because it is
matched against the catalog later, off the machine.

## Fleet policies

`dist/fleet-policies.yml` contains one [Fleet](https://fleetdm.com) policy for each agent, for
each platform the agent runs on. Load it with:

```console
$ fleetctl apply -f dist/fleet-policies.yml
```

A policy **passes when the agent is not on the host** and fails when it is. That matches how
Fleet is normally used: the list of failing hosts is the list of machines that have the
agent, and Fleet's alerts fire on failures. If you want it the other way round, change
`NOT EXISTS` to `EXISTS` in the query.

Each policy only reads the parts of the system where its agent can be found. The Claude Code
policy on macOS looks at home directories and npm packages and nothing else, so it costs
much less than a full inventory scan.

Two limits:

- Policies do not report versions. A policy is a yes or no answer. For versions, use the JSON
  inventory from `bin/discover --write`.
- Policies do not look at containers, because a container query can hang and osqueryd
  cannot put a time limit on one query (see [containers.md](containers.md)). Agents that
  only ship as container images have no policy. The file lists them at the top.

`dist/agents-darwin.sql` and `dist/agents-linux.sql` do the same matching as one query you
can run with `osqueryi`. They return one row per agent found. They have the same limit on
containers; `bin/discover --names --deep` is the way to see container-only agents.

## `status.txt`, whose vocabulary is a contract

One line:

```
ok 2026-08-31T20:30:29Z rows=775 apps=ok browser=ok containers=ok filesystem=ok packages=ok runtime=ok
```

`ok`, `absent`, `unreadable:<runtime>`, `unhealthy:<http-code>`, `timeout:<seconds>`,
`error`, `no-cache`. Every payload also carries one dated `kind=scan` row per branch with
the same value, so a consumer that only has the JSON still knows which branches ran and when.

**`absent` and `unreadable:` are both “no Docker socket here”, and what separates them is
what else is on the machine.** `absent` means no other container runtime is installed
either. `unreadable:podman` means one is and this scan does not read it — so whether that
machine holds containers is **unknown**, not none. A consumer that folds the second into
the first reads a Podman fleet as a fleet with no containers, which is the one reading
this vocabulary exists to prevent.

`bin/classify` splits the same three ways — `scans`, `absences`, `gaps` — and only `gaps`
makes it hedge its report. A machine with no container runtime still gets a plain
`No AI agents found.`; one whose daemon would not answer gets `... in the parts that could
be read.` A consumer reconciling row counts owes `absences` a subtraction, or those rows
read as dropped.

**The first token separates "could not look" from "nothing to look at".** `absent` is a
stated fact about the machine — no Docker, no systemd bus — so it does not degrade the line;
a Mac that simply does not run Docker reads `ok`. `unhealthy:*`, `timeout:*`, `error` and
`unreadable:*` are branches that failed to look, and those do. The distinction is what keeps
the first token worth alerting on: a signal that fires on every Docker-less machine is one a
fleet learns to ignore. The per-branch token still says `containers=absent` whether or not
the line degrades, so a consumer counting machines with no container runtime at all narrows
on that — a Docker-less machine that runs Podman says `containers=unreadable:podman`.

**Judge freshness from the marker row's `ver`**, the unix time of the scan, and not from the
file's mtime — redeploying a file resets the mtime without changing the truth. There is no
`stale:` token: the reader picks the threshold, not the writer.

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

### On a Compute Engine VM

A VM is a headless, often multi-user server, which is a different machine from a laptop.
Four things about it are worth knowing, each checked rather than assumed.

**Which images.** CI runs the Linux scenarios on Debian 12, Rocky Linux 9, Fedora 41 and
Amazon Linux 2023 containers, every one a container can host, and on Ubuntu 24.04 runners,
x86_64 and arm64, so the one
`dist/discovery-linux.sql` is proved on the three families a GCE fleet boots, on the image an
EC2 fleet boots by default, and on the deb and rpm sides of each. A container
cannot host systemd or OS Login, so `test/run-gce.sh` runs the same scenarios on one real
VM per family and brings the observations back into the tree. `test/run-ec2.sh` does the same
on EC2, reached over SSM: Amazon Linux 2023 on x86_64 and arm64, and Ubuntu 24.04.

**OS Login.** With OS Login on, accounts come from an NSS module rather than `/etc/passwd`,
and a home directory appears on first login. osquery's Linux `users` table has read
`/etc/passwd` directly when unconstrained since 5.13.1, so that an LDAP site does not pay a
directory query per scan — which means **`users` does not list OS Login accounts at all**,
nor SSSD, LDAP or Active Directory ones. Measured 2026-10-04 on e2-small VMs of all three
families with OS Login on: the unconstrained table returned exactly the `/etc/passwd` count,
a lookup of the login account's uid returned nothing, and the same lookup with
`include_remote = 1` returned the account. The path branches never depended on it: they
glob `/home/%/` and `/root/` on disk. The two branches that join `users`, browser extensions
and VS Code extensions, take their uids from the home directories on disk as well as from
`users`, because a lookup by one uid does reach NSS. On each VM a Chrome profile owned by
the OS Login account produced **0 extension rows through the `users` join and 1 through the
shipped artifact.** So an account that has logged in is covered, and one that never has owns
nothing to find. The remaining gap is an NSS-only account with a home outside `/home` or
`/root`, which `docs/blind-spots.yaml` records.

**EC2 accounts.** EC2 logins are ordinary `/etc/passwd` accounts, so OS Login's gap doesn't
apply. They are `ec2-user`, `ubuntu`, and `ssm-user`, which Session Manager creates on first
use. On every instance, `users` returned exactly the `/etc/passwd` count. Measured 2026-10-21:
after one real Session Manager session, `users` listed `ssm-user` with its home, and a state
directory planted in that home came back from the shipped artifact. A directory-joined
instance (SSSD) is OS Login's case, and stays in `docs/blind-spots.yaml`.

**Headless.** No desktop session means the desktop-entry, browser and native-messaging
branches return no rows, and that is the correct answer rather than a silent one: each is
a glob over paths that exist or do not, with nothing that can fail soft. On the write path
every branch still gets its own dated `kind=scan` row, so `status.txt` on a headless VM
reads `browser=ok desktop-linux=ok native-messaging-linux=ok`, and a reader can tell
"looked, nothing there" from a branch that never ran. The `systemd` marker is the one that
changes on a VM: with systemd as PID 1 and osquery running as root it reads `ok` and the
`unit` rows are real, where every container run reports `absent`.

**Small shapes.** A shared-core `e2-small` does not promise the same number twice: the same
Rocky image measured the composed artifact at 2.4s cold on one VM and 14.0s on another the
same afternoon, with `systemd_units` alone at 5.5s against 1.2s.
[`osquery/queries/COST.md`](../queries/COST.md#compute-engine-e2-small-2026-10-04) has the table. It
is why `osquery/queries/runtime-linux.sql` is banded `slow`, and why a scheduled `--write`, where each
branch has its own bound, is the shape to prefer over anything that waits.

**Burstable EC2 shapes.** In the default unlimited credit mode, `t3.small` and `t4g.small` run
at full speed: the composed artifact takes 1.6–2.8s cold, and `--write` 4.6–6.0s. In standard
mode a fresh instance has no credits, and is held to its 20% baseline from the start. The same
scan then takes 10–12s cold, and 14–16s for `--write`. That is still inside every branch's own
30s bound, but over the composed artifact's 10s convention.
[`osquery/queries/COST.md`](../queries/COST.md#ec2-t3small-and-t4gsmall-2026-10-21) has the tables.

## The `python3` stub, which used to bite only on a fleet

On a Mac without Command Line Tools installed, `/usr/bin/python3` is a **stub**: it prints an
install prompt on stderr and exits 1 with empty stdout. The scheduled writer was built on it
and produced nothing at all there.

It did not even surface as `no-cache`: that marker row — the one thing that tells a reader
the writer never ran — was itself emitted by `python3`, so the failure surfaced as **silence**,
which a collector that discards the exit status reads as a machine with nothing on it.

Neither endpoint script uses `python3` now. `bin/discover` and `bin/container-scan` are bash
and `osqueryi`; marker rows are built by `printf`, so the row that says the writer never ran
needs nothing that could have been what stopped it, and the documents they read are parsed by
the same SQLite that wrote them. `test/lint.sh` greps for a reintroduction, and
`osquery/test/docker_states.sh` runs every mode with `python3` and `python` stubbed out and asserts
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
- **A choice of where to match.** Both ways ship here and both read the same catalog. Match
  on the machine with `agents-<platform>.sql`, `fleet-policies.yml` or `bin/discover
  --names`, and redeploy those files when the catalog changes. Or collect the JSON and match
  it with `bin/classify` where the catalog lives, so a new signature re-matches evidence you
  already hold. What you do not get here is the collector itself.

## Two things that are deliberately not prerequisites

**`curl`** is used in exactly one place — the Docker socket health probe inside
`bin/container-scan` — and `curl` ships with macOS and with every Linux base image we have
run this on. Naming it as a prerequisite would
make the list look longer than it is without telling anyone anything they can act on.

**Docker** is a property of the machine you are scanning, not a dependency of the scanner. If a
machine has no Docker, `bin/container-scan` finds no socket and reports `absent`, or
`unreadable:<runtime>` when another container runtime is installed and was not
inspected — a stated outcome either way, not a failure. See [containers.md](containers.md) for what the
container branch buys you and when it is worth enabling.
