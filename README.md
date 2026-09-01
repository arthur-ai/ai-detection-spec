<div align="center">

# 🔎 osquery-ai-discovery

**Find the AI agents on a Mac — with SQL you can read.**

Which coding agents, chat clients, AI browsers and browser extensions are installed,
*which route each one arrived by*, and what those extensions are permitted to access.

[![CI](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-38%2F38-2E7D57)](docs/agents.md)
[![osquery](https://img.shields.io/badge/osquery-5.23.1-1D4E89)](https://osquery.io)
[![macOS only](https://img.shields.io/badge/macOS-only-6B7480)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-6B7480)](LICENSE)

**[What we detect, and what tests it →](docs/agents.md)**

</div>

Every team inventorying AI tooling rediscovers the same handful of facts the hard way: that
Cursor's bundle id is an opaque ToDesktop string, that ChatGPT's desktop app is
`com.openai.codex` and not `com.openai.chat`, that one agent ships as a Homebrew cask *and* an
npm global *and* a curl installer. **This is that knowledge, written down and kept true** — as
queries you can read in ten minutes and a catalog you can check line by line.

Take all of it, take one query, or take just the catalog and match it your own way. MIT, no
runtime dependencies beyond osquery, and no network calls of its own — the only socket it
touches is the local Docker one, and only when you ask for a container scan.

### Why you might like it

- **🔍 Nothing hidden.** It is SQL. Read `dist/discovery.sql` and you know exactly what it
  collects: names, paths, versions and declared permissions, and nothing else.
- **✅ Every signature tested against a real install.** Not against documentation — which is how
  this repo once shipped an identifier that matched nothing on any Mac. **38 of 38** identifiers
  are covered by a test that runs in CI, and [the report](docs/agents.md) is generated, so it
  cannot flatter itself.
- **🧩 Add an agent without touching the endpoint.** The queries carry no product names, so a new
  signature re-matches evidence you already collected — nothing to redeploy to the fleet.
- **🗺 Blind spots stated up front.** [Thirteen of them](docs/agents.md), in writing, because a
  discovery tool that hides them is worse than none.

## What you get

| | | |
|---|---|---|
| 🗂 | **`dist/discovery.sql`** | One SQL file to run on the Mac. **No agent name appears in anything it matches on** — the queries look for shapes (an app bundle, an npm global, a state dotdir), never for "Cursor" or "OpenClaw" — so you never edit it when a new agent appears. It returns the machine's whole AI-relevant inventory: about **760 rows** on a developer Mac, 17.9 KB gzipped |
| 🧭 | **`catalog/agents.yaml`** | The 15 agents and 40 identifiers those rows are matched **against**, off the machine. Add a signature here and it re-matches evidence you already collected — no going back to the fleet |
| 🔎 | **`bin/classify`** | Does that matching, wherever you keep the output |
| 🐳 | **`bin/container-scan`** | The container half, run separately and on a hard time bound, because a wedged Docker daemon blocks forever |
| 📋 | **[`docs/agents.md`](docs/agents.md)** | Every identifier and the CI test that proves it. Generated — the numbers are counted, never typed |

**Why the split matters.** The endpoint *enumerates* and the matching happens elsewhere. A
scanner that knows the agent names has to be redeployed to the whole fleet every time the list
changes, and can only ever find what it already knew to look for. This one collects the
evidence once and answers new questions about it later.

## Scope, so you know what you are getting

**macOS.** Built for it and tested on it; nothing here runs on Linux or Windows today. Claiming
otherwise would waste your afternoon.

**Agents — things that act on your behalf.** A protocol SDK is a library an agent is *built
with*, a gateway is something it *calls through*, a model runner *serves* models, and a
container runtime is *how we look*. All four were catalogued once and all four were removed:
counting them as agents overstates what was found on a machine. A tighter list is a more useful
one.

## Requirements

| | Needs |
|---|---|
| macOS | Apple Silicon or Intel. **No lower bound established** — a floor would be a guess |
| osquery | **5.10.0** — every query declares its own in `min-osquery:` |
| `bash` | 3.2, which is the macOS system `bash`, so `/bin/bash` is enough |
| `python3` | **3.7** (`subprocess` `capture_output`) — for `bin/classify`, `bin/discover`'s writer and `tools/` |
| PyYAML | Only for the tools that read the catalog: `bin/classify` and `tools/validate_catalog.py` |

**Which macOS versions has it actually run on?** [`docs/agents.md`](docs/agents.md) answers that
per scenario, with the platform each run recorded — a generated table, not a claim maintained
by hand here.

**`curl` is deliberately not on that list either**, for the same reason and one more: it is
used in exactly one place — the Docker socket health probe inside `bin/container-scan` — and
`/usr/bin/curl` ships with macOS, so naming it as a prerequisite makes the list look longer
than it is without telling anyone anything they can act on.

**Docker is deliberately not on that list.** Nothing here needs it installed: if a Mac has no
Docker, `bin/container-scan` finds no socket and reports `absent` — a stated outcome, not a
failure. Docker is a property of the machine you are scanning, not a dependency of the scanner.
What it buys you today is narrow and worth saying plainly: exactly **one** catalogued agent
carries a container image (`aider`, as `paulgauthier/aider`), so `--deep` earns its place on
fleets that run agents in containers and adds little elsewhere.

Running the queries needs **osquery alone**. `python3` and PyYAML are for the classifier and
the scheduled writer, not the endpoint's reporting path — which is a `cat`.

`sudo` is needed because some tables read other users' home directories. Without it you see
only your own account.

**One caution.** On a fleet, `/usr/bin/python3` is a **stub** until Command Line Tools are
installed — on a Mac without them the scheduled writer produces nothing at all, which surfaces
as `no-cache` rather than as an error.

## Quickstart

```console
$ brew install --cask osquery          # or https://osquery.io/downloads
$ sudo osqueryi --json < dist/discovery.sql | bin/classify
$ sudo bin/discover --deep | bin/classify     # the same, plus container images
```

For a fleet, do not run either of those on a synchronous reporting path — schedule
`bin/discover --write` and `cat` the file. See [Integrating with an endpoint
tool](#integrating-with-an-endpoint-tool).

```
Claude Code  [Coding agent]
    file    /Users/dana/.local/bin/claude
    file    /Users/dana/.claude/

OpenClaw  [Personal agent]
    app     ai.openclaw.mac  2026.7.1
            /Applications/OpenClaw.app
    daemon  ai.openclaw.gateway
    npm     openclaw  2026.8.1
```

`bin/classify` joins the query output to `catalog/agents.yaml`. Run the query alone for raw
inventory:

Sample output from a developer Mac:

```json
[
  {"kind":"app",  "id":"com.anthropic.claudefordesktop","ver":"1.37937.2","loc":"/Applications/Claude.app"},
  {"kind":"app",  "id":"ai.openclaw.mac",              "ver":"2026.7.1", "loc":"/Applications/OpenClaw.app"},
  {"kind":"npm",  "id":"@openai/codex",                "ver":"0.150.1"},
  {"kind":"file", "id":"/Users/dana/.local/bin/claude"},
  {"kind":"port", "id":"18789",                        "loc":"/opt/homebrew/…/bin/node"},
  {"kind":"ext",  "id":"kbhkmjgjmpbaeoinipbngmmpjppjlkmm","perms":"tabs,cookies,nativeMessaging,<all_urls>"}
]
```

`sudo` is needed because some tables read other users' home directories. Without it you see only
your own account.

## What it collects, and what it does not

The queries read **names, paths, versions and declared permissions**. That is all.

They **never**:

- read the contents of any file
- capture secret or credential values
- touch browser history, cookies, or saved passwords
- execute a discovered binary to ask it anything

The strength of shipping queries rather than an agent is that you do not have to take that on
trust. It is SQL. Read `dist/discovery.sql` in ten minutes and verify it yourself.

This tool also **does nothing to the machine**. No blocking, no remediation, no network calls of
its own. It reports; you decide.

### 📋 What it looks for — [`docs/agents.md`](docs/agents.md)

**[Open the coverage report →](docs/agents.md)** Every agent in the catalog, every identifier
each is matched on, and what actually proves it: a **real install** in a CI scenario, a **CI
fixture**, or nothing yet.

It is **generated and kept current by CI** — not a snapshot. `test/lint.sh` fails if it is
stale, a workflow regenerates it on `main`, and each scenario run records which identifiers it
really matched, with the agent version and the OS that produced them. So the page cannot
describe a catalog that has moved on without it.

```console
$ python3 tools/agent_status.py            # the same report, in the terminal
$ python3 tools/agent_status.py --write    # regenerate docs/agents.md
```

It names what the suite *cannot* prove alongside what it can, and separates the two kinds of
gap: identifiers **no test covers**, and identifiers a scenario installed the agent for that
**did not appear**. A coverage summary that lists only its successes reads as complete when it
is merely silent.

## What it cannot see

A discovery tool that hides its blind spots is worse than none, so they are written down and
counted: **13 of them**, from "anything inside a VM" to "what an agent *does*, as opposed to
what it is permitted to do".

They are properties of the platform and the osquery tables rather than gaps in the test suite —
no amount of coverage moves them — and they live in one place so they cannot drift:
[`docs/blind-spots.yaml`](docs/blind-spots.yaml), rendered into the report.

**[Read them in context →](docs/agents.md#what-osquery-cannot-see)**

## Containers

An agent in a container is invisible to every other query here — no `.app` bundle, no
Homebrew entry, no npm global, no dotdir on the host. This is the only branch that sees it,
and it is opt-in because it is the only part of this that talks to a daemon.

```console
$ sudo bin/discover --deep | bin/classify     # base inventory plus container images
$ sudo bin/container-scan --pretty            # containers alone
```

**Why opt-in.** `docker_images` has no timeout of its own, and against a daemon that accepts
the connection and never answers — Docker Desktop mid-startup, or installed and not opened
today — the query never returns. osquery offers no way to bound it, so the only bound is a
kill on the process. That is why the branch ships as its own artifact
(`dist/discovery-deep.sql`) run by its own process: bounded there, it costs the container
rows; bounded inside the composed query it costs six of the ten seconds and reports success
anyway. `queries/COST.md` has the measurements.

`bin/container-scan` reports which happened in its exit code — `0` scanned, `2` did not scan,
`3` asked and gave up, `1` could not run — and, on every outcome, in a `kind=scan` row. That
row is not decoration: an interrupted `osqueryi` exits 0 having printed a valid empty array,
so without it a wedged daemon and a Mac with no containers produce the same value.
`bin/classify` prints it as `COULD NOT LOOK` above the findings.

Image names resolve through the `images:` catalog route — exact match on the repository, tag
stripped, `docker.io/` and Docker Hub's implicit `library/` removed, registry host kept for
everything else. One carries one: `aider`, as `paulgauthier/aider`. **An image name is chosen
by whoever tagged it**, which no other route here is true of: `docker tag alpine
paulgauthier/aider` produces an aider finding and nothing can tell it from the real image.
Read an image row as weaker evidence than a bundle id.

## Running it on a fleet

**Do not put these queries on a synchronous reporting path.** `docker_images` has no timeout
of its own, and against a daemon that accepts the connection and never answers the query does
not return — so anything that runs it while something waits for the answer can hang rather
than fail. Run it on a schedule and read the result:

```console
# on a schedule, as root
$ bin/discover --write /var/lib/ai-discovery/inventory.json \
               --status /var/lib/ai-discovery/status.txt

# from wherever you collect, whenever you like
$ cat /var/lib/ai-discovery/inventory.json
$ cat /var/lib/ai-discovery/status.txt
```

Each branch runs in its own bounded process on the write path, which is a reliability choice:
one unavailable table costs one branch rather than the whole inventory. Composed into a single
statement it returns zero rows and a valid empty JSON array, which a consumer cannot tell from
a clean machine.

`status.txt` is one line, and its vocabulary is a contract:

```
ok 2026-08-31T20:30:29Z rows=775 apps=ok browser=ok containers=ok filesystem=ok packages=ok runtime=ok
```

`ok`, `absent`, `unhealthy:<http-code>`, `timeout:<seconds>`, `error`, `no-cache`,
`stale:<seconds>`. Every payload also carries one dated `kind=scan` row per branch with the
same value, so a consumer that only has the JSON still knows which branches ran and when.

**Judge freshness on that timestamp, not the file's mtime** — redeploying a file resets the
mtime without changing the truth.

### What a deployment has to supply

This repo ships osquery materials: the queries, the runner, the guard and the bound. The parts
that belong to *your* management stack are deliberately not here, because they differ per
consumer and would rot in a public repo:

- **A schedule** — a launchd job, an MDM policy, cron.
- **Transport** — whatever moves the file to wherever you read it.
- **Framing**, if your channel has a size or encoding limit. Compressing the JSON is usually
  enough; on a reference Mac 121 KB of rows becomes about 19 KB.
- **Classification at scale.** `bin/classify` is the reference implementation and answers "what
  is on this Mac". For a fleet, collect the rows and match them where the catalog lives, so
  that adding a signature re-matches evidence you already hold instead of requiring a re-scan.

## Contributing — genuinely, please do

New AI tools appear weekly and identifiers change underneath you, so **a correction is worth as
much as a new agent.** Found an id that has moved? Know a route we are missing? That is the most
useful thing anyone can send, and it does not have to be a big change: one line in
`catalog/agents.yaml` plus a test is a complete contribution.

**The one thing we ask is a passing test rather than a plausible-looking identifier**, and it is
asked because of a mistake we made rather than a hoop we invented. We shipped `bot.molt.mac` for
OpenClaw once. It came from the vendor's own Homebrew metadata, it looked entirely right, and it
matched nothing on any Mac. The real id is `ai.openclaw.mac`, and only installing the thing
revealed it. The scenario harness exists so you do not have to take that risk on trust either.

[CONTRIBUTING.md](CONTRIBUTING.md) has the details, and `tools/gates.sh` runs every check in
about five seconds, so you can see a green result before you open anything. **First response
within five working days.**

## License

**MIT** — use it, fork it, vendor it into your own tooling, ship it inside a product. No
attribution theatre required. See [LICENSE](LICENSE).

Maintained by the Arthur Unify team, and built on [osquery](https://osquery.io), which does all
the hard parts.
