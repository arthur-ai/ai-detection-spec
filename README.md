<div align="center">

# 🔎 osquery-ai-discovery

**Find the AI agents on your fleet — with SQL you can read.**

Which coding agents, chat clients, AI browsers and browser extensions are installed,
*which route each one arrived by*, and what those extensions are permitted to access.

[![CI](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-61%2F61-2E7D57)](docs/agents.md)
[![osquery](https://img.shields.io/badge/osquery-5.23.1-1D4E89)](https://osquery.io)
[![macOS](https://img.shields.io/badge/macOS-shipping-2E7D57)](#requirements)
[![Linux](https://img.shields.io/badge/Linux-shipping-2E7D57)](#requirements)
[![Windows](https://img.shields.io/badge/Windows-not_yet-6B7480)](#scope-so-you-know-what-you-are-getting)
[![License](https://img.shields.io/badge/license-MIT-6B7480)](LICENSE)

**[What we detect, and what tests it →](docs/agents.md)**

</div>

Every team inventorying AI tooling rediscovers the same handful of facts the hard way: that
Cursor's bundle id is an opaque ToDesktop string, that ChatGPT's desktop app is
`com.openai.codex` on current builds and `com.openai.chat` on everything before the Codex
rename, so a fleet needs both, that one agent ships as a Homebrew cask *and* an
npm global *and* a curl installer. **This is that knowledge, written down and kept true** — as
queries you can read in ten minutes and a catalog you can check line by line.

Take all of it, take one query, or take just the catalog and match it your own way. MIT, no
runtime dependencies beyond osquery. **Nothing that runs on the endpoint makes a network
call** — the only socket it touches is the local Docker one, and only when you ask for a
container scan.

### Why you might like it

- **🔍 Nothing hidden.** It is SQL. Read `dist/discovery-darwin.sql` (or
  `dist/discovery-linux.sql`) and you know exactly what it collects: names, paths, versions
  and declared permissions, and nothing else.
- **✅ Every signature tested against a real install.** Not against documentation — which is how
  this repo once shipped an identifier that matched nothing on any Mac. **Every identifier** is
  covered by a test that runs in CI — lint fails on one that is not — and
  [the report](docs/agents.md) is generated, so it cannot flatter itself.
- **🧩 Add an agent without touching the endpoint.** The queries carry no product names, so a new
  signature re-matches evidence you already collected — nothing to redeploy to the fleet.
- **🗺 Blind spots stated up front.** [Written down](docs/limits.md), because a discovery tool
  that hides them is worse than none.

## What you get

| | | |
|---|---|---|
| 🗂 | **A query** | Runs on each machine and lists what is installed — apps, packages, browser extensions, state directories. **No agent name appears anywhere in it.** It reports what it finds; which of those findings add up to an agent is decided later, by the classifier. One per platform, because macOS and Linux read different tables |
| ▶️ | **A runner** | Runs that query on the endpoint and prints the result as one JSON array. A second one covers agents packaged as Docker images, separately and on a time limit, because a wedged Docker daemon never answers and would otherwise hang the scan |
| 🔎 | **A classifier and its catalog** | Reads the collected JSON and tells you which agents are on the machine, matching the evidence against **22 agents and 61 identifiers**. It runs wherever you keep the output, never on the endpoint |
| 🧾 | **The same catalog, as SQL** | For when you cannot run the classifier: a query that returns the agent names directly, a set of Fleet policies, and `bin/discover --names`, which prints the names as one line for a Jamf Extension Attribute. All generated from the catalog, and CI checks they give the same answers as the classifier |

**Why the split matters.** The endpoint *enumerates* and the matching happens elsewhere. A
scanner that knows the agent names has to be redeployed to the whole fleet every time the list
changes, and can only ever find what it already knew to look for. This one collects the
evidence once and answers new questions about it later — add a signature to the catalog and it
re-matches evidence you already have, without going back to the fleet.

**The SQL version of the catalog gives that up on purpose.** Some tools can only work with a
single value or a single query: a Jamf Smart Group, a Fleet policy. For those, the matching
has to happen on the machine, and a new signature only reaches them when you redeploy the
file. The file is generated from the same catalog, so there is still only one place to add a
signature.

**[What a release attaches](#what-a-release-attaches)** names every file and says which machine
it belongs on.

## Scope, so you know what you are getting

**macOS and Linux ship. Windows does not.** CI installs the real software on macOS runners, on
`ubuntu-24.04`, and in Debian 12, Rocky 9 and Fedora 41 containers, so both platforms are held
to the same standard: a signature is verified when a scenario installs the actual software and
asserts the classifier finds it.

**Coverage is a gate, not a figure.** Every identifier is covered by a CI test that installs
the real software, and the build fails if that is ever less than all of them — so there is no
partial number to interpret. [The report](docs/agents.md) names which scenarios proved each
one.

**What is platform-specific.** Declared in [`catalog/routes.yaml`](catalog/routes.yaml), which
the matcher, the validator, the coverage report and lint all read — so this table is the
registry rather than a description of it:

| | routes | osquery tables |
|---|---|---|
| **macOS only** | `bundle_ids`, `homebrew`, `launchd_prefixes` | `apps`, `homebrew_packages`, `launchd` — all in osquery's `specs/darwin` |
| **Linux only** | `deb_packages`, `desktop_ids`, `rpm_packages`, `systemd_prefixes` | `deb_packages`, `rpm_packages`, `systemd_units`, `file` |
| **Both** | `binaries`, `extension_ids`, `images`, `model_stores`, `native_messaging_hosts`, `npm`, `pypi`, `state_dirs`, `vscode_extensions` | `npm_packages`, `chrome_extensions`, `vscode_extensions`, `docker_images`, `file` |

The composed artifact is per platform for that reason — `dist/discovery-darwin.sql` and
`dist/discovery-linux.sql` name disjoint sets of tables, so **there is no single file that runs
on both**. `bin/discover` picks by `uname -s`.

**Windows has no code and no date**, because a date this repo cannot enforce is the kind of
claim it exists to avoid.

**Agents — things that act on your behalf.** A protocol SDK is a library an agent is *built
with*, a gateway is something it *calls through*, a model runner *serves* models, and a
container runtime is *how we look*. All four were catalogued once and all four were removed:
counting them as agents overstates what was found on a machine. A tighter list is a more useful
one.

## Requirements

| | Needs |
|---|---|
| macOS | Apple Silicon or Intel. **No lower bound established** — a floor would be a guess |
| Linux | Any distro with dpkg or rpm. One artifact serves both: on Debian `rpm_packages` returns no rows and exits 0, and on Fedora `deb_packages` does the same — measured, not assumed |
| osquery | **5.10.0** — every query declares its own in `min-osquery:`, and `queries/vscode.sql` declares **5.11.0**, which is when `vscode_extensions` arrived |
| `bash` | 3.2, which is the macOS system `bash`, so `/bin/bash` is enough |
| `python3` | **3.7** (`subprocess` `capture_output`) — for `bin/classify` and `tools/`. **Nothing on the endpoint needs it** |
| PyYAML | Only for the tools that read the catalog: `bin/classify` and `tools/validate_catalog.py` |

**Everything that runs on the endpoint needs osquery alone.** `bin/discover` and
`bin/container-scan` are bash and `osqueryi`; `python3` and PyYAML are for the classifier and
the tools, which run off the machine. [`docs/deployment.md`](docs/deployment.md) says why that
is a rule rather than a detail, why `curl` is not listed, and what the one-file bundle adds.

`sudo` is needed because some tables read other users' home directories. Without it you see
only your own account.

## Quickstart

```console
$ git clone https://github.com/arthur-ai/osquery-ai-discovery
$ cd osquery-ai-discovery              # or download the assets from a tagged release
$ brew install --cask osquery          # or https://osquery.io/downloads
$ python3 -m pip install pyyaml        # for bin/classify only -- the endpoint needs nothing
$ sudo osqueryi --json < dist/discovery-darwin.sql | bin/classify
$ sudo bin/discover --deep | bin/classify     # the same, plus container images
$ sudo osqueryi --json < dist/agents-darwin.sql   # or: get the agent names straight from one query
$ sudo bin/discover --names                   # or: the names as one line, for a Jamf Extension Attribute

# On Linux, the same thing. bin/discover picks the artifact by `uname -s`, so the
# second form needs no change at all.
$ sudo apt install ./osquery_5.23.1-1.linux_amd64.deb
$ sudo osqueryi --json < dist/discovery-linux.sql | bin/classify
```

`dist/` is committed, so a clone is ready to run — there is nothing to build. Pinning a
tagged release is the recommended posture, and one ships the same artifacts plus the
catalog; see [SECURITY.md](SECURITY.md).

For a fleet, do not run either of those on a synchronous reporting path — schedule
`bin/discover --write` and `cat` the file. See [Running it on a fleet](docs/deployment.md).

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

`bin/classify` joins the query output to `catalog/agents.yaml`. Run the query alone and you
get the raw inventory instead:

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

## What a release attaches

**Fifteen assets**: `discovery-darwin.sql`, `discovery-linux.sql`, `discovery-deep.sql`,
`ai-discovery.conf`, `signatures.sql`, `agents-darwin.sql`, `agents-linux.sql`,
`fleet-policies.yml`, `discover`, `container-scan`, `classify`, `agents.yaml`, `routes.yaml`,
`ai-discovery-darwin.sh`, `ai-discovery-linux.sh`.

You do not need all of them. Which you take depends on where the thing runs.

**On the endpoint**

| | |
|---|---|
| `discovery-darwin.sql`<br>`discovery-linux.sql` | The query for each platform. Take the one that matches — `bin/discover` picks by `uname -s`, so you can ship both |
| `discovery-deep.sql` | The container-image query, and a supplement rather than a superset. `bin/container-scan` is the only thing that runs it, because the wall-clock bound lives there — and `bin/discover --deep` reaches it by calling that. Take this file if you use either |
| `ai-discovery.conf` | The osqueryd pack, carrying every platform's queries with osqueryd's own per-query `platform` field. Take this *instead of* the `.sql` files if you schedule through osqueryd rather than calling `bin/discover` |
| `discover` | Runs the query for the platform it is on and prints one JSON array |
| `container-scan` | Runs the deep query under a time limit. The only supported way to run it |

**Off the machine**

| | |
|---|---|
| `classify` | Turns collected evidence into agent names. Never runs on the endpoint |
| `agents.yaml` | What the evidence is matched against. Add a signature here and it re-matches evidence you already collected |
| `routes.yaml` | How each kind of evidence is matched — a bundle id, a Debian package, an npm install, a config directory. The matcher, the validator, the coverage report and lint all read this one file, and `classify` expects it beside `agents.yaml` |

**On the endpoint, when you cannot run the classifier**

| | |
|---|---|
| `agents-darwin.sql`<br>`agents-linux.sql` | A query that returns the agent names directly, one row per agent found. Run it with `sudo osqueryi --json < agents-darwin.sql`. It does not look at container images, because that part of the scan needs a time limit that only `container-scan` provides |
| `signatures.sql` | The catalog converted to SQL. `discover --names` uses it to turn an inventory into a list of names. Keep it next to `discover`; nothing else uses it |
| `fleet-policies.yml` | One Fleet policy per agent per platform. A policy fails on a host that has the agent, which puts those hosts on Fleet's failing list. Load with `fleetctl apply -f fleet-policies.yml` |

All three are **generated** from `agents.yaml`, and CI checks they find the same agents as
`classify`. When you add a signature to the catalog, you have to redeploy these files for them
to see it. The JSON inventory does not need that, because it is matched later, off the
machine.

**Or, instead of the endpoint half: one file**

| | |
|---|---|
| `ai-discovery-darwin.sh`<br>`ai-discovery-linux.sh` | Everything in the endpoint table above plus `signatures.sql`, for one platform, packed into one self-extracting script — for a machine that can host a script and not a package. It takes the same arguments as `bin/discover` and installs nothing |

**A bundle does not contain the catalog or the classifier.** It does contain `signatures.sql`,
so `--names` works from a bundle. Everything else it produces is the raw inventory, which you
classify off the machine as before. A bundle also needs `base64` and `tar` on the machine,
which the loose files do not.

If you take the loose files, ship `bin/`, `dist/` and `catalog/` **side by side**. Both
`bin/discover` and `bin/classify` resolve what they need relative to their own parent, so loose
in one folder neither finds it.

## What it collects, and what it does not

The queries read **names, paths, versions and declared permissions**. That is all.

They **never**:

- read the contents of any file
- capture secret or credential values
- touch browser history, cookies, or saved passwords
- execute a discovered binary to ask it anything

The strength of shipping queries rather than an agent is that you do not have to take that on
trust. It is SQL. Read `dist/discovery-darwin.sql` in ten minutes and verify it yourself.

This tool also **does nothing to the machine**. No blocking, no remediation, and no network
call from anything that runs on the endpoint. It reports; you decide.

`bin/classify`, which runs off the endpoint, is the one part that talks to the network: one
anonymous usage event per run, counts only — never a path, a hostname or an agent identifier.
`--telemetry-check` prints exactly what would be sent, `AI_DISCOVERY_TELEMETRY=0` turns it
off, and [`docs/telemetry.md`](docs/telemetry.md) lists every field.

### 📋 What it looks for — [`docs/agents.md`](docs/agents.md)

Every agent in the catalog, every identifier each is matched on, and the CI scenario that
installs the real software and proves it. Generated and gated by lint, so it cannot describe a
catalog that has moved on without it. What the suite *cannot* prove is kept beside it, in
[`docs/limits.md`](docs/limits.md).

**[Open the coverage report →](docs/agents.md)**

## What it cannot see

A discovery tool that hides its blind spots is worse than none, so they live in one place —
[`docs/blind-spots.yaml`](docs/blind-spots.yaml) — and are rendered into
[`docs/limits.md`](docs/limits.md). They are
properties of the platform and the osquery tables rather than gaps in the test suite: no
amount of coverage moves them.

The ones most likely to matter to you: anything inside a VM or a container, snap and Flatpak
packages (osquery has no table for either), AppImage installs, and what an agent *does* as
opposed to what it is permitted to do.

**[Read them in context →](docs/limits.md#what-osquery-cannot-see)**

## Containers

An agent in a container leaves nothing on the host that any other query reads, so one opt-in
branch asks the Docker daemon — under a wall-clock bound, because `docker_images` never
returns against a daemon that accepts the connection and does not answer.

```console
$ sudo bin/discover --deep | bin/classify     # base inventory plus containers
```

**[How the bound works, the exit codes, and how image names resolve →](docs/containers.md)**

## Running it on a fleet

**Do not put these queries on a synchronous reporting path** — they can hang rather than fail.
Schedule `bin/discover --write` and read the file; the `status.txt` beside it is one line whose
vocabulary is a contract, so a consumer can always tell a clean machine from a branch that
could not look. Scheduling and transport are yours to supply, and so is classification at
scale unless you match on the endpoint; this repo ships the queries, the runner, the guard and
the bound.

**If your tool only stores one value per machine**, like a Jamf Extension Attribute, use
`bin/discover --names`. It prints the agent names and the status as one line. If you use
Fleet, load `fleet-policies.yml` to get one policy per agent.

**[The scheduled writer, the status line, the one-file bundle, and the one-line and Fleet options →](docs/deployment.md)**

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
