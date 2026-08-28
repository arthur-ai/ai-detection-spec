# Measured cost

Best of three runs. The floor is the honest number: anything above it is scheduler noise,
and what we are looking for is a query that *blocks*, not a microbenchmark.

Bands: `fast` under 1s, `slow` 1 to 5s, `expensive` over 5s and excluded from
`dist/discovery.sql`. `tools/measure.py --check` enforces them on every pull request.

The gate fires at **2x the declared band**, not at the band itself. A band is a declaration
a reader can trust; the gate catches a query that *blocks*, which is an order-of-magnitude
event. Enforced at the same number, the boundary case flaps: `apps.sql` measured 0.81s and
1.14s on consecutive runs of the same commit on the same runner. A gate that fails at random
teaches people to re-run it, and then a real stall gets re-run too. 2x absorbs runner
variance and is still five times below the 10.2s stall this exists to catch.

The composed `dist/discovery.sql` has no tolerance: 10s is the Extension Attribute's actual
limit, not a target.

An Extension Attribute gets roughly ten seconds and 30KB. Overrun either and the machine
reports nothing, which is indistinguishable from a machine with nothing on it. That is why
this is a build gate and not a review note.

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

## What neither baseline covers

**A machine without the dependency installed is not a valid baseline.** A `docker_images`
branch measures 0.35s with Docker absent and **10.24s with Docker installed but not
answering**, returning zero rows in both cases. The hosted runner has no Docker, so CI
asserts the absent case only. The stopped and mid-startup states need a local or
self-hosted run.

If your query touches a daemon, socket or external service, measure it stopped and
mid-startup before you trust either table above.

# Measured payload

Enumeration (D20) trades payload for not being wrong about the catalog. The Extension
Attribute cap is roughly 30KB, so the trade only holds if the payload fits, and these are
the numbers it was accepted on. Framing is `arthur1.<base64(gzip(json))>`.

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

Installing agents barely moves the number. The payload is dominated by inventory the
machine already had, so the marginal cost of a finding is close to nothing and the total
is set by how loaded the Mac is.

## Where the cap actually binds

**Catalog growth is free.** The query holds no identifiers, so adding agents costs zero
bytes. Verified rather than assumed: growing `catalog/agents.yaml` from 21 agents to 221
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
