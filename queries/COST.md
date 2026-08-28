# Measured cost

Best of three runs. The floor is the honest number: anything above it is scheduler
noise, and what we are looking for is a query that *blocks*, not a microbenchmark.

Reference machine: macOS 26.6.2, Apple Silicon, 34 applications installed, Docker
present but not running. **A machine without the dependency installed is not a valid
baseline** — that is the state that hid a ten-second stall for a week.

| query | band | seconds | rows |
|---|---|---|---|
| `apps.sql` | fast | 0.57 | 4 |
| `browser.sql` | fast | 0.56 | 67 |
| `filesystem.sql` | fast | 0.24 | 4 |
| `packages.sql` | fast | 0.29 | 1 |
| `runtime.sql` | fast | 0.38 | 0 |
| `dist/discovery.sql` | composed | 1.07 | 76 |

Bands: `fast` under 1s, `slow` 1 to 5s, `expensive` over 5s and excluded from
`dist/discovery.sql`. `tools/measure.py --check` enforces them and runs on every pull
request.

An Extension Attribute gets roughly ten seconds and 30KB. Overrun either and the machine
reports nothing, which is indistinguishable from a machine with nothing on it.
