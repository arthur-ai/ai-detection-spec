# Working in this repo

This repo holds **osquery materials only**: the queries, the composed artifacts, the catalog,
and the scripts that run them. Deployment glue for a particular MDM belongs to whoever wraps
these artifacts, not here.

## The one rule everything else follows

**An empty result must never be indistinguishable from a clean machine.** Nearly every bug this
repo has shipped was a wrong answer that looked like a right one:

- A bounded `osqueryi` that is SIGTERM'd **exits 0 and prints `[\n\n]`** — a valid, empty,
  entirely plausible result. **The kill decides, not the child.** A bounded query must discard
  its own output, because the output of a killed query is a lie.
- A Docker daemon can answer `200` on `/_ping` and then never serve `/images/json`. A health
  check is necessary and **not sufficient**; that state is `wedge` in `test/lib/fake_docker.py`.
- `$HOME` unguarded under `set -u` crashed the socket probe, which reported `containers=absent`
  on a Mac with a healthy daemon — a plausible answer manufactured by a crash.
- A `kind` absent from `KIND_ROUTES` in `bin/classify` is **dropped, not unmatched** — invisible
  even under `--show-unmatched`. `ext` sat like that from the beginning; Claude was still
  reported via its native-messaging bridge, so nothing looked wrong.

So: every failure carries a reason. That is what `kind=scan` marker rows are for, and their
vocabulary — `ok`, `absent`, `unhealthy:<code>`, `timeout:<n>`, `error`, `no-cache`,
`stale:<n>` — is a contract, not a log format.

## Facts, not documentation

**Identifiers are read off real installs.** We shipped `bot.molt.mac` for OpenClaw straight from
the vendor's own Homebrew metadata and it matched nothing on any Mac; the real id is
`ai.openclaw.mac`. `aider` installs as `aider-chat` under `uv` and `pipx` while its state dir is
`~/.aider`, so evidence and signature never met. Both were silent, and neither survived contact
with an actual install.

**The catalog detects agents.** Something that acts on a user's behalf. An MCP SDK is a
library an agent is built with and LiteLLM is a gateway an agent calls through; both were
catalogued, both were easy to detect, and both were removed, because counting them among
"agents found on this Mac" overstates the finding. Their rows stay in the fixtures as negative
controls, asserted to arrive and be declined — the only way to tell *correctly not an agent*
from *route quietly broken*. Docker Desktop went the same way, and the reason
generalises: what we detect inside a container is the agent **image** — the runtime is how we
look, not what we look for — and whether Docker is present is already answered better by the
`kind=scan` marker, which distinguishes *no Docker* from *Docker wedged* as a bundle id cannot.
One non-agent classification remains, marked in `not_agents`: a **local model** server is the
inference capability an agent runs against, not a library describing one.

**A real install is the standard, and the catalog enforces it.** An agent is verified when a VM
scenario installs the real software and asserts the classifier finds it. Anything less is an
exception carrying a `reason`, an `evidence` grade and the date it was raised;
`tools/validate_catalog.py` fails on an agent that has neither. `docs/agents.md` is generated
from that, so the exception register is a work list rather than an excuse list — and a fixture
is not a weaker pass but a different claim, because it proves the matcher works and says nothing
about whether the identifier is what the software ships today.

When something genuinely cannot be verified, say so in the tree rather than guessing —
`docs/signature-lifecycle.md` covers how, and the standing rule is that **a catalog may carry a
guess but may not hide one.**

Two numbers this project treats as conventions, because Jamf documents neither: the **10s EA
timeout** and the **30KB EA value cap**. Both are self-imposed. Do not restate them as platform
limits.

## Architecture, briefly

The endpoint **enumerates**; it holds no catalog and does no filtering. Matching happens off the
machine, in `bin/classify`, against `catalog/agents.yaml`. That is what lets a new signature
re-match evidence already collected, and it is why `tools/check_no_catalog.py` fails the build if
an agent identifier leaks back into the SQL.

Every row is the **six-column contract**: `kind, id, ver, loc, extra, perms`.

**Four things ship and they are not the same query.**

| artifact | what it is |
|---|---|
| `dist/discovery.sql` | the composed `fast` + `slow` queries |
| `dist/discovery-deep.sql` | the `expensive` queries — a **supplement, not a superset** |
| `dist/ai-discovery.conf` | the pack; additionally carries `containers.sql` |
| `bin/container-scan` | not a query. The only supported way to run the deep artifact, because that artifact can block forever and the bound lives in the runner |

`dist/` is **generated**. Edit `queries/`, then `python3 tools/build.py`; `--check` gates it.

## Traps that have already cost a day

- **`UNION ALL` takes its column names from the first arm only.** An unaliased first arm inherits
  whatever precedes it — which is `apps.sql` inside `dist/discovery.sql`, and nothing standalone.
  This shipped: the pack's browser query returned columns named `'ext'` and
  `permissions || CASE WHEN…`. `check_pack.py` counted rows and passed it; `lint.sh` counted
  columns and passed it. Both now check names. **Alias every first arm.**
- **`CROSS JOIN` is mandatory** for user-scoped tables. A plain `JOIN … USING (uid)` returns zero
  rows, silently — osquery needs the uid constraint pushed in.
- **A single `%` matches one path component.** `Application Support/Google/Chrome/…` is two.
- **Bash 3.2** is what a managed Mac has. No `timeout(1)`, and an empty array under `set -u` is an
  unbound-variable error: append with `+=` and expand as `${a[@]+"${a[@]}"}`.
- **`identifier` is derived from the manifest `key`.** That is why a planted or unpacked
  extension reports an EMPTY one — it has no key. The consequence is not that ids are
  untestable: the Web Store's signed CRX *does* carry the key, so unpacking one into a real
  profile yields the real id, and `45-claude-extension` does exactly that. Chromium ids are
  key-derived, so they are identical across all 11 `browser_type`s osquery enumerates.

## Testing

```console
$ test/lint.sh                      # contract, first-arm aliases, kind coverage
$ python3 tools/build.py --check    # dist/ matches queries/
$ python3 tools/validate_catalog.py
$ python3 tools/check_no_catalog.py
$ python3 test/test_matcher.py
$ sudo test/docker_states.sh        # every daemon state, guard and bound (~31s)
$ sudo python3 tools/check_pack.py  # every pack query actually returns rows
```

**Assert on what must NOT match, not only on what must.** `libxdmcp` must not be claimed by the
`mcp` signature; a fork must not be claimed as the real image. Only that shape of assertion can
tell *correctly declined* from *never looked at* — which is precisely the difference the `ext`
bug hid behind.

**Verify a test by breaking the thing it covers.** A multi-tag assertion here was vacuous for
months because its fixture had no agent on either tag. If removing the code does not turn the
test red, the test proves nothing.

VM scenarios (`test/run.sh`) need Tart and run on dispatch and a schedule, not per PR. Where something genuinely cannot be
tested, a scenario `exit 3`s to SKIP with the reason in `requires.json` — but **be slow to
conclude that.** This repo asserted that the Claude extension could not be installed without
MDM, and was wrong twice over: Chrome had never been launched, so no profile existed to read,
and the browser's install flow was never needed in the first place. A scenario that fails where nobody can act on it trains people to ignore a red
suite.

## Register

State the measurement, then the consequence. Where a number is unverified, say so rather than
rounding it into fact. Comments in this repo carry the reasoning and the rejected alternative,
because the *why* is the part that stops the bug coming back — see the headers of
`queries/browser.sql` and `catalog/agents.yaml` for the house style.
