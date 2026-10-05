# Measured cost

Best of three runs. The floor is the honest number: anything above it is scheduler noise,
and what we are looking for is a query that *blocks*, not a microbenchmark.

Bands: `fast` under 1s, `slow` 1 to 5s, `expensive` excluded from the composed artifacts and
composed into `dist/discovery-deep.sql` instead. `tools/measure.py --check` enforces them on
every pull request.

`expensive` covers two different facts. `python_packages` at 15.6s is **slow** — a number.
`docker_images` against a wedged daemon is **unbounded** — not a number, which is what
`measure.py`'s `float("inf")` ceiling admits. A slow query can be scheduled; an unbounded one
needs a process around it that can be killed. Neither belongs in a composed artifact.

The gate fires at **2x the declared band**, not at the band itself. A band is a declaration
a reader can trust; the gate catches a query that *blocks*, which is an order-of-magnitude
event. Enforced at the same number, the boundary case flaps: `apps.sql` measured 0.81s and
1.14s on consecutive runs of the same commit on the same runner. A gate that fails at random
teaches people to re-run it, and then a real stall gets re-run too. 2x absorbs runner
variance and is still five times below the 10.2s stall this exists to catch.

The composed artifact is gated at 10s, and **that number is self-imposed.**

An earlier version of this file called it a platform limit. It is not: no macOS management
tool we checked documents a per-script timeout, and the evidence runs the other way — scripts
measured at 21 seconds, and inventory collection *stalling* rather than being cut off. An
unbounded collection script does not fail fast; it hangs that machine's inventory.

So the gate stays as a convention: 10s keeps collection brisk, and the real requirement is
that nothing on a synchronous reporting path can block forever. The better answer is not to
run a blocking query on that path at all — see the scheduled writer below.

## Linux baseline

GitHub-hosted `ubuntu-24.04`, image **Ubuntu 24.04.4 LTS x86_64**, osquery 5.23.1. A runner
carries **1212 deb packages, 438 systemd units and 12 desktop entries**, which makes it a
usefully loaded machine for everything except the agent routes — it has no agents on it, so
every row count below is the empty case for those.

| query | band | seconds | rows |
|---|---|---|---|
| `browser.sql` | fast | 0.05 | 0 |
| `desktop-linux.sql` | fast | 0.22 | 13 |
| `filesystem-linux.sql` | fast | 0.22 | 10 |
| `native-messaging-linux.sql` | fast | 0.22 | 0 |
| `packages-linux.sql` | fast | 0.26 | 1211 |
| `packages.sql` | fast | 0.26 | 13 |
| `ports.sql` | fast | 0.24 | 0 |
| `runtime-linux.sql` | fast | **1.03** | **478** |
| `vscode.sql` | fast | 0.23 | 0 |
| `containers.sql` | expensive | 0.22 | 0 |
| `dist/discovery-linux.sql` | composed | 1.12 | 1726 |
| `dist/discovery-deep.sql` | deep | 0.22 | 0 |

### The composed Linux artifact costs 8-12s COLD, not 1.12s

**Both numbers above and below are real, and they answer different questions.** The 1.12s in
the table is what `tools/measure.py` reports; the CI job that runs the artifact the way an
endpoint does measured **8s, 9s, 12s and 14s** across four runs, with the same ~1750 rows.

**Four readings, and every one of them is at or over the 10s budget.** That is worth saying
plainly rather than filing under runner variance: this is not `apps.sql` measuring 0.81s and
1.14s either side of a 1s band. The cold cost of the composed Linux artifact on a loaded
machine EXCEEDS the budget this repo sets itself, consistently, and the CI gate emits a
warning every time it does.

The gap is not the data. It is how each number is taken:

| | `tools/measure.py` | the `Runtime on Linux` job |
|---|---|---|
| runs | **floor of three** | one |
| warmth | `performance.yml`'s baseline step runs `dpkg-query`, `systemctl list-unit-files` and `ls /usr/share/applications` first — **exactly what this query reads** | cold, first thing after installing osquery |
| privilege | unprivileged | `sudo`, so it can read other users' homes |

`measure.py`'s own docstring is right about what it is for — *"the floor is the honest number:
anything above it is scheduler noise, and we are looking for queries that block, not for
microbenchmarks"* — and that makes it a **warm floor**, which is the wrong number to judge a
synchronous reporting path by. **The cold number is what an endpoint's first scheduled scan
pays**, and on a machine with 1212 deb packages and 438 systemd units that is 8-12s against a
self-imposed 10s budget.

Two consequences, and neither is a defect in the query:

- **It reinforces the deployment advice this repo already gives.** `docs/deployment.md` says
  not to put this on a synchronous reporting path and to schedule `bin/discover --write` and
  `cat` the file. A cold cost near the budget is the measurement behind that sentence rather
  than a new problem.
- **The CI gate warns at the budget and fails at 2x.** That is the convention `measure.py`
  already uses, and the reason it is right HERE is narrower than the reason it is right there:
  a hard gate made this job red at 12s and green at 9s on identical code, which teaches people
  to re-run rather than to read. The warning is the part that matters -- it fires on every run,
  so the overrun stays visible instead of being absorbed into a green tick.
- **The `unit` branch is the first thing to reconsider if this needs to come down.** It is 477
  of the ~1750 rows -- 28% of the payload -- and `systemd_prefixes` carries no catalog values,
  so none of those rows can match anything today. Dropping or filtering it would cut payload
  and time together. It is not dropped yet because an unrecognised unit running unattended is
  the same argument that keeps 47 third-party launchd jobs on macOS, and because
  `fragment_path` is the wrong discriminator for the reason the query records. But the
  trade is now measured on both sides rather than argued on one.

The cold macOS cost was checked the same way for comparison and is not interesting: 1.65s cold
against 1.22s warm, a factor of 1.3. Whatever makes the Linux figure 8-10x is specific to that
platform's tables — `deb_packages` reads a ~5MB dpkg database and `systemd_units` makes DBus
round trips for 438 units — and it has **not** been isolated further than that. Saying so is
better than picking one of them and writing it down.

### `runtime-linux.sql` is the one to read carefully

This section previously said no Linux numbers existed and that this branch's band was "an
expectation, not a measurement". It is measured now, and the expectation was optimistic in two
different ways.

**It is over its declared band.** 1.03s against a `fast` ceiling of 1s — reported as *over
declared band, within tolerance*, so the 2x gate passes it. **The band is not being changed on
one sample**, and that is the same judgement `apps.sql` already earned: it measured 0.81s and
1.14s on consecutive runs of the same commit on the same runner, which is why the gate fires at
2x and not at the band. 1.03s is inside that noise. A second and third run either settle it
below 1s or make the case for `slow` on evidence rather than on one reading.

**478 rows is 28% of the whole Linux payload**, and the `systemd_prefixes` route carries **no
catalog values at all** — so every one of those rows is evidence that can never match anything
today. That is not automatically wrong: the macOS `daemon` branch keeps all 47 third-party
launchd jobs on the same argument, that an unrecognised job running unattended is the point. But
the ratio is very different. macOS drops 937 launchd jobs to 47 with `com.apple.%`; Linux has no
equivalent, because the distro's units are named `sshd.service` and `cron.service` with nothing
in the NAME to key on.

`fragment_path` is the only structural discriminator — `/etc/systemd/system` for locally
installed units against `/usr/lib/systemd/system` for packaged ones — and it is still the wrong
filter for the reason recorded in the query: a vendor's own `.deb` writes to `/usr/lib` too, so
it would drop exactly the packaged agent the branch exists to find. **The decision is therefore
deferred rather than taken**, and now it is deferred with a number attached instead of without
one. It becomes urgent if either half of the ratio moves: a fleet payload nearing the framing
budget, or a real agent unit landing in the catalog and making the branch earn its rows.

**The 30KB payload budget is a macOS convention carried over, not a Linux limit.** It comes from
a Jamf Extension Attribute value cap, and Jamf does not document that either — it is self-imposed
on both platforms. Linux has no equivalent channel at all. `test/run-linux.sh` and the Linux CI
job keep the same budget anyway, because a payload small enough to move is worth having
regardless, but nothing about Linux requires it and no one should restate it as though something
did.

## Compute Engine, `e2-small`, 2026-10-04

Stock images from the three families a GCE fleet boots, OS Login on, osquery 5.23.1, run by
`test/run-gce.sh` before any scenario installed anything. A shared-core shape with 2 vCPU
and under 2GB. `tools/measure.py --check` passed on every VM; floors of three.

| query | Debian 12 | Ubuntu 24.04 | Rocky 9.8 |
|---|---|---|---|
| `packages-linux.sql` | 0.24s, 361 rows | 0.24s, 595 | 0.61s, 406 |
| `runtime-linux.sql` | 0.78s, 241 | 1.18s, 449 | 1.23s, 258 |
| every other Linux query | 0.23–0.26s | 0.24–0.26s | 0.24–0.26s |
| `dist/discovery-linux.sql` | 0.82s, 620 | 1.22s, 1065 | 1.71s, 671 |

Cold, as an endpoint's first scan pays it: 1.3s, 1.7s and 2.4s. `bin/discover --write`,
every branch in its own process: 3.9s, 4.3s and 5.1s.

**A second Rocky VM the same afternoon measured `runtime-linux.sql` at 5.54s and the
composed artifact at 9.24s warm, 13.96s cold.** Same image, same shape, same query. The
per-unit D-Bus round trips are where the time goes, and a shared core does not promise the
same number twice — so `runtime-linux.sql` is banded `slow` on the strength of the worse
VM, and the composed figure should be read as "usually two seconds, occasionally fourteen"
rather than as either number alone.

## CI baseline

GitHub-hosted `macos-15`, image macOS **15.7.7 arm64**, 26 applications, 117 Homebrew
formulae, osquery 5.23.1. The runner is pinned rather than `macos-latest` so an image
reissue shifts these numbers visibly instead of silently.

| query | band | seconds | rows |
|---|---|---|---|
| `apps.sql` | fast | 0.81 | 0 |
| `browser.sql` | fast | 0.25 | 0 |
| `filesystem.sql` | fast | 0.25 | 0 |
| `packages.sql` | fast | 0.24 | 0 |
| `runtime.sql` | fast | 0.47 | 0 |
| `dist/discovery-darwin.sql` | composed | 1.20 | 0 |

**Every row count is zero, and that is a limitation of this baseline, not a result.** The
runner has no AI agents installed and no browser profiles, so these numbers measure the
empty case. A query that is slow only when it has rows to return would pass here.

## Loaded baseline

An ordinary developer Mac: macOS 26, Apple Silicon, Docker installed but not running,
several browser profiles, 76 matching rows.

| query | band | seconds | rows |
|---|---|---|---|
| `apps.sql` | fast | 0.56 | 4 |
| `browser.sql` | fast | 0.56 | 67 |
| `filesystem.sql` | fast | 0.24 | 4 |
| `packages.sql` | fast | 0.29 | 1 |
| `runtime.sql` | fast | 0.38 | 0 |
| `dist/discovery-darwin.sql` | composed | 1.07 | 76 |

## Deliberately not collected

`python_packages`: 15.6s per scan, does not honour WHERE push-down, and contributed zero
matches. It took the full query from 2.0s to 78s. If it is ever wanted, it goes in the
scheduled writer, never on a synchronous reporting path.

(This lived in `queries/NOTES.md`, which was deleted: its other entry described
`docker_images` as absent, and `docker_images` now ships. A note about one table belongs
beside that table — `queries/containers.sql` carries the current version — and a note about
cost belongs here.)

## What neither baseline covers

**A machine without the dependency installed is not a valid baseline.** A `docker_images`
branch measures 0.35s with Docker absent and **10.24s with Docker installed but not
answering**, returning zero rows in both cases. The hosted runner has no Docker, so CI
asserts the absent case only. The stopped and mid-startup states need a local or
self-hosted run.

If your query touches a daemon, socket or external service, measure it stopped and
mid-startup before you trust either table above.

## The container branch against a live daemon, 2026-09-11

Both tables above were measured on runners with **no Docker**, where `containers.sql`
returns zero rows in 0.22s. That number says nothing about the cost of the branch actually
doing its job, and it now has three arms rather than one, so here is the live reading.

macOS 15, Docker 28.4.0, osquery 5.23.1, **18 images / 1 running container / 6 label rows**,
`dist/discovery-deep.sql` through `osqueryi` three times consecutively:

```
0.67s   0.54s   0.52s      25 rows, 4447 bytes of JSON
```

**Roughly +0.1s over the 0.44s the images arm alone measured on the same class of host**, for
a running container and its vendor labels. Comfortably inside `bin/container-scan`'s 6s
wall-clock bound, which is the number that matters — the bound exists because
`docker_images` is UNBOUNDED against a wedged daemon, not because the healthy path is slow.

**Two things this does not measure, and both scale with the host rather than the query.**
`docker_containers` is a per-container inspect, so its cost grows with how many containers
are RUNNING, and one machine with one container cannot show that curve. `docker_image_labels`
grows with images times labels per image — 6 rows from 18 images here, because most images
carry no `source` label at all. A developer machine running a twenty-container Compose stack
is the case to measure before trusting this figure, and it has not been measured.

## The container scan, and why it runs in its own process

`bin/container-scan` is the only supported way to run `dist/discovery-deep.sql`. It carries
the two things SQL cannot express: a round trip demanding HTTP 200, and a wall-clock kill.

Measured against `test/lib/fake_docker.py` on 2026-09-14, shipped defaults
(`CONTAINER_SCAN_TIMEOUT=6`, `DOCKER_PING_TIMEOUT=8`):

| daemon state | `bin/container-scan` | exit | value |
|---|---|---|---|
| no socket anywhere | 0.10s | 2 | one `scan` row, `extra=absent` |
| stale socket / not a socket | 0.12s | 2 | one `scan` row, `extra=absent` |
| answers 500 | 0.12s | 2 | one `scan` row, `extra=unhealthy:500` |
| asleep, wakes in 3s (`nap`) | 3.62s | 0 | the image rows |
| **accepts, never replies** | **8.17s** | **2** | one `scan` row, `extra=unhealthy:000` |
| **pings 200, then never serves** | **7.88s** | **3** | one `scan` row, `extra=timeout:6` |
| healthy, 6 images | 0.58s | 0 | 8 rows plus the `ok` marker |

**Two rows of this table were wrong, and both in the direction that makes a budget look
affordable.** Accepts-never-replies was recorded as 0.19s: it is the one state that waits out
the WHOLE ping budget, so it was 1.16s at the old 1s budget and is 8.2s now — six times the
documented figure at the time it was documented, and it is the row anyone deciding whether
that budget can be raised would read first. Pings-200-then-never-serves was recorded as 7.36s
and measures 7.88s here and 8.00s through the suite, because the SIGKILL escalation added
since pays its grace on every bounded kill rather than only when SIGTERM is ignored.

~8s is 0.04s probe + the 6s bound (osqueryi's 0.5s startup is *inside* it, so do not add
them) + up to 1s of SIGKILL grace + polling slop. Against a ten-second budget that leaves 2s;
a bound above 8 does not fit. Raise it only with a measurement showing the daemon is slow
rather than wedged — and note that a slow daemon is measured in the ping budget below, not
here, because the probe is what waits for a wake.

**The ping budget is a ceiling, not a cost, which is why 8 is affordable.** Every state that
answers returns in about a tenth of a second whatever it is set to; only accepts-never-replies
pays the whole of it. It was 1s, and a Docker Desktop wake does not fit in 1s: Resource Saver
parks the VM after five idle minutes and holds the first request while it comes back — 2.60s
and 2.49s measured on macOS 15 / Docker 28.4.0 after a 340s pause, with the query behind it
then running warm at 0.13s per engine request. At 1s the guard rejected the daemon it had just
woken and reported `unhealthy:000`, and the next scan succeeded on the engine the last one had
started. **A nap longer than 8s is not measured**: one Mac, one nap length.

**What costs inside the wall clock is daemon latency, not inventory size.** Against a daemon
answering instantly, osquery's own side of the scan is 0.23s at 18 images and 0.55s at 10,000
images / 40,000 label rows. One scan makes three engine requests — `/images/json`,
`/containers/json`, `/images/json` again for the labels — so a daemon costing *t* per request
needs ~3*t* to fit: measured against a fake answering late, 1s per request scans in 3.53s and
3s per request does not fit at all.

**Two attributes, not one.** Folded together, `bin/discover --deep` against a wedged daemon
measures **8.64s**: it fits today and stops fitting the first time either half grows.

Folding the *branch* into the composed query is worse than the arithmetic suggests. Measured,
container arm third of six, wedged daemon, killed at 6s: all 757 base rows came back and
osqueryi **exited 0**. The rows are not the casualty — the casualty is any evidence that the
container half went unread, plus 7.21s against 1.19s for the base alone. Unbounded instead,
the value blanks outright. Split, an overrun blanks only the container attribute and its scan
row says which happened.

| | wedged daemon | healthy | base only |
|---|---|---|---|
| one EA (`bin/discover --deep`) | 8.64s | 1.77s | — |
| inventory EA (`bin/discover`) | 1.10s | 1.10s | 1.10s |
| container EA (`bin/container-scan`) | 7.36s | 0.51s | — |

**What removing `python3` from the endpoint did to these, measured rather than reasoned.**
The endpoint scripts parse JSON with `osqueryi` now, and an `osqueryi` spawn costs ~0.24s
against an interpreter's ~0.03s — so the question is which paths gained one. Five runs each,
old and new interleaved on one Mac, and that Mac is not the one the table above was measured
on: read the DELTAS, not the absolutes, and do not fold them into the cells by arithmetic.

| | old (python3) | new (osqueryi) | delta |
|---|---|---|---|
| `bin/discover` | 1.40s | 1.37s | — neither calls an interpreter |
| `bin/discover --deep`, healthy | 2.43s | 2.67s | **+0.24s**, one spawn: the base/deep join |
| `bin/discover --deep`, wedged | 9.69s | 9.63s | — |
| `bin/container-scan`, healthy | 1.01s | 0.99s | — the marker lost a spawn, the join gained one |
| `bin/discover --write` | 6.99s | 5.55s | **−1.44s**, eleven pack reads collapsed into one |

**The budgeted path did not move.** Wedged is where the margin is thin, and it is flat there
because `container_scan` joins its marker only on success, while `marker()` itself stopped
spawning anything — so on the path that matters the two changes cancel. Healthy `--deep` pays
one spawn, against a budget it uses a quarter of. `--write`, the mode with nobody waiting on
it, got faster.

Where a consumer's budgets are **per value** rather than a shared pool, splitting gives each
half its own and neither can blank the other. Check whether yours are.

**Scope the container EA to Macs that have Docker.** A Mac with none returns a marker row in
0.18s, which is correct and is also 10,000 rows of "no Docker here" per full sync on a fleet
that mostly has no Docker.

### Container payload

Measured twice on the same developer Mac, on two real image stores — the larger one spanning
five registries: Docker Hub library and org, `ghcr.io`, `gcr.io`, `public.ecr.aws`.

| | rows | raw | framed EA | % of cap |
|---|---|---|---|---|
| inventory EA (`bin/discover`) | 757 | 116.2 KB | 17.7 KB | 59% |
| container EA, 27 images | 27 | 4.4 KB | 2.3 KB | **8%** |
| container EA, 10 images | 10 | 1.6 KB | 0.9 KB | 3% |
| both in one EA, 27 images | 784 | 120.5 KB | 20.1 KB | 67% |

**Time binds long before 30KB does**, the reverse of the base inventory's problem.

Two store sizes make the marginal cost a measurement: (2.3 − 0.9) KB over 17 rows is **84
bytes per row**, against 32.6 for an application row. `loc` is a 64-character hex digest (no
`sha256:` prefix, measured) and a digest does not compress, so gzip gets nothing from a run
of them the way it does from `/System/` paths. **An image row is the most expensive row this
repo emits.**

### The scheduled writer, which is the recommended deployment

Nothing upstream will bound us, so the fix is not a faster blocking call but not making one
while something waits. `bin/discover --write` runs on a schedule and whatever collects reads
the file. The schedule itself belongs to your management stack, not to this repo.

| path | cost | can it block? |
|---|---|---|
| `cat` of the written file | **0.09s** | no |
| `bin/discover` (live, composed) | 1.19s | not today; one added daemon-touching branch and yes |
| `bin/discover --deep` (live, wedged Docker) | 8.64s | bounded at the cost of the whole budget |
| `bin/discover --write` (the scheduled job) | 4.16s | nothing is waiting for it |

**On the write path each branch runs in its own process, and that is a reliability decision
rather than a performance one.** Composition saves ~0.47s of osqueryi startup per branch —
worth having when an attribute is waiting, worth nothing when a launchd job is. What it costs
is measured:

| one branch's table unavailable, as on an older osquery | result |
|---|---|
| composed, one statement | **0 rows**, exit 1, stdout `[\n\n]` — five bytes of valid, empty JSON |
| independent, one process per branch | **6 of 6 branches, 757 rows**; the bad branch contributes 0 |

Every query declares `min-osquery: 5.10.0`, so a missing table is a real deployment state.
Composed, one unavailable table makes a Mac report as though nothing is installed on it — and
a consumer that ignores exit status cannot tell that from a clean machine. The independent
writer costs 4.16s instead of 1.19s and cannot do that.

It also gives each branch its own `kind=scan` row, so "we could not look" is per branch instead
of all-or-nothing.

### How the scan scales

**Wall clock is flat in the number of images, and independent of their size.** Measured
against a fake daemon serving a varying count, best of three:

| images | scan |
|---|---|
| 10 | 0.478s |
| 50 | 0.464s |
| 200 | 0.466s |
| 1000 | 0.484s |

A hundredfold more images costs 6 milliseconds. The real store's 10 images occupy 44.56 GB
and scan in the same time as ten synthetic ones, so bytes on disk cost nothing either. What
the 0.58s end-to-end scan is actually made of, on this Mac:

| step | seconds |
|---|---|
| the guard, `curl /_ping` | 0.10 |
| osqueryi process startup | 0.35 |
| the `docker_images` query itself | 0.13 |
| **total** | **0.58** |

So the scan is fixed cost. Enumeration is free; **starting a process and asking a daemon
whether it is alive is the whole bill**, which is also why composing this into a second
invocation costs about half a second and no more.

**Payload is what scales, and it is the binding constraint.** With realistic identifiers —
random 64-char digests and varied repository names:

| images | framed EA | % of cap |
|---|---|---|
| 10 | 0.8 KB | 3% |
| 50 | 3.6 KB | 12% |
| 200 | 14.3 KB | 48% |
| 365 | 26.0 KB | 87% |
| 500 | 35.4 KB | **118%** |

**The 30KB cap binds at roughly 420 images**, holding steady at about 73 bytes per row. A Mac
with a few hundred images overruns the container EA long before it comes close to the ten
seconds.

Measure this with random digests or not at all. Sequential synthetic ids (`%064x` of a
counter) framed 1000 rows into 16.6 KB — 17 B/row, a quarter of the truth — because gzip
exploits a run of near-identical hex that a real digest never gives it. The first attempt at
this table used them and would have put the ceiling near 1800 images.

Note that `size_bytes` is the UNCOMPRESSED size. `ollama/ollama:latest` reports 6.98 GB from
a 2.78 GB download, so the figure `bin/container-scan --pretty` prints is disk footprint, not
transfer.

# Measured payload

Enumeration (D20) trades payload for not being wrong about the catalog. The Extension
Attribute cap is roughly 30KB, so the trade only holds if the payload fits, and these are
the numbers it was accepted on. Framed sizes below are gzip plus base64, which is what a
value channel with a size limit will cost you.

`tools/measure_payload.py` prints this per scenario on every Scenarios run. It fails over
the cap and warns above 80%.

## Clean runner, macOS 15.7.7 arm64

Scenario `00-baseline` on the hosted runner: no AI agents, no browser profiles.

| rows | raw | framed EA | % of cap |
|---|---|---|---|
| 582 | — | 12.2 KB | 41% |

`app=402, brew=121, daemon=23, file=22, port=12, npm=2`

**A clean machine is no longer a small payload**, which is the part of this trade worth
understanding. 402 apps and 121 Homebrew packages are macOS and the runner image, not
findings. Enumeration means every Mac reports its inventory whether or not it has an agent
on it.

## Loaded developer Mac

macOS 26, Apple Silicon, 392 apps, 136 Homebrew packages, 53 browser extensions.

| | rows | raw | framed EA | % of cap |
|---|---|---|---|---|
| filtered (before D20) | 76 | 9 KB | 2.6 KB | 9% |
| enumerated | 748 | 113.5 KB | 17.4 KB | 58% |

## Every scenario, same run

| scenario | rows | framed EA | % of cap |
|---|---|---|---|
| 00-baseline | 582 | 12.2 KB | 41% |
| 20-cli-agents | 585 | 12.3 KB | 41% |
| 50-autonomous | 584 | 12.3 KB | 41% |
| 55-openclaw-npm | 584 | 12.3 KB | 41% |
| 60-persistence | 586 | 12.3 KB | 41% |
| 25-python-agents | 589 | 12.3 KB | 41% |
| 10-desktop-apps | 592 | 12.7 KB | 42% |
| 40-browser | 590 | 12.8 KB | 43% |

The 10-desktop-apps row predates the split that moved `perplexity` into
11-perplexity-desktop, so it measures one more cask than that scenario now installs and
11-perplexity-desktop has no measured row here at all. NOT RE-MEASURED RATHER THAN
RE-ESTIMATED: every number in this table came off one run, and a subtracted guess sitting in
a measured column is exactly the kind of figure that later gets quoted as fact. Both settle
on the next full run.

Installing agents barely moves the number. The payload is dominated by inventory the
machine already had, so the marginal cost of a finding is close to nothing and the total
is set by how loaded the Mac is.

## Where the cap actually binds

**Catalog growth is free.** The query holds no identifiers, so adding agents costs zero
bytes. Verified rather than assumed: growing `catalog/agents.yaml` from 21 agents to 221 <!--fixed-number-->
left the composed artifact byte-identical and the framed payload unchanged at 17868 bytes.
Whatever limits this design, it is not how many agents we can name.

**Inventory growth is not free**, and that is the real constraint. Measured by extending
the reference Mac with structurally similar application rows:

| total rows | framed EA | % of cap | marginal |
|---|---|---|---|
| 748 | 17.4 KB | 58% | — |
| 998 | 25.4 KB | 85% | 32.6 B/row |
| 1248 | 33.4 KB | 111% | 32.6 B/row |

So the cap binds at roughly **1150 rows**, about 400 more than the reference Mac carries.
Two real inventories concatenated — this Mac plus the hosted runner, 1338 rows — land at
exactly **100%** of the cap. Headroom is real but it is not generous, and it is consumed
by how loaded a machine is rather than by anything about AI.

An earlier revision of this file put the marginal cost at 23 B/row and the ceiling near
1300 rows. That came from measuring random subsets, which breaks up the runs of similar
paths gzip exploits and understates the true marginal cost. Prefer the numbers above.

### The lever, and why it is not simply pulled

Applications dominate: **300 of 392 rows on the reference Mac are `/System/`**, stock
macOS rather than anything installed. Dropping them takes 58% to 34% of the cap, and 43%
to 19% on the runner. It is the single largest saving available and it is not a catalog
match, so it looks free.

It is not free. `/System/` carries `com.apple.GenerativePlaygroundApp`, `com.apple.Siri`,
`com.apple.siri.launcher` and Shortcuts, which are exactly the first-party AI surface an
AI-governance product should see. `browser.sql` already refused a blanket `com.apple.%`
exclusion on this reasoning and excluded a single manifest by name instead, so a blanket
exclusion here would contradict a decision this repo has already made deliberately.

If the payload needs to come down, exclude `/System/` by an argued rule that keeps the
Apple Intelligence surface, and record which bundles it keeps. Do not reach for the prefix.

## Fleet cost, which is the real tradeoff

EA values ride in every inventory submission and every `section=EXTENSION_ATTRIBUTES`
response. At 10,000 Macs per full sync:

| | per sync |
|---|---|
| filtered | 27 MB |
| enumerated | 179 MB |

That is the number to reject this design on, not the per-device cap. If it is
unacceptable, the fallback is deliberately coarse matching -- vendor prefixes and name
patterns rather than exact identifiers -- which keeps most of the benefit at a fraction of
the size, and which is still not a catalog on the device.
