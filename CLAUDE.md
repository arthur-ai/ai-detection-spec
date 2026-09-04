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
vocabulary — `ok`, `absent`, `unhealthy:<code>`, `timeout:<n>`, `error`, `no-cache` — is a
contract, not a log format.

**`stale:<n>` was in that list and is now retired**, because nothing ever emitted it. It was
documented here, in `docs/deployment.md` and accepted by `ci.yml`'s vocabulary check, while no
writer produced it — a contract term with no producer, which is the same class of claim as an
identifier no test can generate. Staleness is already carried better: every marker row's `ver`
holds the unix time of the scan, and `bin/classify` computes the age from it. That way the
reader's threshold is the reader's, rather than one the writer had to guess at.

## Facts, not documentation

**Identifiers are read off real installs.** We shipped `bot.molt.mac` for OpenClaw straight from
the vendor's own Homebrew metadata and it matched nothing on any Mac; the real id is
`ai.openclaw.mac`. `aider` installs as `aider-chat` under `uv` and `pipx` while its state dir is
`~/.aider`, so evidence and signature never met. Both were silent, and neither survived contact
with an actual install.

## The scope is agents, and only agents

**An agent is something that acts on the user's behalf.** That is the whole test. It is not
"is this AI software" and not "can we detect it" — everything removed below passed both and
was removed anyway.

| removed | what it actually is |
|---|---|
| `mcp-sdk` | a **library an agent is built with**. Detecting it says a developer imported a protocol |
| `litellm` | a **gateway an agent calls through**. Detecting it says traffic may be proxied |
| `docker` | a **runtime**: how we look, not what we look for. What we detect in a container is the agent *image* |
| `ollama`, `lm-studio`, `jan`, `llama-cpp` | **model runners**. They serve language models; an agent is what drives one |

Each was easy to detect and each belongs in *some* AI inventory, which is exactly why the
reasoning is written into `catalog/agents.yaml`'s header rather than left to memory — the
temptation to re-add them is obvious. **Counting them among "agents found on this Mac"
overstates the finding**, and that is the one error this repo exists to avoid.

Two consequences worth knowing before you extend anything:

- **A removed entry keeps its fixture rows**, and the assertion inverts to *must not match*.
  Deleting the evidence with the signature leaves nothing to tell *correctly not an agent*
  from *route quietly broken* — which is the ambiguity the dropped `ext` kind hid behind for
  months. `25-python-agents` still installs LiteLLM for exactly this reason.
- **A query branch that no agent can be found through is payload nobody can read.** The
  `model` branch went when the model runners did: it emitted a row per model manifest, and
  `bin/classify` never had a `model` key in `KIND_ROUTES`, so every one of those rows was
  *dropped* — the same failure as `ext`, undetected because the row counts were right.

If the scope widens, the model runners are the strongest candidates to return, and the
`model` branch with them.

**NOTHING SHIPS IN THE CATALOG WITHOUT A REAL TEST**, and `tools/agent_status.py --gate`
enforces it in lint; `docs/agents.md` carries the current figure, counted rather than typed. An identifier that no test produces is
not a signature, it is a guess with a comment beside it — and the two are indistinguishable
until something tries to install it. Both catalog bugs found this way had one: npm `mcp` was
Mintlify's package, and npm `aider` is *"Lightweight website popular article component for
static website"*, sitting under a note reading "the usual route; the npm name differs", which
explained the discrepancy instead of questioning it.

`tools/agent_status.py` reports coverage **per identifier and against CI**, because a scenario
that only runs on a maintainer's Mac catches nothing on a pull request. Its most useful state
is **`did not appear`**: a CI scenario installed the agent and this identifier never showed up.
That means one of three things, and they are worth telling apart —

| it means | what to do |
|---|---|
| the scenario installs by another route | install that route, on **another machine** — two routes claiming one binary name cannot share a host |
| the artifact only exists once the agent **runs** | invoke it; a state directory does not exist until first run |
| **the identifier is wrong** | remove it. This is how both catalog bugs surfaced |
| **the route cannot identify at all** | remove the route. A listening port only matches when the process holding it already names the agent, so it is a second opinion from the same witness — `ports` was retired for that |

An identifier that genuinely cannot be covered goes under `untested:` with a reason and a
date. That list can shrink silently and never grow silently: an entry whose identifier *is*
covered fails the gate, so a reason cannot outlive the gap it excused.

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

**`catalog/routes.yaml` is the route registry, and adding a route there is the whole edit.** The
vocabulary used to live in five hardcoded lists that had to agree — `validate_catalog`'s
`ROUTES`, `classify`'s `KIND_ROUTES`, `agent_status`'s `EXACT_KINDS`/`GLOB_ROUTES`/`ALL_ROUTES`,
and `lint.sh`'s `KINDS` — and `ext` was missing from one of them from the beginning. All four
derive from the file now. It carries **no field nothing reads**: `purl` and version-semantics
were both left out for that reason, and its header says so.

**The composed artifact is per platform, and there is no unqualified one.**

| artifact | what it is |
|---|---|
| `dist/discovery-darwin.sql` | the composed `fast` + `slow` queries for macOS |
| `dist/discovery-linux.sql` | the same for Linux. **Not a superset of anything** — a different set of tables |
| `dist/discovery-deep.sql` | the `expensive` queries — a **supplement, not a superset**. One file, because every expensive query is `posix`; `build.py` fails loudly if one stops being |
| `dist/ai-discovery.conf` | the pack, carrying every platform's queries with osqueryd's own per-query `platform` field |
| `bin/container-scan` | not a query. The only supported way to run the deep artifact, because that artifact can block forever and the bound lives in the runner |

**`dist/discovery.sql` is gone.** It named one platform while claiming none, and fed to the wrong
`osqueryi` it returns `[\n\n]` — five bytes of valid, empty, plausible JSON. It does at least
exit 1, which is the only reason that state is recoverable; `bin/discover` picks by `uname -s`.

A query declares `-- platform: darwin | linux | posix`, where `posix` means both and is
osqueryd's own word for it. The value is **checked** against `catalog/routes.yaml` now: it never
was, so `-- platform: macos` built clean and shipped a pack query osqueryd silently never
scheduled.

`dist/` is **generated**. Edit `queries/`, then `python3 tools/build.py`; `--check` gates it,
in both directions — a stale artifact and an artifact nothing generates are the same drift.

## Traps that have already cost a day

- **`UNION ALL` takes its column names from the first arm only.** An unaliased first arm inherits
  whatever precedes it, and composition is per platform now — so which file leads an artifact
  depends on the platform, and a file can lead one artifact and sit mid-way through another.
  This shipped: the pack's browser query returned columns named `'ext'` and
  `permissions || CASE WHEN…`. `check_pack.py` counted rows and passed it; `lint.sh` counted
  columns and passed it. Both now check names. **Alias every first arm.**
- **`CROSS JOIN` is mandatory** for user-scoped tables. A plain `JOIN … USING (uid)` returns zero
  rows, silently — osquery needs the uid constraint pushed in.
- **A single `%` matches one path component.** `Application Support/Google/Chrome/…` is two.
- **`/root` is not under `/home`,** so a Linux path glob needs its own branch for it. A
  `%`-component cannot reach it, and an agent installed from a root shell is exactly what that
  silence would hide.
- **Some tables fail SOFT, which is worse than failing.** `systemd_units` with no reachable
  system bus logs to stderr, returns **zero rows**, and lets the statement exit 0 with every
  other row intact. Nothing downstream reads stderr, so a container or a locked-down host
  reports "no agent units" in the shape a clean host does. `queries/runtime-linux.sql` pairs it
  with a `kind=scan` marker computed in SQL, and the marker reasons from the unit **count** —
  socket presence alone reports `ok` against a bound-but-dead socket, which is Docker's `wedge`
  state again.
- **`deb_packages` reports packages nobody has installed.** dpkg keeps a `deinstall ok
  config-files` record, with the version, for anything removed without `--purge`. Filter on
  `status LIKE '%ok installed'` or an uninstalled agent reads as an installed one. Test it with
  a package that has conffiles: `cowsay` has none, so its record vanishes on remove and a broken
  query looks correct.
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
