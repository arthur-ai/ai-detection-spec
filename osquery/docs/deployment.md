# Running it on a fleet

What only matters at fleet scale. [The README](../README.md) covers one machine.

Paths on this page are the release layout, `bin/`, `dist/` and `catalog/` side by side, as a
deployment unpacks them. In a clone, `discover`, `container-scan` and `dist/` are under
`osquery/`.

## Schedule the scan, then read the file

The container branch can hang rather than fail ([containers.md](containers.md)), so do not
run the queries on a synchronous reporting path. Write on a schedule and read the result:

```console
# on a schedule, as root
$ bin/discover --write /var/lib/ai-detection-spec/inventory.json \
               --status /var/lib/ai-detection-spec/status.txt

# from wherever you collect, whenever you like
$ cat /var/lib/ai-detection-spec/inventory.json
$ cat /var/lib/ai-detection-spec/status.txt
```

**`cat` is the integration.** `bin/discover --cache PATH` adds a parse check, so a
half-written file is caught rather than forwarded as a machine that reported nothing, but it
needs `osqueryi`. A collection host without osquery should just read the file.

On the write path each branch runs in its own bounded process, so one unavailable table costs
one branch. Composed into one statement, it would return a valid empty array that a consumer
cannot tell from a clean machine.

## `status.txt`

One line, one token per branch (abbreviated here):

```
ok 2026-08-31T20:30:29Z rows=775 apps=ok browser=ok containers=absent filesystem=ok …
```

The values are the spec's scan outcomes ([SPEC.md §5.2](../../SPEC.md#52-scan-markers)):
`ok`, `absent`, `unreadable:<runtime>`, `unhealthy:<reason>`, `timeout:<seconds>`, `error`,
`no-cache`. The payload carries the same outcome as one dated `kind=scan` row per branch, so a
consumer with only the JSON knows which branches ran and when.

- **The first token is `degraded` when any branch failed to look**, meaning anything other
  than `ok` or `absent`. `absent` is a fact about the machine, such as no Docker or no systemd
  bus, so a Mac without Docker reads `ok`. That keeps the first token worth alerting on.
- **`absent` and `unreadable:<runtime>` are both "no Docker socket here".** `absent` means no
  other container runtime is installed either. `unreadable:podman` means one is and this scan
  does not read it, so whether the machine holds containers is unknown, not none.
- **Judge freshness from the marker's `ver`**, the unix time of the scan, not from the file's
  mtime. The reader picks the threshold.

`bin/classify` sorts the markers into scans, absences and gaps
([SPEC.md §6.7](../../SPEC.md#67-scans-absences-and-gaps)), and only a gap makes it hedge:
`No AI agents found in the parts that could be read.`

## One file, for a platform that hosts a script and not a package

The loose files work only side by side, because `bin/discover` resolves `dist/` against its
own parent. A management platform is worst at placing files and best at running a script, so
the bundle is the layout inside one script:

```console
$ python3 osquery/tools/bundle.py --platform darwin   # or take it from the release
$ ./artifacts/ai-detection-spec-darwin.sh --write /var/lib/ai-detection-spec/inventory.json \
                                         --status /var/lib/ai-detection-spec/status.txt
```

- **It takes `bin/discover`'s arguments and installs nothing.** The payload is extracted to
  a private temporary directory, run, and removed, also on failure and on interrupt.
- **It adds two prerequisites, `base64` and `tar`,** to the closed list the endpoint scripts
  keep to ([CLAUDE.md](../CLAUDE.md)). Both are stock on macOS and every Linux base image this
  repo has run on, and the loose files need neither.
- **One platform per bundle.** The wrong one exits 1, naming the artifact it carries, before
  unpacking anything.
- **It carries `dist/signatures.sql` and not the catalog or `bin/classify`**, so `--names`
  works and everything else is raw evidence, matched off the machine.

### Wrapping it

A reporting channel usually wants its own output paths, framing, size budget or exit status.
None of that is here; `--driver` is the seam:

```console
$ python3 osquery/tools/bundle.py --platform darwin --driver ./my-driver.sh
```

The bundle runs `my-driver.sh` instead of `bin/discover`, with `AI_DETECTION_SPEC_ROOT`
pointing at the extracted tree and the arguments passed through. The driver owns the exit
status. To read a member back out of a built bundle, use the supported interface rather than
the file's internals:

```console
$ python3 osquery/tools/bundle.py --platform darwin --member driver ./my-bundle.sh
```

## One line for a Jamf Extension Attribute

An Extension Attribute stores one text value per Mac, which Smart Groups match on.
`bin/discover --names` matches on the machine and prints the agents and the status as one
line. This command is the whole Extension Attribute script:

```console
$ bin/discover --names --cache /var/lib/ai-detection-spec/inventory.json
Claude Code 2.0.1, Cursor 1.7.44; ok 2026-10-05T13:20:11Z rows=775 apps=ok …
```

Before the `; ` are the agents found, with a version where the evidence carried one, or
`none`. After it is the `status.txt` line. So `contains "Cursor"` finds Cursor, and
`contains "degraded"` finds machines where part of the scan failed. `none; degraded …` is not
a clean machine.

- If the writer has never run, it prints `none; degraded <time> rows=1 inventory=no-cache`
  and exits 1. If the summary itself fails, it prints nothing and exits 1.
- The version is one of those seen, not necessarily the highest.
- `--names` also works with `--deep`, with `--write PATH --status TXT`, and in the bundle.

The names come from `dist/signatures.sql`, the catalog rendered into SQL. **Redeploy it when
the catalog changes.** The JSON inventory needs no redeploy, because it is matched off the
machine.

## Fleet policies

```console
$ fleetctl apply -f dist/fleet-policies.yml
```

One [Fleet](https://fleetdm.com) policy per agent per platform. A policy **passes when the
agent is absent**, so Fleet's failing-hosts list is the list of machines with the agent; swap
`NOT EXISTS` for `EXISTS` to invert it. Each policy reads only the branches its agent's
routes need.

Policies report no versions; use the JSON for those. They never look at containers, because
osqueryd cannot bound one query, so an agent that ships only as an image has no policy, and
the file lists those at the top. `dist/agents-darwin.sql` and `dist/agents-linux.sql` do the
same matching as one `osqueryi` query, one row per agent, with the same container limit.

## Linux

`bin/discover` picks its artifact by `uname -s`, so every command above works unchanged.

- **Check `osqueryi`'s exit status if you run an artifact yourself.** Fed to the wrong
  platform, an artifact prints `[\n\n]`, valid empty JSON, and exits 1.
- **One pack serves every platform.** `dist/ai-detection-spec.conf` sets osqueryd's
  per-query `platform` field, and `bin/discover --write` filters the same way.
- **systemd has its own marker**, because `systemd_units` returns zero rows and exits 0 when
  osquery cannot reach the system bus: `ok`, `absent` with no bus, or `unhealthy:no-units`
  with a bus and no units.

### Cloud VMs

CI proves `dist/discovery-linux.sql` in Debian, Rocky, Fedora and Amazon Linux containers and
on Ubuntu runners. A container has no systemd or OS Login, so `test/run-gce.sh` and
`test/run-ec2.sh` run the same scenarios on real VMs.

- **OS Login, SSSD, LDAP and AD accounts are not in osquery's `users`** on Linux since
  5.13.1, which reads `/etc/passwd` when unconstrained. The path branches glob `/home` and
  `/root` on disk. The user-scoped branches take their uids from those home directories as
  well, and a lookup by uid does reach NSS. On GCE VMs with OS Login, a Chrome profile owned
  by the login account produced 0 extension rows through `users` alone and 1 through the
  shipped artifact. The remaining gap, an NSS-only account with a home elsewhere, is in
  [`docs/blind-spots.yaml`](../../docs/blind-spots.yaml).
- **EC2 logins are ordinary `/etc/passwd` accounts**, `ssm-user` included once Session
  Manager has created it, so OS Login's gap does not apply.
- **A headless VM** returns no desktop, browser or native-messaging rows, correctly: each
  branch is a path glob, with nothing to fail soft, and its marker still says it ran. The
  `systemd` marker reads `ok` there, where a container reads `absent`.
- **Small shapes vary.** A shared-core `e2-small`, or a burstable EC2 instance in standard
  credit mode, can take the composed artifact past the 10s convention, while every branch
  of `--write` stays inside its own 30s bound. [COST.md](../queries/COST.md) has the
  figures, and the reason to prefer the scheduled writer.

## What a deployment supplies

This repo ships the queries, the runner, the guard, the bound and the matching. The parts
that belong to your management stack differ per consumer and are not here:

- **A schedule**: a launchd job, a systemd timer, an MDM policy, cron.
- **Transport** from the machine to wherever you read the file.
- **Framing**, if your channel limits size. Compressing the JSON is usually enough. The 30KB
  this repo keeps to is a self-imposed Extension Attribute convention, not a platform limit.
- **Where to match.** On the machine, with `agents-<platform>.sql`, `fleet-policies.yml` or
  `bin/discover --names`, redeployed when the catalog changes. Or off it, with
  `bin/classify` over the stored JSON, where a new signature re-matches evidence you already
  hold.

Two things are deliberately not prerequisites. **`curl`** is used once, for the Docker health
probe, and ships with macOS and every Linux base image this repo has run on. **Docker** is a
property of the machine being scanned: without it the container branch reports `absent`, or
`unreadable:<runtime>` when another runtime is installed.
