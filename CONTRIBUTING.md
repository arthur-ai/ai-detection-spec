# Contributing

The most valuable contribution is a **signature**: a new AI tool, or a correction to one we have
wrong. Second most valuable is a **detection gap** you can reproduce.

**First response within five working days.** That covers a maintainer actually running your
scenario, not just reading the diff.

## The one rule that breaks builds

Every query branch emits **six columns, in this order**:

| # | Column | Meaning |
|---|---|---|
| 1 | `kind` | Row type — the closed set below, declared in `catalog/routes.yaml` |
| 2 | `id` | The identifier: bundle id, package name, port, path |
| 3 | `ver` | Version if statically readable, else `''` |
| 4 | `loc` | Where it lives on disk |
| 5 | `extra` | Kind-specific, one value: `browser_type` for `ext`, the vendor for `jbplugin`, the bind address for `port`, `bun` for an `npm` row from bun's global directory. Each query's header says what its kind carries |
| 6 | `perms` | A declared capability. For `ext`, the permissions, then `<all_urls>`, then `unreferenced` (on disk, absent from Preferences, so never loaded) or `sideloaded:<sha256 of manifest.json>` (registered, not from the Web Store); `bin/classify`'s `split_perms()` separates that token from the permissions. `privileged` for `container`. Otherwise `''` |

Everything composes into one `UNION ALL`, so a branch emitting five columns breaks the whole
query. `test/lint.sh` catches it in about ten seconds. Run it first.

Use `''` rather than `NULL` for a column a branch has nothing for. `NULL` propagates through
string concatenation and silently empties whole rows.

**The kinds, and which route each one carries.** This table is derived from
`catalog/routes.yaml` — that file is the registry, and adding a route there is the only edit
needed: the matcher, the validator, the coverage report and lint all read it. This used to be
five hardcoded lists that had to agree, and `ext` was missing from one of them from the
beginning, so every browser-extension row was **dropped rather than unmatched** — invisible
even under `--show-unmatched`, for months, while the row counts stayed right.

| `kind` | route(s) | platform |
|---|---|---|
| `app` | `bundle_ids` | darwin |
| `brew` | `homebrew` | darwin |
| `daemon` | `launchd_prefixes` | darwin |
| `deb` | `deb_packages` | linux |
| `desktop` | `desktop_ids` | linux |
| `ext` | `extension_ids` | posix |
| `file` | `binaries`, `model_stores`, `pypi`, `state_dirs` | posix |
| `image` | `images` | posix |
| `jbplugin` | `jetbrains_plugins` | posix |
| `nmh` | `native_messaging_hosts` | posix |
| `npm` | `npm` | posix |
| `port` | `ports` | posix |
| `proc` | `process_paths`, `running_apps` (darwin), `running_npm` | posix |
| `rpm` | `rpm_packages` | linux |
| `unit` | `systemd_prefixes` | linux |
| `vscodeext` | `vscode_extensions` | posix |
| `scan` | — a marker, not a route: it says a branch could **not** look | linux |

`posix` means darwin **and** linux, and it is osqueryd's own word for it in the pack format, so
a query's `-- platform:` and a route's `platform:` come from one vocabulary.

Two kinds are not demanded of a scenario, and `test/lint.sh` derives that rather than listing
it — a scenario must pin the kinds **its own platform's queries actually emit**:

- **`image`** is a registry kind no composed artifact carries. `containers.sql` is `expensive`,
  so it ships in `dist/ai-discovery.conf` and the deep artifact only. No scenario runs Docker;
  `test/docker_states.sh` covers that branch instead, against a fake socket in every daemon
  state.
- **`scan`** is not a route kind at all. `queries/runtime-linux.sql` emits one on every run
  because `systemd_units` **fails soft** — no system bus means zero rows, exit 0, and every
  other row returned — so the marker is the only thing separating "no agent units" from "we
  could not read the unit list". Linux scenarios pin it, and that is worth doing: it asserts
  the marker is there rather than assuming it.

## Adding a signature

1. Install the real thing, on the platform it ships for. Do not guess identifiers from vendor
   documentation.
2. Find how it actually presents:
   ```console
   $ osqueryi "SELECT bundle_identifier, bundle_short_version, path FROM apps WHERE path LIKE '%Thing%'"
   $ osqueryi "SELECT name, version FROM deb_packages WHERE name LIKE '%thing%' AND status LIKE '%ok installed'"
   ```
3. Add a test scenario under `test/scenarios/`, with a `setup.sh` that installs it and an
   `expected.json` that says what should be found. Under `classified.forbid`, list any agent
   the new rows could be mistaken for: Roo Code's extension id,
   `rooveterinaryinc.roo-cline`, contains Cline's name. A new scenario also goes in the matrix
   in `.github/workflows/scenarios.yml`.
4. Regenerate the files built from the catalog, and run the checks:
   ```console
   $ python3 tools/build.py                  # dist/
   $ python3 tools/agent_status.py --write   # docs/agents.md, docs/limits.md, README badge
   $ tools/gates.sh
   ```
   The agent and identifier totals in README's text are not regenerated. If they changed,
   edit them by hand; `tools/check_doc_numbers.py`, which `gates.sh` runs, names the line.
5. Open a PR. CI checks the scenario is well-formed; the full run happens on a runner for its
   platform.

**Check every install route.** A single tool often ships several ways, and each lands somewhere
different. OpenClaw ships as a Homebrew cask *and* an npm global *and* a `curl | bash` installer
that wraps npm. A fleet that standardised on one route is invisible to a signature written for
another.

**Keep old identifiers as aliases.** When a vendor changes a bundle id, machines that installed
the old version still carry it. Add the new one; do not delete the old.

## The catalog

Signatures live in `catalog/agents.yaml`, one entry per tool carrying **every route it
ships through**:

```yaml
- id: openclaw
  name: OpenClaw
  classification: Personal agent
  bundle_ids: [ai.openclaw.mac]                # read off a live install, never a zap stanza
  homebrew: [openclaw]
  npm: [openclaw, clawdbot, moltbot]
  state_dirs: ["~/.openclaw"]
  launchd_prefixes: [ai.openclaw.]
```

`tools/validate_catalog.py` checks it and runs in CI. It is strict about the mistakes that
fail *silently*: a duplicate id produces double findings, an unknown classification renders
as a blank pill, an entry with no route can never match anything, and the same identifier
claimed by two agents means one is wrong and both will fire.

`classification` describes **deployment shape**, not risk. See the vocabulary at the top of
the file.

### What belongs in the catalog

**Agents.** Something that acts on the user's behalf. The test is not "is this AI software"
and not "can we detect it" — both `mcp-sdk` and `litellm` passed those and were still removed.
An SDK is a library an agent is *built with*; a gateway is something an agent calls *through*.
Detecting either says a developer imported a protocol or proxied some traffic, not that
anything is acting on anyone's behalf.

**Model runners went the same way** — `ollama`, `lm-studio`, `jan`, `llama-cpp`. They serve
language models; an agent is what drives one. The `model` query branch went with them: no
agent is found through a model store, so its rows were payload nobody read.

A **container runtime** went too. `containers.sql` exists because agents hide in containers —
so what belongs in the catalog is the agent **image** (`paulgauthier/aider`), not Docker. The
runtime is instrumentation, and
whether it is present is already reported by the `kind=scan` marker, which tells *no Docker*
apart from *Docker wedged*. A bundle id cannot.

If you remove an entry, **leave its rows in the fixtures** and assert they are declined.
Deleting the evidence with the signature leaves nothing to distinguish *correctly not an
agent* from *route quietly broken*.

### A real install is the standard

An agent is verified when a **VM scenario installs the real software** and asserts the
classifier finds it. That is the bar, and it is the bar because nothing lower catches the
errors this catalog exists to avoid: `bot.molt.mac` came from OpenClaw's own Homebrew
metadata and matched nothing on any Mac, and `aider` installs as `aider-chat` while its
state directory is `~/.aider`, so evidence and signature never met. Both passed review.

So add the agent to a scenario's `classified.must_find`. A fixture proves the matcher; only a
CI scenario proves the identifier is what the software ships today. **There is no way to
record an exception instead** — `tools/validate_catalog.py` refuses an agent no scenario
installs, unconditionally. There used to be an `unverified:` block whose weakest grade was
`vendor-documentation`, the source this repo exists to distrust; it held nothing for its whole
life, and [`docs/signature-lifecycle-v2.md`](docs/signature-lifecycle-v2.md#what-was-deleted-and-why)
records what went with it.

If no scenario can install your agent, it is not a signature yet. Say so in
[`docs/blind-spots.yaml`](docs/blind-spots.yaml), which is the file for what this repo cannot
see, rather than shipping the identifier with a note attached.

### Regenerate the doc in the same commit

[`docs/agents.md`](docs/agents.md) lists every agent, its identifiers and the evidence
behind each one; [`docs/limits.md`](docs/limits.md) lists what osquery cannot see and what
each scenario leaves unproved. Both are **generated**, exactly as `dist/` is:

```console
$ python3 tools/agent_status.py            # read it in the terminal
$ python3 tools/agent_status.py --write    # regenerate docs/agents.md and docs/limits.md
```

`test/lint.sh` fails if either is stale, so change the catalog and regenerate in the same
commit. A workflow also regenerates it on `main` as a safety net, which covers a direct
push or a merge that moves coverage without touching the catalog.

### `observed.json` is what coverage is counted from

Each scenario records what it actually matched in `test/scenarios/<name>/observed.json`, and
`tools/agent_status.py` counts coverage from those files rather than from what `expected.json`
asserts — an agent can pass while carrying an identifier nothing exercised.

The `collect` job writes them and it runs **only on `main`**: a pull request asserts and
uploads without committing, because a PR must not be able to move recorded coverage. So **a PR
that adds an identifier's first real install should commit the observation itself** — otherwise
the generated page reports that identifier as uncovered until the merge lands, while the
scenario proving it sits green on the same PR.

```console
$ python3 tools/agent_status.py --record /tmp/out.json test/scenarios/<name> \
    --platform linux --os 24.04 --arch x86_64
```

Records merge and are refused when they shrink: a run proving fewer identifiers than the
committed file already holds stops rather than overwriting it, because that is also what a
query that quietly broke looks like. `--allow-shrink` is the deliberate override, for an
identifier genuinely removed from the catalog.

The state to read closely is **`did not appear`**: a scenario installed the agent and this
identifier never showed up. It has five causes, and
[`docs/signature-lifecycle-v2.md`](docs/signature-lifecycle-v2.md#triage-why-did-it-stop-appearing)
is the triage. The pair to get right is *wrong identifier* against *no longer installable*:
they look identical in the report, take opposite actions, and are told apart by whether any
run ever produced the value —

```console
$ grep -rl '"value": "<the value>"' test/scenarios/*/observed.json
```

No record means wrong, and both catalog bugs found so far were that: npm `mcp` is Mintlify's
package, and npm `aider` is a static-site component. A record means the software moved on
while machines on the old build still report it — keep the value and supersede it.

### Superseding an identifier

Re-record the scenario against a run that no longer produces the value, and ask for it:

```console
$ python3 tools/agent_status.py --record /tmp/out.json test/scenarios/<scenario> --supersede
```

That moves the lost observation into that scenario's `observed.json` `archived` list and
prints the record to paste under the agent that owns the value:

```yaml
    superseded:
      - {route: bundle_ids, value: com.example.old, last_version: 1.4.2,
         last_proved: 2026-09-14, by: 57-example-era, run: 34840592589}
```

Three things about that block are not stylistic, and the lifecycle page carries the reasoning:
the value **stays on its route**, which is what keeps machines on the old build matching; the
provenance **cannot be typed** — `tools/validate_catalog.py` refuses a record no archived
observation backs field for field, so a `?` in the printed block is a refusal waiting to
happen, and the fix is to re-record on CI; and it is **a deliberate mode**, because a vendor
pulling a download for a week looks exactly like a rename for that week. There is no `retired:`
list any more, and an unknown agent field fails the build.

### The `images` route

A container image repository, reached only by `bin/discover --deep`. It is matched exactly
against the normalised tag, and the normalisation was read off 28 real images rather than
reasoned about:

```yaml
  images: [paulgauthier/aider]        # Docker Hub: no docker.io/, no library/
  images: ["ghcr.io/block/goose"]     # anywhere else: the registry host IS part of it
```

Three things to know before adding one:

- **Give the repository, never a tag.** `paulgauthier/aider:latest` in the catalog normalises
  to `paulgauthier/aider` on the row side and would simply never match. `validate_catalog.py`
  rejects it, because the failure is otherwise silent — the agent just stops being found.
- **Prefer the two-segment published name.** A locally built image is shaped exactly like a
  Docker Hub library image, so a bare `aider` would claim anyone's `aider:latest` build.
- **This route is weaker evidence than the others, and the difference is real.** Every other
  identifier here is chosen by a vendor. An image name is chosen by whoever ran `docker tag`,
  so `docker tag alpine paulgauthier/aider` yields an aider finding that nothing can tell from
  the genuine image. Say so when you use it; do not treat an image row as a bundle id.

**Verification: pull it and read the row.** Identifiers are facts read off real installs, and
for an image that means the `docker_images` row, not the registry — a `200` proves the name
and says nothing about how a row renders it. Every `images` value in the catalog was read off
a real row.

**If Docker Hub pulls are blocked for you** (Registry Access Management: the daemon refuses
with `authentication required - access token has insufficient scopes`, and it is daemon-side,
so an isolated `DOCKER_CONFIG` will not help), side-load instead:

1. Anonymous pull token from `auth.docker.io`, index from `registry-1.docker.io`, pick your
   architecture's manifest.
2. Download config and layers into `blobs/sha256/<digest>`, **verifying each blob's sha256
   against the digest that named it** — a truncated layer loads and is wrong.
3. Write `oci-layout` (`{"imageLayoutVersion":"1.0.0"}`) and an `index.json` whose manifest
   entry carries `"io.containerd.image.name": "docker.io/<repo>:<tag>"`. That annotation names
   the loaded image, and so decides what `docker_images` reports.
4. `tar -cf - -C <dir> . | docker load`.

Needs the containerd image store (`docker info` shows `containerd-snapshotter=true`).
`ollama/ollama` and `paulgauthier/aider` were verified this way.

## Query frontmatter

```sql
-- name: browser-extensions
-- description: Chrome/Brave/Edge extensions across every profile, with permissions
-- tables: users, chrome_extensions
-- min-osquery: 5.10.0
-- cost: fast          # fast <1s | slow 1-5s | expensive >5s
-- platform: darwin
```

## Performance is a build gate

**A query must be fast in its worst state, not its typical one**, and CI enforces it.

The case that taught us: a `docker_images` branch cost 0.35s with no Docker installed and
**10.4s with Docker installed but stopped**, returning zero rows either way. That is the common
state on a developer Mac, and it took the whole query from 1.0s to 11.2s.

Two ways this hides:

- **A clean test machine lacks the dependency entirely**, so it never exercises the slow path.
- **A liveness probe that only `connect()`s to a socket reports success** while the query still
  stalls, because osquery blocks on the *read*. Only a full round trip distinguishes them.
- **A round trip that gets a 200 also reports success, and then the *next* request blocks.** A
  health check is a fact about the past. Between the probe and the query there is a window, and
  Docker Desktop spends real time in the state where its API answers and its engine does not
  serve. A probe narrows that window; only a wall-clock bound on the process closes it. If the
  table you are adding has no timeout of its own and osquery offers no flag to give it one —
  check, because `docker_images` has neither — then it cannot go in a composed artifact at any
  band. It goes in `dist/discovery-deep.sql`, behind a runner that can kill it.

If your query touches a daemon, socket or external service, test it **stopped and mid-startup**,
not just healthy.

`tools/measure.py --check` times every query against its declared band and fails the build on an
overrun, naming the query and its measured cost. It runs on every pull request. Measured numbers
for each query, and the machine they were taken on, are in [queries/COST.md](queries/COST.md).

```console
$ tools/measure.py             # time every query, print a table
$ tools/measure.py --check     # fail if any query exceeds its declared band
```

Raise a query's declared band rather than tuning the budget, and say in the PR why the cost is
inherent. A `slow` query is fine; an undeclared one is not.

## Running the tests

Platform-free, and worth running first:

```console
$ test/lint.sh                 # static checks, ~10s, no osquery, both platforms
$ python3 test/test_matcher.py # the matcher, no osquery, no VM, no container
$ python3 tools/build.py --check
$ python3 tools/render_match.py --check   # the catalog rendered as SQL, up to date
$ python3 tools/validate_catalog.py
```

`python3 test/test_match_sql.py` holds that rendered SQL to the matcher, evidence row for
evidence row. It needs `osqueryi` and says SKIP without one; it runs for real in CI.

Needs osquery, and measures whichever platform you are on:

```console
$ tools/measure.py --check     # cost bands, a few seconds
$ sudo test/docker_states.sh   # every daemon state, that the bound kills the one the guard
                               # wrongly admits, and that image rows classify, ~35s
$ sudo python3 tools/check_pack.py
```

Scenarios, which install real software and are therefore per platform:

```console
$ test/run.sh 00-baseline           # macOS, in a disposable VM
$ test/run-linux.sh 70-linux-baseline   # Linux, in a disposable container
$ test/run-linux.sh                 # every Linux scenario
$ LINUX_IMAGE=quay.io/rockylinux/rockylinux:9 test/run-linux.sh   # on another distro
$ test/run-gce.sh --family debian-12    # on a real Compute Engine VM; needs gcloud
```

**The harnesses differ because the platforms do.** `test/run.sh` uses
[Tart](https://tart.run), which needs an Apple Silicon Mac and a base image of roughly 25GB.
`test/run-linux.sh` needs only Docker, because a Linux scenario needs no hypervisor — which
is also why the Linux CI jobs run directly on the runner with no VM layer, and in Debian,
Rocky and Fedora containers beside it. `test/run-gce.sh` exists for what neither can stage:
systemd as PID 1 on every family, OS Login accounts, and a shared-core machine shape.

A Linux scenario that no row of a job can host is not listed under that job, and the reason is
always a fact about the runner rather than about the software: `76-linux-systemd` needs a real
system bus and `79-linux-image` a Docker daemon, so both run on the Ubuntu runners and under
`test/run-gce.sh` and are not listed under the containers; `77-linux-rpm` and
`91-linux-claude-rpm` need dnf and are not listed under the Ubuntu runners. Where a job hosts a
scenario on some rows and not others it still **skips** by exiting 3: the deb and rpm scenarios
on the other family's images, and `75-linux-browser` on the arm64 runner, because Google ships
no Linux arm64 Chrome.

**Scenarios run on every pull request, the ones its diff can move**, on macOS and Linux both,
and all of them every week. You do not need to run them locally to contribute: push the branch
and let CI do it. Superseded runs on the same branch are cancelled, so pushing repeatedly costs
one suite rather than one per push.

`tools/ci_scope.py` maps each changed path to the scenarios that read it and excludes the rest
from the matrix. A scenario's own files run that scenario; a catalog edit runs the scenarios that
name, observed or probe evidence for the agents it changed; a query or composed artifact runs its
platform; prose runs none. It decides in the expensive direction: a path it does not recognise, a
diff it cannot compute, and a diff that comes back empty all run every scenario. An excluded
scenario does not appear in the checks list, so the scope job's summary names each path, the rule
that scoped it and what ran. The one thing scoping can miss -- a new signature over-matching rows
in a scenario with no link to its agent -- is what the weekly run is for.

The cost bands and the runtime checks skip only when every changed path is a `.md` file or
`LICENSE`.
`test/lint.sh` is never skipped, so the gates that read prose -- the documented numbers, the
generated doc, the workflow parser -- still run on the commit that changes it.

If you need the full suite on a branch anyway, run the workflow from the Actions tab: a
`workflow_dispatch` has no diff to read and runs everything.

Assertions are on **counts and specific identifiers**, never "did it parse". Every defect found
in this project so far produced plausible-looking output with the wrong number of rows, and not
one of them errored.

## Versioning

Releases are [semantic](https://semver.org), with repository-specific meaning:

- **major** — the six-column contract or the catalog schema changes. Consumers must change code.
- **minor** — a new query, or new signatures. Additive and safe to take.
- **patch** — a corrected identifier, a fixed glob, documentation.

Releases are cut whenever signatures change, at most weekly. What changed in each one is on the
[Releases page](https://github.com/arthur-ai/osquery-ai-discovery/releases) rather than in a file
in the tree; there is no `CHANGELOG.md`. Publishing a release triggers
[`release.yml`](.github/workflows/release.yml), which rebuilds the composed artifacts and
`dist/ai-discovery.conf` from the tagged `queries/` and attaches them — so a deployment can pin
a tag instead of tracking `main`, and what it downloads is derived from the tag rather than
uploaded by hand.

## Reporting a detection gap

If you know of an agent this misses, open an issue with the tool, how you installed it, and what
`dist/discovery-darwin.sql` or `dist/discovery-linux.sql` returned. If disclosing it
publicly would be unwise, see
[SECURITY.md](SECURITY.md).

## Scope

The catalog describes **what software is present**, not whether it is good, safe or
permitted. Classifications like `Personal agent` describe deployment shape. Whether a given
agent is acceptable is your judgement about your fleet, not ours about a vendor. Which
platforms ship is the README's to say; `tools/validate_catalog.py` refuses an agent claiming
one nothing can find it on.
