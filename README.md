<div align="center">

# 🔎 osquery-ai-discovery

**Find the AI agents on your fleet — with SQL you can read.**

Which coding agents, chat clients, AI browsers and browser extensions are installed,
*which route each one arrived by*, and what those extensions are permitted to access.

[![CI](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/osquery-ai-discovery/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-110%2F111-A26A16)](docs/agents.md)
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
runtime dependencies beyond osquery.

### Why you might like it

- **🔍 Nothing hidden.** It is SQL. Read `dist/discovery-darwin.sql` (or
  `dist/discovery-linux.sql`) and you know exactly what it collects: names, paths, versions
  and declared permissions, and nothing else. Read `dist/agents-darwin.sql` and you also see
  every identifier it matches on.
- **✅ Every signature tested against a real install.** Not against documentation — which is how
  this repo once shipped an identifier that matched nothing on any Mac. **Every identifier** is
  covered by a test that runs in CI, the build fails if one is not, and
  [the report](docs/agents.md) is generated, so it cannot flatter itself.
- **🧩 One catalog, matched where you need it.** Off the machine with the classifier, or on
  it with a query, a Fleet policy or a Jamf Extension Attribute. Same catalog either way.
- **🗺 Blind spots stated up front.** [Written down](docs/limits.md), because a discovery tool
  that hides them is worse than none.

## What you get

| | | |
|---|---|---|
| 🗂 | **A query** | Runs on each machine and lists what is installed — apps, packages, browser extensions, state directories. **No agent name appears anywhere in it.** It reports what it finds; which of those findings add up to an agent is decided later, by the classifier. One per platform, because macOS and Linux read different tables |
| ▶️ | **A runner** | Runs that query on the endpoint and prints the result as one JSON array. A second one covers agents packaged as Docker images, separately and on a time limit, because a wedged Docker daemon never answers and would otherwise hang the scan |
| 🔎 | **A classifier and its catalog** | Reads the collected JSON and tells you which agents are on the machine, matching the evidence against **42 agents and 111 identifiers**. It runs wherever you keep the output, never on the endpoint |
| 🧾 | **The same catalog, as SQL** | A query that returns the agent names directly, a set of Fleet policies, and `bin/discover --names`, which prints the names as one line for a Jamf Extension Attribute |

**Two ways to match, one catalog.** Pick the one that fits how you collect:

- **Match off the machine.** The endpoint runs the inventory query and the classifier matches
  the result against the catalog wherever you keep it. Add a signature to the catalog and it
  re-matches the evidence you already have, without going back to the fleet. This is the
  shape for a collector that stores the JSON.
- **Match on the machine.** Run `agents-darwin.sql` or `agents-linux.sql` and get the agent
  names straight from osquery, load `fleet-policies.yml` into Fleet, or point a Jamf
  Extension Attribute at `bin/discover --names`. This is the shape for tools that work with
  one query or one value per machine. A new signature reaches these files when you redeploy
  them.

Both are generated from `catalog/agents.yaml`, and CI checks that they find the same agents
on the same evidence. There is one place to add a signature either way.

**[What a release attaches](#what-a-release-attaches)** names every file and says which machine
it belongs on.

## Scope, so you know what you are getting

**macOS and Linux ship. Windows does not.** CI installs the real software on macOS runners, on
`ubuntu-24.04` and `ubuntu-24.04-arm`, and in Debian 12, Rocky 9, Fedora 41 and Amazon Linux
2023 containers, so both platforms are held to the same standard: a signature is verified when
a scenario installs the actual software and asserts the classifier finds it.

**What is platform-specific.** Declared in [`catalog/routes.yaml`](catalog/routes.yaml), which
the matcher, the validator, the coverage report and lint all read — so this table is the
registry rather than a description of it:

| | routes | osquery tables |
|---|---|---|
| **macOS only** | `bundle_ids`, `homebrew`, `launchd_prefixes`, `running_apps` | `apps`, `homebrew_packages`, `launchd`, `plist` — all in osquery's `specs/darwin` |
| **Linux only** | `deb_packages`, `desktop_ids`, `rpm_packages`, `systemd_prefixes` | `deb_packages`, `rpm_packages`, `systemd_units`, `file` |
| **Both** | `binaries`, `extension_ids`, `images`, `jetbrains_plugins`, `model_stores`, `native_messaging_hosts`, `npm`, `process_paths`, `pypi`, `running_npm`, `state_dirs`, `vscode_extensions` | `npm_packages`, `chrome_extensions`, `vscode_extensions`, `jetbrains_plugins`, `docker_images`, `processes`, `file` |

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
| osquery | **5.10.0** for `bin/discover --write`, which runs each query separately and reports any that fail. **5.18.0** to run the whole inventory as one query, because the JetBrains query needs a table added in that release |
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

# Match on the machine: one query, agent names out
$ sudo osqueryi --json < dist/agents-darwin.sql
$ sudo bin/discover --names                   # the same as one line, for a Jamf Extension Attribute

# Match off the machine: inventory out, classify wherever you keep the output
$ sudo osqueryi --json < dist/discovery-darwin.sql | bin/classify
$ sudo bin/discover --deep | bin/classify     # the same, plus container images

# On Linux, the same thing. The bin/discover commands need no change -- it picks the
# platform by `uname -s`. The osqueryi commands take the -linux files instead.
$ sudo apt install ./osquery_5.23.1-1.linux_amd64.deb
$ sudo osqueryi --json < dist/agents-linux.sql
$ sudo osqueryi --json < dist/discovery-linux.sql | bin/classify
```

`dist/` is committed, so a clone is ready to run — there is nothing to build. Pinning a
tagged release is the recommended posture, and one ships the same artifacts plus the
catalog; see [SECURITY.md](SECURITY.md).

For a fleet, do not run either of those on a synchronous reporting path — schedule
`bin/discover --write` and `cat` the file. See [Running it on a fleet](docs/deployment.md).

`bin/classify` prints the agents it found and the evidence for each:

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

Run the inventory query alone and you get the raw rows it matched those from:

```json
[
  {"kind":"app",  "id":"com.anthropic.claudefordesktop","ver":"1.37937.2","loc":"/Applications/Claude.app"},
  {"kind":"app",  "id":"ai.openclaw.mac",              "ver":"2026.7.1", "loc":"/Applications/OpenClaw.app"},
  {"kind":"npm",  "id":"@openai/codex",                "ver":"0.150.1"},
  {"kind":"brew", "id":"openclaw",                     "ver":"2026.8.1", "loc":"/opt/homebrew/Caskroom/openclaw"},
  {"kind":"file", "id":"/Users/dana/.local/bin/claude"},
  {"kind":"ext",  "id":"kbhkmjgjmpbaeoinipbngmmpjppjlkmm","perms":"tabs,cookies,nativeMessaging,<all_urls>"}
]
```

## What a release attaches

**Fifteen assets**: `discovery-darwin.sql`, `discovery-linux.sql`, `discovery-deep.sql`,
`ai-discovery.conf`, `signatures.sql`, `agents-darwin.sql`, `agents-linux.sql`,
`fleet-policies.yml`, `discover`, `container-scan`, `classify`, `agents.yaml`, `routes.yaml`,
`ai-discovery-darwin.sh`, `ai-discovery-linux.sh`.

You do not need all of them. Which you take depends on where the thing runs.

**On the endpoint: the inventory**

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

**On the endpoint: the match**

| | |
|---|---|
| `agents-darwin.sql`<br>`agents-linux.sql` | A query that returns the agent names directly, one row per agent found. Run it with `sudo osqueryi --json < agents-darwin.sql`. It does not look at container images, because that part of the scan needs a time limit that only `container-scan` provides |
| `signatures.sql` | The catalog converted to SQL. `discover --names` uses it to turn an inventory into a list of names. Keep it next to `discover`; nothing else uses it |
| `fleet-policies.yml` | One Fleet policy per agent per platform. A policy fails on a host that has the agent, which puts those hosts on Fleet's failing list. Load with `fleetctl apply -f fleet-policies.yml` |

These three are generated from `agents.yaml`; redeploy them when the catalog changes.

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

This tool also **does nothing to the machine**. No blocking, no remediation, and no network
call from anything that runs on the endpoint. It reports; you decide.

`bin/classify`, which runs off the endpoint, is the one part that talks to the network: one
anonymous usage event per run, counts only — never a path, a hostname or an agent identifier.
`--telemetry-check` prints exactly what would be sent, `AI_DISCOVERY_TELEMETRY=0` turns it
off, and [`docs/telemetry.md`](docs/telemetry.md) lists every field.

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
could not look. Scheduling and transport are yours to supply; this repo ships the queries,
the runner, the guard, the bound, and the matching, either on the machine or off it.

**With Jamf**, point an Extension Attribute at `bin/discover --names`. It prints the agent
names and the status as one line, which Smart Groups can match on. **With Fleet**, load
`fleet-policies.yml` to get one policy per agent. **With your own collector**, store the JSON
and run `bin/classify` over it.

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
