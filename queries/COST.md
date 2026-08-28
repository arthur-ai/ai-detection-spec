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
