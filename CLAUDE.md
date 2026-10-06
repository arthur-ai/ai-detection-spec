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
vocabulary — `ok`, `absent`, `unreadable:<runtime>`, `unhealthy:<code>`, `timeout:<n>`,
`error`, `no-cache` — is a contract, not a log format.

**`unreadable:<runtime>` is the newest term.** `absent` means “no Docker socket at the paths
we probe”, which a reader takes as “no containers here” — different facts on a Podman host.
Probing Podman would be worse: its socket passes the health guard and then serves zero images.
So the runtime is named from a socket or a binary on disk, and nothing more. **Declining to
look and finding nothing may not share a word.**

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
`tools/check_no_catalog.py` fails the build if an agent identifier leaks into those queries.

**One generated family takes that trade the other way, on purpose.** `tools/render_match.py`
renders the catalog into `dist/signatures.sql`, `dist/agents-<platform>.sql` and
`dist/fleet-policies.yml` — matching **on** the endpoint, for the readers who have no
collector: a Jamf Extension Attribute (`bin/discover --names`), a Fleet policy, `osqueryi`
with a question. The rules that keep it honest:

- The signature rows come out of `bin/classify`'s own `build_index`, and the SQL matches
  the same six-column rows the classifier does, so agreement is structural. Where the
  classifier uses a regex, the SQL uses `regex_match` with the classifier's pattern.
- `test/test_match_sql.py` holds the two to the **same evidence rows, per row**, on every
  fixture, on controls that must and must not match, and in every scenario on the rows a
  real install produced. It needs `osqueryi` and SKIPs loudly without one; the CI runtime
  jobs run it with `--require-osqueryi`.
- A route whose match mode the renderer cannot express **fails the build**; a value two
  agents both claim fails the build. A join reports every signature a row satisfies and
  the classifier picks one, so those are the two ways they could disagree.
- `check_no_catalog.py` exempts those four files **by name** and requires each to carry
  identifiers; every other file in `dist/` is still held to the rule.
- `regex_match` returns NULL on a miss, an invalid pattern aborts the whole statement, and
  `LIKE` is case-insensitive — so the join is a `CASE`, every regex is compiled before it is
  written, and a prefix is `substr`.
- A signature added to the catalog reaches the rendered files only by redeploying them. The
  payload still re-matches. The bundle carries `signatures.sql` for `--names` and nothing
  else that names an agent.

Every row is the **six-column contract**: `kind, id, ver, loc, extra, perms`.

**Telemetry lives on exactly one side of that boundary.** `bin/classify` sends one anonymous
usage event per run; `bin/discover`, `bin/container-scan` and every composed artifact send
nothing, and that is a rule rather than a gap waiting to be filled — the endpoint runs as
root on machines whose owners did not choose this tool, and the classifier does not. The
event is counts only, its field list is declared once in `EVENT_FIELDS` and gated against
`docs/telemetry.md`, and `test/test_telemetry.py` asserts the negative: that nothing from a
payload full of home directories and agent identifiers comes back out. `--telemetry-check`
prints what would be sent without sending or creating anything, because a field list you
cannot print is one the reader has to take on trust.

**`bin/discover` MAY NOT ADD A DEPENDENCY, and neither may `bin/container-scan`.** That is a
rule about what you are allowed to type in them, and it is the second property of the same
boundary as telemetry. What they are permitted is closed:

| allowed | why |
|---|---|
| **bash 3.2** | what a managed Mac has, and the shebang both scripts declare |
| **`osqueryi`** | the dependency this repo already is. Resolved through `osqueryi_path`, which states its failure rather than assuming a PATH |
| **`curl`** | the Docker `/_ping` probe in `bin/container-scan`, and nothing else. Ships with macOS and every Linux base image we have run on; `docs/deployment.md` says why it is not written up as a prerequisite |
| **the POSIX utilities already in use** | read off the two files, not from memory: `cat`, `chmod`, `date`, `dirname`, `mkdir`, `mktemp`, `mv`, `rm`, `sed`, `sleep`, `uname`. That is the whole list |

Anything else is a new dependency, **including one that is obviously installed on the machine
you are testing on.** No interpreter — no `python`, `perl`, `ruby`, `node`. No `jq`: it does
not ship with macOS at all, and every use it would have is one `osqueryi` already covers. No
GNU-only flag on a utility in that list, because BSD `sed` and `date` are what a Mac has.

**`tools/bundle.py` widens that list by exactly two, and it is the only thing allowed to.**
The one-file bundle it emits extracts a `tar` from `base64` before `bin/discover` starts, so
a machine running a bundle needs those two on top of the table above. They are stock
everywhere this repo runs and the cost is opt-in — a consumer who unpacks `bin/` and `dist/`
themselves pays neither — but it is a widening rather than a detail, and it is written down
in `docs/deployment.md` where a deployer will meet it. Nothing else may add to the list: the
wrapper ships to the same machines the runner does, and `test/lint.sh` holds it to the same
deny-list.

**`osqueryi` is the JSON parser, and the shell is the serializer.** That is the whole toolkit
and it is enough: `json_str`/`json_row` build a six-column row with `printf`; `osq_run`,
`json_concat` and `merge_sql` read documents with the same SQLite that wrote them. If you are
reaching for a tool, you are reaching past one of those.

It was not always true, and the cost of it not being true was not an error. On a managed Mac
`/usr/bin/python3` is a **stub** — no Command Line Tools, so it prints an install prompt on
stderr and exits 1 with empty stdout — and the `no-cache` row that exists to say the writer
never ran was built by the interpreter that stopped the writer. It printed nothing, and
nothing reads as a clean machine. **A marker row may not depend on anything that could be the
thing it is reporting**, and neither may the guard that decides whether to emit one.

`test/lint.sh` greps both files for a deny-list — `python`, `jq`, `perl`, `ruby`, `node`,
`deno`, `php` — excluding comments so the explanation does not fail its own check. **That gate
is narrower than this rule**: it catches what people actually reach for, not every command,
so a new dependency can pass lint and still be wrong. The reviewer is the enforcement for the
rest. `bin/classify` is deliberately outside all of this, for the same reason telemetry is: it
runs off the machine, where a missing interpreter is one operator's problem rather than a
fleet-wide condition.

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
| `dist/signatures.sql` | **rendered from the catalog**, not composed from `queries/`: the signature table and the match, as a fragment over an `ev` CTE the caller supplies. `bin/discover --names` feeds it the payload |
| `dist/agents-darwin.sql`, `dist/agents-linux.sql` | the enumeration wrapped in that match: one row per agent found. **Never sees image-only agents** — the container branch needs the bound, so it is not in here, and the header says so |
| `dist/fleet-policies.yml` | one Fleet policy per agent per platform, passing when absent. Each wraps only the branches its agent's routes need |

**`dist/discovery.sql` is gone.** It named one platform while claiming none, and fed to the wrong
`osqueryi` it returns `[\n\n]` — five bytes of valid, empty, plausible JSON. It does at least
exit 1, which is the only reason that state is recoverable; `bin/discover` picks by `uname -s`.

A query declares `-- platform: darwin | linux | posix`, where `posix` means both and is
osqueryd's own word for it. The value is **checked** against `catalog/routes.yaml` now: it never
was, so `-- platform: macos` built clean and shipped a pack query osqueryd silently never
scheduled.

`dist/` is **generated**. Edit `queries/`, then `python3 tools/build.py`; `--check` gates it,
in both directions — a stale artifact and an artifact nothing generates are the same drift.
The rendered match files come from `catalog/` through `tools/render_match.py`, which needs
PyYAML; `build.py` runs it when PyYAML is present and says so when it is not, and
`render_match.py --check` is its own gate. `build.py` knows the rendered names only so its
unknown-file check can tell "rendered" from "nothing generates it".

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
  unbound-variable error: append with `+=` and expand as `${a[@]+"${a[@]}"}`. A heredoc inside
  `$( )` is scanned for the closing paren *without* respecting its quoted delimiter, so one
  apostrophe in a comment swallows the `)` and the file stops parsing — and `python3 - <<'X'`
  reads the **script** from stdin, so a pipe into it is discarded in silence. `bash -n` catches
  the first. Nothing catches the second: every assertion simply reads as failed.
- **A parse failure prints `[\n\n]` too.** Fed malformed JSON, `osqueryi` writes
  `Error: malformed JSON` to stderr, exits 1, and **still prints five bytes of valid, empty
  JSON on stdout**. The kill decides, not the child — and neither does the parser. Every
  `osqueryi` call that parses a document goes through `osq_run`, which prints nothing on a
  non-zero exit, because that guard belongs in one place rather than at every call site.
- **`identifier` is derived from the manifest `key`.** That is why a planted or unpacked
  extension reports an EMPTY one — it has no key. The consequence is not that ids are
  untestable: the Web Store's signed CRX *does* carry the key, so unpacking one into a real
  profile yields the real id, and `45-claude-extension` does exactly that. Chromium ids are
  key-derived, so they are identical across all 11 `browser_type`s osquery enumerates.

## Testing

```console
$ test/lint.sh                      # contract, first-arm aliases, kind coverage, container envs
$ python3 tools/build.py --check    # dist/ matches queries/
$ python3 tools/render_match.py --check   # the rendered match SQL matches the catalog
$ python3 test/test_match_sql.py    # ...and agrees with bin/classify, row for row (needs osqueryi; SKIPs)
$ python3 tools/validate_catalog.py # + routes.yaml, platforms, value_pattern
$ python3 tools/check_no_catalog.py
$ python3 test/test_matcher.py
$ python3 tools/check_workflows.py  # matrix union, platform pairing, docs.yml triggers
$ sudo test/docker_states.sh        # every daemon state, guard and bound (~31s)
$ sudo python3 tools/check_pack.py  # every pack query actually returns rows
$ python3 tools/measure.py --check  # cost bands
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

**Scenarios run per pull request, on both platforms.** `test/run.sh` boots a macOS guest under
Tart; `test/run-linux.sh` runs the Linux scenarios in containers and needs no hypervisor, with
`LINUX_IMAGE` choosing the distro. CI runs them on Debian 12, Rocky 9 and Fedora 41
containers and an Ubuntu runner; `test/run-gce.sh` runs them on a real Compute Engine VM per
family, which is the only path with systemd, OS Login and a shared-core shape. Each
scenario declares its `platform` in `expected.json`, and `tools/check_workflows.py` asserts it
is paired with a runner that can host it — a Linux scenario listed under the macOS job would
otherwise skip on every run while looking scheduled.

Where something genuinely cannot be
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

**Be concise. This applies to comments and to docs alike.** Carrying the reasoning is not
licence for a paragraph where a clause does. Keep the fact that stops the bug; cut the
retelling, the second example, the restatement in capitals, and the history of a tree that
has no users yet. A comment nobody finishes reading protects nothing.
