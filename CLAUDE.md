# Working in this repo

This repo holds the **Open Agent Detection Format** (`SPEC.md`, `schema/`, `conformance/`), its
reference catalog and matcher (`catalog/`, `bin/classify`), and `osquery/`, the format's first
**binding**: the queries and scripts that collect evidence on an endpoint. The binding's own
rules are in [`osquery/CLAUDE.md`](osquery/CLAUDE.md). Deployment glue for a particular MDM
belongs to whoever wraps these artifacts, not here.

**The format is normative, and it may not depend on this repo.** `SPEC.md`, `schema/` and
`conformance/` name no implementation path, and `test/test_conformance.py` fails if one does. A
change to what matching means is one change in four places that move together: the section of
`SPEC.md`, the schema, the vectors, and both matchers (`bin/classify` and the rendered SQL).
The vectors are the contract; when a matcher and a vector disagree, the vector is right until
`SPEC.md` says otherwise. The match modes and the scan outcomes are declared in the schemas. CI
and the osquery lint read the outcomes there; `bin/classify` ships without `schema/`, so it keeps
a copy of the modes, and `test/test_conformance.py` holds the copy equal.

**The catalog and the matcher never read `osquery/`.** `bin/classify`, `catalog/` and the tools
that maintain them work on evidence rows from any binding. The binding reads them, the scenario
harness drives the binding, and the repo-wide gates run its checks; a check that needs both the
catalog and the binding's files belongs to the binding. `test/lint.sh` holds the first sentence.

## The one rule everything else follows

**An empty result must never be indistinguishable from a clean machine.** Nearly every bug this
repo has shipped was a wrong answer that looked like a right one:

- A bounded `osqueryi` that is SIGTERM'd **exits 0 and prints `[\n\n]`** — a valid, empty,
  entirely plausible result. **The kill decides, not the child.** A bounded query must discard
  its own output, because the output of a killed query is a lie.
- A Docker daemon can answer `200` on `/_ping` and then never serve `/images/json`. A health
  check is necessary and **not sufficient**; that state is `wedge` in `osquery/test/lib/fake_docker.py`.
- `$HOME` unguarded under `set -u` crashed the socket probe, which reported `containers=absent`
  on a Mac with a healthy daemon — a plausible answer manufactured by a crash.
- A `kind` no route in `catalog/routes.yaml` declares is **dropped, not unmatched** — invisible
  even under `--show-unmatched`. `ext` sat like that from the beginning; Claude was still
  reported via its native-messaging bridge, so nothing looked wrong.

So: every failure carries a reason. That is what `kind=scan` marker rows are for, and their
vocabulary — `ok`, `absent`, `unreadable:<runtime>`, `unhealthy:<reason>`, `timeout:<n>`,
`error`, `no-cache` — is a contract, not a log format.

**`unreadable:<runtime>` is the newest term.** `absent` means “no Docker socket at the paths
we probe”, which a reader takes as “no containers here” — different facts on a Podman host.
Probing Podman would be worse: its socket passes the health guard and then serves zero images.
So the runtime is named from a socket or a binary on disk, and nothing more. **Declining to
look and finding nothing may not share a word.**

**`stale:<n>` was in that list and is now retired**, because nothing ever emitted it. It was
documented here, in `osquery/docs/deployment.md` and accepted by `ci.yml`'s vocabulary check, while no
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
That means one of five things, and they are worth telling apart —

| it means | what to do |
|---|---|
| the scenario installs by another route | install that route, on **another machine** — two routes claiming one binary name cannot share a host |
| the artifact only exists once the agent **runs** | invoke it; a state directory does not exist until first run |
| **the identifier is wrong** | remove it. This is how both catalog bugs surfaced |
| **the route cannot identify at all** | remove the route. A listening port only matches when the process holding it already names the agent, so it is a second opinion from the same witness — `ports` was retired for that |
| **the identifier is right and is no longer installable** | **keep it** — re-record with `tools/agent_status.py --record <payload> <scenario> --supersede`, which moves the lost observation into that scenario's `archived` list and prints the `superseded:` record to paste into `catalog/agents.yaml`. Told apart from a wrong identifier by whether any run ever produced it; `docs/signature-lifecycle-v2.md` has the workflow |

**There is no `retired:` list on an agent any more, and reaching for one fails the build.** It
was a flat list of strings that exempted every value it named from the coverage gate and asked
for nothing in return. `superseded:` replaced it and carries the observation instead — route,
value, `last_version`, `last_proved`, `by`, `run` — and `tools/validate_catalog.py` refuses a
record that no archived observation backs field for field, so the provenance cannot be typed.
**The value STAYS on its route**: supersession marks a signature, it never moves it, and that
is what keeps the old build's machines matching. `--supersede` is a deliberate mode and must
stay one — a vendor pulling a download for a week is indistinguishable from a rename for that
week, and a guard that archived on its own would supersede a live signature on one bad
afternoon. Unknown agent fields are an error, so the old habit fails loudly rather than
shipping a value nothing checks.

**`untested:` is gone too, and `tools/validate_catalog.py` rejects it.** An identifier no CI
test covers has three outcomes: cover it, supersede it if a run once proved it and nothing
can install it now, or remove it. "No runner happens to produce it" is not one of them.
`com.openai.chat` looked like a supersession until the pre-rename DMG turned out to still be
served.

**A real install is the standard, and it is now the only one.** An agent is verified when a VM
scenario installs the real software and asserts the classifier finds it, and
`tools/validate_catalog.py` refuses an agent no scenario installs — unconditionally. **There is
no exception register any more.** The `unverified:` block and its `evidence` grades are gone;
its weakest grade was `vendor-documentation`, the source this repo exists to distrust, and
nothing was ever written to it in its whole life. What `docs/agents.md` generates instead is
**Identifiers that did not pass**, which is a work list with no way to write an excuse into it.
A fixture is not a weaker pass but a different claim: it proves the matcher works and says
nothing about whether the identifier is what the software ships today.

When something genuinely cannot be verified, say so in the tree rather than guessing —
`docs/signature-lifecycle-v2.md` covers how, and the standing rule is that **a catalog may carry a
guess but may not hide one.** That document describes the lifecycle **as the tree runs it
today**, and it used to be a design for one that did not exist — the `-v2` in its name is a
leftover from when a `-v1` described the tree beside it. One section is still a design record
and it is marked where it begins: `NOT BUILT: naming the successor with a model`. Read that
marker before writing code against anything below it, and do not widen the claim above it.

Two numbers this project treats as conventions, because Jamf documents neither: the **10s EA
timeout** and the **30KB EA value cap**. Both are self-imposed. Do not restate them as platform
limits.

## Architecture, briefly

The endpoint **enumerates**; the enumeration queries hold no catalog and do no filtering.
Matching happens off the machine, in `bin/classify`, against `catalog/agents.yaml`. That is
what lets a new signature re-match evidence already collected, and it is why
`osquery/tools/check_no_catalog.py` fails the build if an agent identifier leaks into those queries.

**The second way to match is on the endpoint, and it is a peer, not a fallback.** The binding
renders the catalog into SQL that answers "which agents are here" directly — a Jamf Extension
Attribute, a Fleet policy, `osqueryi` with a question. `osquery/CLAUDE.md` has the rules that
keep that rendering in step with `bin/classify`.

Every row is the **six-column contract**: `kind, id, ver, loc, extra, perms`.

**Telemetry lives on exactly one side of that boundary.** `bin/classify` sends one anonymous
usage event per run; `osquery/bin/discover`, `osquery/bin/container-scan` and every composed artifact send
nothing, and that is a rule rather than a gap waiting to be filled — the endpoint runs as
root on machines whose owners did not choose this tool, and the classifier does not. The
event is counts only, its field list is declared once in `EVENT_FIELDS` and gated against
`docs/telemetry.md`, and `test/test_telemetry.py` asserts the negative: that nothing from a
payload full of home directories and agent identifiers comes back out. `--telemetry-check`
prints what would be sent without sending or creating anything, because a field list you
cannot print is one the reader has to take on trust.

**The endpoint may not add a dependency.** `osquery/bin/discover` and
`osquery/bin/container-scan` run as root on machines whose owners did not choose this tool, and
what they may call is a closed list in `osquery/CLAUDE.md`. `bin/classify` is deliberately
outside it, for the same reason telemetry is: it runs off the machine, where a missing
interpreter is one operator's problem rather than a fleet-wide condition.

**`catalog/routes.yaml` is the route registry, and adding a route there is the whole edit.** The
vocabulary used to live in five hardcoded lists that had to agree — `validate_catalog`'s
`ROUTES`, `classify`'s `KIND_ROUTES`, `agent_status`'s `EXACT_KINDS`/`GLOB_ROUTES`/`ALL_ROUTES`,
and `lint.sh`'s `KINDS` — and `ext` was missing from one of them from the beginning. All four
derive from the file now. It carries **no field nothing reads**: `purl` arrived with its reader,
`tools/export.py`, and version-semantics stays out for that reason; its header says why.

## Testing

```console
$ test/lint.sh                      # contract, first-arm aliases, kind coverage, container envs
$ python3 osquery/tools/build.py --check    # osquery/dist/ matches osquery/queries/
$ python3 osquery/tools/render_match.py --check   # the rendered match SQL matches the catalog
$ python3 osquery/test/test_match_sql.py    # ...and agrees with bin/classify, row for row (needs osqueryi; SKIPs)
$ python3 tools/validate_catalog.py # + routes.yaml, platforms, value_pattern
$ python3 osquery/tools/check_no_catalog.py
$ python3 test/test_matcher.py
$ python3 tools/check_workflows.py  # matrix union, platform pairing, docs.yml triggers
$ sudo osquery/test/docker_states.sh        # every daemon state, guard and bound (~31s)
$ sudo python3 osquery/tools/check_pack.py  # every pack query actually returns rows
$ python3 osquery/tools/measure.py --check  # cost bands
```

**Everything above runs on both platforms and measures the one it is on.**
`docker_states.sh`, `check_pack.py` and `measure.py` each resolve the platform themselves
and skip the other's queries by name rather than silently — a Linux query measured on macOS
reported `0.24s, 0 rows`, which is a query that ERRORED being recorded as fast.

**Assert on what must NOT match, not only on what must.** `libxdmcp` must not be claimed by the
`mcp` signature; a fork must not be claimed as the real image. Only that shape of assertion can
tell *correctly declined* from *never looked at* — which is precisely the difference the `ext`
bug hid behind.

**Verify a test by breaking the thing it covers.** A multi-tag assertion here was vacuous for
months because its fixture had no agent on either tag. If removing the code does not turn the
test red, the test proves nothing.

**Scenarios run per pull request, the ones its diff can move, and all of them weekly, on both
platforms.** `tools/ci_scope.py` picks them, and a path it cannot scope runs every one. Every
workflow job declares `timeout-minutes`, at most 60, and `tools/check_workflows.py` fails one
that does not: the default is 360, and a hung `open -a` billed that in full four times in
October 2026. `test/run.sh` boots a macOS guest under
Tart; `test/run-linux.sh` runs the Linux scenarios in containers and needs no hypervisor, with
`LINUX_IMAGE` choosing the distro. CI runs them on Debian 12, Rocky 9, Fedora 41 and Amazon
Linux 2023 containers and on Ubuntu runners, x86_64 and arm64; `test/run-gce.sh` runs them on
a real Compute Engine VM per family, which is the only path with systemd, OS Login and a
shared-core shape, and `test/run-ec2.sh` on a real EC2 instance per family, reached over SSM,
for Amazon Linux 2023, Graviton and the burstable credit modes. Each
scenario declares its `platform` in `expected.json`, and `tools/check_workflows.py` asserts it
is paired with a runner that can host it — a Linux scenario listed under the macOS job would
otherwise skip on every run while looking scheduled.

Where something genuinely cannot be
tested, a scenario `exit 3`s to SKIP with the reason in `requires.json` — but **be slow to
conclude that.** This repo asserted that the Claude extension could not be installed without
MDM, and was wrong twice over: Chrome had never been launched, so no profile existed to read,
and the browser's install flow was never needed in the first place. A scenario that fails where nobody can act on it trains people to ignore a red
suite.

## Two shell traps, everywhere in this repo

- **A heredoc inside `$( )` is scanned for the closing paren *without* respecting its quoted
  delimiter**, so one apostrophe in a comment swallows the `)` and the file stops parsing.
  `bash -n` catches it.
- **`python3 - <<'X'` reads the *script* from stdin**, so a pipe into it is discarded in
  silence. Nothing catches it: every assertion simply reads as failed. Pass data as arguments.

## Register

State the measurement, then the consequence. Where a number is unverified, say so rather than
rounding it into fact. Comments in this repo carry the reasoning and the rejected alternative,
because the *why* is the part that stops the bug coming back — see the headers of
`osquery/queries/browser.sql` and `catalog/agents.yaml` for the house style.

**Be concise. This applies to comments and to docs alike.** Carrying the reasoning is not
licence for a paragraph where a clause does. Keep the fact that stops the bug; cut the
retelling, the second example, the restatement in capitals, and the history of a tree that
has no users yet. A comment nobody finishes reading protects nothing.
