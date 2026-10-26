# Measured cost

**These are records, not live figures.** Each section names the machine and, where known,
the date. Two things are checked on every run: `osquery/tools/measure.py --check` enforces
the bands below on every pull request, and `osquery/tools/measure_payload.py` prints each
scenario's payload on every Scenarios run and fails over the cap. Nothing checks the numbers
on this page, so re-measure rather than extrapolate.

Bands: `fast` under 1s, `slow` 1 to 5s, `expensive` excluded from the composed artifacts and
composed into `osquery/dist/discovery-deep.sql` instead. `expensive` covers two facts: a slow
query such as `python_packages` at 15.6s, and an **unbounded** one, `docker_images` against a
wedged daemon, which needs a process around it that can be killed.

The gate fires at **2x the declared band**. It exists to catch a query that blocks, and a gate
at the band itself flaps: `apps.sql` measured 0.81s and 1.14s on consecutive runs of one
commit.

The composed artifact is held to **10s, a self-imposed convention** (root `CLAUDE.md`). The
real requirement is that nothing on a synchronous reporting path can block forever, which is
why [the deployment page](../docs/deployment.md) schedules `--write` instead.

## Linux

### Hosted runner

GitHub-hosted `ubuntu-24.04`, Ubuntu 24.04.4 LTS x86_64, osquery 5.23.1: 1212 deb packages,
438 systemd units, 12 desktop entries, no agents.

| query | band | seconds | rows |
|---|---|---|---|
| `browser.sql` | fast | 0.05 | 0 |
| `desktop-linux.sql` | fast | 0.22 | 13 |
| `filesystem-linux.sql` | fast | 0.22 | 10 |
| `native-messaging-linux.sql` | fast | 0.22 | 0 |
| `packages-linux.sql` | fast | 0.26 | 1211 |
| `packages.sql` | fast | 0.26 | 13 |
| `ports.sql` | fast | 0.24 | 0 |
| `runtime-linux.sql` | slow | **1.03** | **478** |
| `vscode.sql` | fast | 0.23 | 0 |
| `containers.sql` | expensive | 0.22 | 0 |
| `osquery/dist/discovery-linux.sql` | composed | 1.12 | 1726 |
| `osquery/dist/discovery-deep.sql` | deep | 0.22 | 0 |

**Cold, the composed artifact took 8s, 9s, 12s and 14s** across four CI runs, at or over the
10s convention, and 3s to 25s across 19 runs. The 1.12s above is `measure.py`'s **warm
floor**: best of three, unprivileged, after a baseline step that has just read the same dpkg
database, unit list and desktop entries. The cold number is what an endpoint's first scan
pays. So the CI gate warns above the budget and fails only at 60s (`QUERY_FAIL_S` in
`ci.yml`): a hard gate at the budget went red at 12s and green at 9s on identical code. The
macOS artifact is 1.65s cold against 1.22s warm. The Linux gap comes from `deb_packages` (a
~5MB database) and `systemd_units` (a D-Bus round trip per unit), and has not been isolated
further.

### `runtime-linux.sql`

**It is banded `slow` because a shared-core VM measured it at 5.54s** (below). Its 478 rows
are 28% of the payload, and `systemd_prefixes` carries no catalog values, so today none of
them can match. That is the first thing to cut if the payload or the time must come down.
It has not been cut because an unrecognised unit running unattended is worth seeing, the
argument that keeps 47 third-party launchd jobs on macOS, and because no structural filter
works (the query says why). Revisit if the payload nears its budget or an agent unit enters
the catalog.

### Compute Engine `e2-small`, 2026-10-04

Stock images, OS Login on, osquery 5.23.1, run by `test/run-gce.sh` before any scenario
installed anything. Shared-core, 2 vCPU, under 2GB. Floors of three; `measure.py --check`
passed on every VM.

| query | Debian 12 | Ubuntu 24.04 | Rocky 9.8 |
|---|---|---|---|
| `packages-linux.sql` | 0.24s, 361 rows | 0.24s, 595 | 0.61s, 406 |
| `runtime-linux.sql` | 0.78s, 241 | 1.18s, 449 | 1.23s, 258 |
| every other Linux query | 0.23–0.26s | 0.24–0.26s | 0.24–0.26s |
| `osquery/dist/discovery-linux.sql` | 0.82s, 620 | 1.22s, 1065 | 1.71s, 671 |

Cold: 1.3s, 1.7s and 2.4s. `osquery/bin/discover --write`: 3.9s, 4.3s and 5.1s.

**A second Rocky VM the same afternoon measured `runtime-linux.sql` at 5.54s** and the
composed artifact at 9.24s warm, 13.96s cold. On a shared core, read the composed figure as
"usually two seconds, occasionally fourteen".

### EC2 `t3.small` and `t4g.small`, 2026-10-21

Stock Amazon Linux 2023 and Ubuntu 24.04, osquery 5.23.1, run by `test/run-ec2.sh` before any
scenario installed anything. 2 vCPU, 2GB, burstable. Floors of three; `measure.py --check`
passed on every instance.

**Unlimited credits** (the default, full speed):

| query | AL2023 `t3.small` | AL2023 arm64 `t4g.small` | Ubuntu 24.04 `t3.small` |
|---|---|---|---|
| `packages-linux.sql` | 0.53s, 495 rows | 0.68s, 492 | 0.25s, 652 |
| `runtime-linux.sql` | 1.23s, 296 | 1.52s, 286 | 0.97s, 395 |
| every other Linux query | 0.23–0.28s | 0.04–0.31s | 0.03–0.29s |
| `osquery/dist/discovery-linux.sql` | 1.73s, 801 | 2.22s, 788 | 1.08s, 1068 |

Cold: 2.8s, 2.3s and 1.6s. `--write`: 5.8s, 4.6s and 5.0s. A second AL2023 `t3.small`: 3.0s
and 6.0s.

**Standard credits, held to the 20% baseline.** A fresh instance has no credits; the harness
kept every vCPU busy until the hypervisor throttled it (80% and 78% steal), and the scan then
saw 49–57% steal on every step:

| | AL2023 `t3.small` | AL2023 arm64 `t4g.small` |
|---|---|---|
| composed artifact, cold | 11.9s | 10.2s |
| composed artifact, warm | 10.1s | 8.7s |
| `osquery/bin/discover --write` | 16.2s | 14.0s |
| floor, `runtime-linux.sql` | 2.15s | 3.90s |
| floor, `osquery/dist/discovery-linux.sql` | 4.26s | 5.21s |

A single held run is four to five times slower, but its floors only about twice, because a
throttled instance earns back a little credit between short runs. `--write` stayed inside
every branch's 30s bound; the composed artifact did not stay under 10s cold. On the held
`t4g.small`, `packages-linux.sql` ran over its `fast` band (1.85s), within the 2x tolerance.

## macOS

### Hosted runner

GitHub-hosted `macos-15`, macOS 15.7.7 arm64, 26 applications, 117 Homebrew formulae,
osquery 5.23.1, pinned so an image reissue shifts these visibly.

| query | band | seconds | rows |
|---|---|---|---|
| `apps.sql` | fast | 0.81 | 0 |
| `browser.sql` | fast | 0.25 | 0 |
| `filesystem.sql` | fast | 0.25 | 0 |
| `packages.sql` | fast | 0.24 | 0 |
| `runtime.sql` | fast | 0.47 | 0 |
| `osquery/dist/discovery-darwin.sql` | composed | 1.20 | 0 |

The runner has no agents and no browser profiles, so this is the empty case: a query slow
only when it has rows would pass here.

### A loaded developer Mac

macOS 26, Apple Silicon, Docker installed but not running, several browser profiles.

| query | band | seconds | rows |
|---|---|---|---|
| `apps.sql` | fast | 0.56 | 4 |
| `browser.sql` | fast | 0.56 | 67 |
| `filesystem.sql` | fast | 0.24 | 4 |
| `packages.sql` | fast | 0.29 | 1 |
| `runtime.sql` | fast | 0.38 | 0 |
| `osquery/dist/discovery-darwin.sql` | composed | 1.07 | 76 |

Later additions, 2026-10-07: `jetbrains.sql` 0.39s for 0 rows (no JetBrains IDE);
`running.sql` 0.25s for 0 and `running-darwin.sql` 0.24s for 62; the composed artifact 1.51s
for 865. In an Ubuntu container, one `bun add -g @google/gemini-cli` produced 6 `packages.sql`
rows, because bun hoists a global's dependencies.

## Deliberately not collected

`python_packages`: 15.6s per scan, no WHERE push-down. It took the full query from 2.0s to
78s. If it is ever wanted, it belongs in the scheduled writer.

**A machine without the dependency is not a baseline for a query that touches one.**
`docker_images` measures 0.35s with Docker absent and 10.24s with Docker installed and not
answering, zero rows both times. The hosted runners have no Docker. Measure a daemon-touching
query stopped and mid-startup before trusting any table here.

## Containers

### Against a live daemon, 2026-09-11

macOS 15, Docker 28.4.0, osquery 5.23.1, 18 images, 1 running container, 6 label rows,
`osquery/dist/discovery-deep.sql` three times: **0.67s, 0.54s, 0.52s**, 25 rows. Not
measured: many running containers (`docker_containers` inspects each) or many labels per
image. A twenty-container Compose stack is the case to measure before trusting this.

### Per daemon state, 2026-09-14

Against `osquery/test/lib/fake_docker.py`, shipped defaults (`CONTAINER_SCAN_TIMEOUT=6`,
`DOCKER_PING_TIMEOUT=8`):

| daemon state | `osquery/bin/container-scan` | exit | value |
|---|---|---|---|
| no socket anywhere | 0.10s | 2 | one `scan` row, `extra=absent` |
| stale socket / not a socket | 0.12s | 2 | one `scan` row, `extra=absent` |
| answers 500 | 0.12s | 2 | one `scan` row, `extra=unhealthy:500` |
| asleep, wakes in 3s (`nap`) | 3.62s | 0 | the image rows |
| **accepts, never replies** | **8.17s** | **2** | one `scan` row, `extra=unhealthy:000` |
| **pings 200, then never serves** | **7.88s** | **3** | one `scan` row, `extra=timeout:6` |
| healthy, 6 images | 0.58s | 0 | 8 rows plus the `ok` marker |

- **Accepts-never-replies is the only state that waits out the whole ping budget**, so it
  costs the budget. The budget is 8s because a Resource Saver wake took 2.6s (the
  [containers page](../docs/containers.md) has the mechanism); every answering state returns
  in about a tenth of a second whatever it is set to.
- **Pings-then-never-serves costs** the 0.04s probe, plus the 6s bound with `osqueryi`'s 0.5s
  startup inside it, plus up to 1s of SIGKILL grace. A bound above 8 would not fit a 10s
  budget.
- **Inside the bound, daemon latency costs, not inventory size.** `osquery`'s own side is
  0.23s at 18 images and 0.55s at 10,000. One scan makes three engine requests, so a daemon
  answering in 1s per request scans in 3.53s, and at 3s per request it does not fit.
- **Folding the branch into the composed query loses the evidence that it went unread.**
  Third arm of six, wedged daemon, killed at 6s: all 757 base rows came back and `osqueryi`
  exited 0, in 7.21s against 1.19s.

| | wedged daemon | healthy | base only |
|---|---|---|---|
| one EA (`osquery/bin/discover --deep`) | 8.64s | 1.77s | — |
| inventory EA (`osquery/bin/discover`) | 1.10s | 1.10s | 1.10s |
| container EA (`osquery/bin/container-scan`) | 7.36s | 0.51s | — |

Where budgets are per value rather than pooled, two attributes give each half its own. A Mac
with no Docker returns its marker in 0.18s, so scope a container attribute to Macs that have
Docker.

### Removing `python3` from the endpoint

An `osqueryi` spawn costs ~0.24s against an interpreter's ~0.03s. Five runs each, old and
new interleaved on one Mac (not the Mac above, so read the deltas):

| | old (python3) | new (osqueryi) | delta |
|---|---|---|---|
| `osquery/bin/discover` | 1.40s | 1.37s | — |
| `osquery/bin/discover --deep`, healthy | 2.43s | 2.67s | **+0.24s**, the base/deep join |
| `osquery/bin/discover --deep`, wedged | 9.69s | 9.63s | — |
| `osquery/bin/container-scan`, healthy | 1.01s | 0.99s | — |
| `osquery/bin/discover --write` | 6.99s | 5.55s | **−1.44s**, one pack read instead of eleven |

### How the scan scales

Wall clock is flat in the number of images and independent of their size, against a fake
daemon, best of three: 0.478s at 10 images, 0.464s at 50, 0.466s at 200, 0.484s at 1000. The
0.58s end-to-end scan is 0.10s for the `/_ping` guard, 0.35s of `osqueryi` startup and 0.13s
for the query.

**Payload is what scales.** Framed, with random 64-character digests and varied names:

| images | framed EA | % of cap |
|---|---|---|
| 10 | 0.8 KB | 3% |
| 50 | 3.6 KB | 12% |
| 200 | 14.3 KB | 48% |
| 365 | 26.0 KB | 87% |
| 500 | 35.4 KB | **118%** |

About 73 bytes per row, so the 30KB cap binds near 420 images, long before the clock. Measure
with random digests: sequential ones framed at a quarter of the true size, because gzip
exploits near-identical hex. Two real stores gave 84 bytes per row against 32.6 for an
application row. `loc` is a digest, and digests do not compress. `extra` is `size_bytes`,
the uncompressed size, not the download.

## The scheduled writer

| path | cost | can it block? |
|---|---|---|
| `cat` of the written file | **0.09s** | no |
| `osquery/bin/discover` (live, composed) | 1.19s | not today; one daemon-touching branch and yes |
| `osquery/bin/discover --deep` (live, wedged Docker) | 8.64s | bounded, at the cost of the whole budget |
| `osquery/bin/discover --write` (the scheduled job) | 4.16s | nothing is waiting for it |

Each branch in its own process costs ~0.47s of `osqueryi` startup per branch, and buys this:

| one branch's table unavailable, as on an older osquery | result |
|---|---|
| composed, one statement | **0 rows**, exit 1, stdout `[\n\n]` |
| independent, one process per branch | **6 of 6 branches, 757 rows**; the bad branch contributes 0 |

Most queries need 5.10.0, `vscode.sql` 5.11.0 and `jetbrains.sql` 5.18.0, so a missing table
is a real deployment state.

## Payload

Enumeration trades payload for never being wrong about the catalog on the device, so it holds
only if the payload fits. Framed sizes are gzip plus base64. The cap is the 30KB
Extension Attribute convention.

**A hosted macOS runner (`00-baseline`)**: 582 rows, 12.2 KB framed, 41% of the cap
(`app=402, brew=121, daemon=23, file=22, port=12, npm=2`). A clean machine is not a small
payload: macOS and the runner image are most of it.

**A loaded developer Mac** (392 apps, 136 Homebrew packages, 53 browser extensions):

| | rows | raw | framed EA | % of cap |
|---|---|---|---|---|
| filtered (before enumeration) | 76 | 9 KB | 2.6 KB | 9% |
| enumerated | 748 | 113.5 KB | 17.4 KB | 58% |

**Installing agents barely moves it.** One run of every scenario then shipping landed between
582 and 592 rows, 41% to 43% of the cap.

### Where the cap binds

**Catalog growth is free**: growing `catalog/agents.yaml` from 21 agents to 221 left the <!--fixed-number-->
composed artifact byte-identical and the payload unchanged.

**Inventory growth is not.** Extending the loaded Mac with application rows:

| total rows | framed EA | % of cap | marginal |
|---|---|---|---|
| 748 | 17.4 KB | 58% | — |
| 998 | 25.4 KB | 85% | 32.6 B/row |
| 1248 | 33.4 KB | 111% | 32.6 B/row |

The cap binds near 1150 rows. Measure marginal cost by extending a real inventory; random
subsets break up the runs gzip exploits and understate it.

**The lever, and why it is not pulled.** 300 of the 392 apps on that Mac are under
`/System/`, and dropping them takes 58% to 34%. But `/System/` carries
`com.apple.GenerativePlaygroundApp`, Siri and Shortcuts, the first-party AI surface an
inventory should see, which is why `native-messaging.sql` excludes one Apple bridge by name
rather than by prefix. If the payload must come down, exclude `/System/` by a rule that keeps
that surface and records what it keeps.

**Fleet cost is the real trade.** Extension Attribute values ride in every inventory
submission: at 10,000 Macs per full sync, 27 MB filtered against 179 MB enumerated. If that
is unacceptable, the fallback is coarse matching off the device (vendor prefixes and name
patterns), not a catalog on it.
