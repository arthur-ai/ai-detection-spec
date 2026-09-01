# Measured cost

Best of three runs. The floor is the honest number: anything above it is scheduler noise,
and what we are looking for is a query that *blocks*, not a microbenchmark.

Bands: `fast` under 1s, `slow` 1 to 5s, `expensive` excluded from `dist/discovery.sql` and
composed into `dist/discovery-deep.sql` instead. `tools/measure.py --check` enforces them on
every pull request.

`expensive` covers two different facts. `python_packages` at 15.6s is **slow** — a number.
`docker_images` against a wedged daemon is **unbounded** — not a number, which is what
`measure.py`'s `float("inf")` ceiling admits. A slow query can be scheduled; an unbounded one
needs a process around it that can be killed. Neither belongs in `dist/discovery.sql`.

The gate fires at **2x the declared band**, not at the band itself. A band is a declaration
a reader can trust; the gate catches a query that *blocks*, which is an order-of-magnitude
event. Enforced at the same number, the boundary case flaps: `apps.sql` measured 0.81s and
1.14s on consecutive runs of the same commit on the same runner. A gate that fails at random
teaches people to re-run it, and then a real stall gets re-run too. 2x absorbs runner
variance and is still five times below the 10.2s stall this exists to catch.

The composed `dist/discovery.sql` is gated at 10s, and **that number is self-imposed.**

An earlier version of this file called it a platform limit. It is not: no macOS management
tool we checked documents a per-script timeout, and the evidence runs the other way — scripts
measured at 21 seconds, and inventory collection *stalling* rather than being cut off. An
unbounded collection script does not fail fast; it hangs that machine's inventory.

So the gate stays as a convention: 10s keeps collection brisk, and the real requirement is
that nothing on a synchronous reporting path can block forever. The better answer is not to
run a blocking query on that path at all — see the scheduled writer below.

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
| `dist/discovery.sql` | composed | 1.20 | 0 |

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
| `dist/discovery.sql` | composed | 1.07 | 76 |

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

## The container scan, and why it runs in its own process

`bin/container-scan` is the only supported way to run `dist/discovery-deep.sql`. It carries
the two things SQL cannot express: a round trip demanding HTTP 200, and a wall-clock kill.

Measured against `test/lib/fake_docker.py`, default bound (`CONTAINER_SCAN_TIMEOUT=6`):

| daemon state | `bin/container-scan` | exit | value |
|---|---|---|---|
| no socket anywhere | 0.18s | 2 | one `scan` row, `extra=absent` |
| stale socket / not a socket | 0.19s | 2 | one `scan` row, `extra=absent` |
| accepts, never replies | 0.19s | 2 | one `scan` row, `extra=unhealthy:000` |
| answers 500 | 0.20s | 2 | one `scan` row, `extra=unhealthy:500` |
| **pings 200, then never serves** | **7.36s** | **3** | one `scan` row, `extra=timeout:6` |
| healthy, 3 images | 0.51s | 0 | the image rows |

7.36s is 0.04s probe + the 6s bound (osqueryi's 0.5s startup is *inside* it, so do not add
them) + 0.35s to die + polling slop. Against a ten-second budget that leaves 2.6s; a bound
above 8 does not fit. Raise it only with a measurement showing the daemon is slow rather than
wedged.

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
| 30-local-models | 591 | 12.5 KB | 42% |
| 10-desktop-apps | 592 | 12.7 KB | 42% |
| 40-browser | 590 | 12.8 KB | 43% |

The 10-desktop-apps row is from a run where that scenario installed seven casks. It now
installs six -- `perplexity` was split into 11-perplexity-desktop for its macOS >= 15
floor -- so that figure is high by roughly one app's worth of rows, and 11-perplexity-desktop
has no measured row here at all. NOT RE-MEASURED RATHER THAN RE-ESTIMATED: every number in
this table came off one run, and a subtracted guess sitting in a measured column is exactly
the kind of figure that later gets quoted as fact. Both settle on the next full run.

Installing agents barely moves the number. The payload is dominated by inventory the
machine already had, so the marginal cost of a finding is close to nothing and the total
is set by how loaded the Mac is.

## Where the cap actually binds

**Catalog growth is free.** The query holds no identifiers, so adding agents costs zero
bytes. Verified rather than assumed: growing `catalog/agents.yaml` from 21 agents to 221 <!--fixed-number-->
left `dist/discovery.sql` byte-identical and the framed payload unchanged at 17868 bytes.
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
