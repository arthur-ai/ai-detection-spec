<div align="center">

# 🔎 osquery-ai-discovery

**Find the AI agents on your fleet — with SQL you can read.**

Which coding agents, chat clients, AI browsers and browser extensions are installed,
*which route each one arrived by*, and what those extensions are permitted to access.

[![CI](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-48%2F48-2E7D57)](docs/agents.md)
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
container scan. The classifier, which runs off the machine, sends one anonymous usage event
per run: counts, never identifiers, described field by field in
[`docs/telemetry.md`](docs/telemetry.md) and switched off with `AI_DISCOVERY_TELEMETRY=0`.

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
- **🗺 Blind spots stated up front.** [Written down](docs/agents.md), because a discovery tool
  that hides them is worse than none.

## What you get

| | | |
|---|---|---|
| 🗂 | **`dist/discovery-darwin.sql`**<br>**`dist/discovery-linux.sql`** | One SQL file to run on the endpoint, per platform — the tables are disjoint, so there is no single file that runs on both, and no unqualified name pretending otherwise. **No agent name appears in anything they match on** — the queries look for shapes (an app bundle, a deb, an npm global, a state dotdir), never for "Cursor" or "OpenClaw" — so you never edit them when a new agent appears. About **760 rows** on a developer Mac, 17.9 KB gzipped |
| 🧭 | **`catalog/agents.yaml`** | The 17 agents and 50 identifiers those rows are matched **against**, off the machine. Add a signature here and it re-matches evidence you already collected — no going back to the fleet |
| 🧱 | **`catalog/routes.yaml`** | The route registry: every way an identifier can arrive, which platform it exists on and how it is matched. The matcher, the validator, the coverage report and lint all derive from this one file |
| 🔎 | **`bin/classify`** | Does that matching, wherever you keep the output |
| 🐳 | **`bin/container-scan`** | The container half, run separately and on a hard time bound, because a wedged Docker daemon blocks forever |
| 📋 | **[`docs/agents.md`](docs/agents.md)** | Every identifier and the CI test that proves it. Generated — the numbers are counted, never typed |

**Why the split matters.** The endpoint *enumerates* and the matching happens elsewhere. A
scanner that knows the agent names has to be redeployed to the whole fleet every time the list
changes, and can only ever find what it already knew to look for. This one collects the
evidence once and answers new questions about it later.

## Scope, so you know what you are getting

**macOS and Linux ship. Windows does not.** CI installs the real software on macOS runners and
on `ubuntu-24.04`, plus a `fedora:41` container for the rpm family, so both platforms are held
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
| `python3` | **3.7** (`subprocess` `capture_output`) — for `bin/classify`, `bin/discover`'s writer and `tools/` |
| PyYAML | Only for the tools that read the catalog: `bin/classify` and `tools/validate_catalog.py` |

Running the queries needs **osquery alone**. `python3` and PyYAML are for the classifier and
the scheduled writer, not the endpoint's reporting path — which is a `cat`. Which OS versions
each scenario has actually run on is recorded in [`docs/agents.md`](docs/agents.md).

`sudo` is needed because some tables read other users' home directories. Without it you see
only your own account.

## Quickstart

```console
$ brew install --cask osquery          # or https://osquery.io/downloads
$ sudo osqueryi --json < dist/discovery-darwin.sql | bin/classify
$ sudo bin/discover --deep | bin/classify     # the same, plus container images

# On Linux, the same thing. bin/discover picks the artifact by `uname -s`, so the
# second form needs no change at all.
$ sudo apt install ./osquery_5.23.1-1.linux_amd64.deb
$ sudo osqueryi --json < dist/discovery-linux.sql | bin/classify
```

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

`bin/classify`, which runs off the endpoint, is the one part that talks to the network: it
sends a single anonymous usage event per run so that questions like "is anyone on a stale
catalog" have an answer. It carries counts — never a path, a hostname, or an agent
identifier. `bin/classify --telemetry-check` prints exactly what would be sent and sends
nothing; `AI_DISCOVERY_TELEMETRY=0` turns it off; [`docs/telemetry.md`](docs/telemetry.md)
lists every field.

### 📋 What it looks for — [`docs/agents.md`](docs/agents.md)

Every agent in the catalog, every identifier each is matched on, and the CI scenario that
installs the real software and proves it. Generated and gated by lint, so it cannot describe a
catalog that has moved on without it — and it names what the suite *cannot* prove alongside
what it can.

**[Open the coverage report →](docs/agents.md)**

## What it cannot see

A discovery tool that hides its blind spots is worse than none, so they live in one place —
[`docs/blind-spots.yaml`](docs/blind-spots.yaml) — and are rendered into the report. They are
properties of the platform and the osquery tables rather than gaps in the test suite: no
amount of coverage moves them.

The ones most likely to matter to you: anything inside a VM or a container, snap and Flatpak
packages (osquery has no table for either), AppImage installs, and what an agent *does* as
opposed to what it is permitted to do.

**[Read them in context →](docs/agents.md#what-osquery-cannot-see)**

## Containers

An agent in a container is invisible to every other query here — no `.app` bundle, no
Homebrew entry, no npm global, no dotdir on the host. This is the only branch that sees it,
and it is opt-in because it is the only part of this that talks to a daemon.

```console
$ sudo bin/discover --deep | bin/classify     # base inventory plus container images
$ sudo bin/container-scan --pretty            # containers alone
```

Opt-in because `docker_images` cannot be bounded from inside osquery: against a daemon that
accepts the connection and never answers, the query never returns, so the bound has to be a
kill on a separate process. Every outcome carries a reason rather than an empty result.

**[How the bound works, the exit codes, and how image names resolve →](docs/containers.md)**

## Running it on a fleet

**Do not put these queries on a synchronous reporting path** — they can hang rather than fail.
Schedule the writer and read the file:

```console
# on a schedule, as root
$ bin/discover --write /var/lib/ai-discovery/inventory.json \
               --status /var/lib/ai-discovery/status.txt

# from wherever you collect, whenever you like
$ cat /var/lib/ai-discovery/inventory.json
$ cat /var/lib/ai-discovery/status.txt
```

`status.txt` is one line and its vocabulary is a contract, so a consumer can always tell a
clean machine from a branch that could not look. Scheduling, transport and classification at
scale are yours to supply; this repo ships the queries, the runner, the guard and the bound.

**[The status contract, and what a deployment has to supply →](docs/deployment.md)**

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
