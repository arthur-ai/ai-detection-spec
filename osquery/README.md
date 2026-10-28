# The osquery binding

The first binding of [ai-detection-spec](../SPEC.md): osquery queries that collect agent
evidence on macOS, Linux and Windows, and the scripts that run them on a machine. The
repository's [catalog](../catalog/agents.yaml) says which of those things are agents. [The
root README](../README.md) says what counts as an agent and how every identifier is proved.

- **It is SQL you can read.** `osquery/dist/discovery-darwin.sql`,
  `osquery/dist/discovery-linux.sql` and `osquery/dist/discovery-windows.sql` are everything
  it collects: names, paths, versions and declared permissions.
- **The inventory names no agent.** It reports what is installed, and matching happens
  later, so a catalog fix re-matches evidence you already collected.
- **One catalog, matched where you need it**: off the machine with `bin/classify`, or on it
  with a query, a Fleet policy or a Jamf Extension Attribute.
- **Its blind spots are [written down](../docs/limits.md).**

## Quickstart

```console
$ git clone https://github.com/arthur-ai/ai-detection-spec
$ cd ai-detection-spec                 # or download the assets from a tagged release
$ brew install --cask osquery          # or https://osquery.io/downloads
$ python3 -m pip install pyyaml        # for bin/classify only; the endpoint needs nothing

# Match on the machine: one query, agent names out
$ sudo osqueryi --json < osquery/dist/agents-darwin.sql
$ sudo osquery/bin/discover --names                   # the same as one line, for a Jamf Extension Attribute

# Match off the machine: evidence out, classify wherever you keep it. discover prints
# nothing and exits 1 when osqueryi fails, so a failed run cannot pass for a clean machine
$ sudo osquery/bin/discover | bin/classify
$ sudo osquery/bin/discover --deep | bin/classify     # the same, plus container images

# On Linux, osquery/bin/discover picks the platform itself, and osqueryi takes agents-linux.sql
$ sudo apt install ./osquery_5.23.1-1.linux_amd64.deb
$ sudo osqueryi --json < osquery/dist/agents-linux.sql

# On Windows there is no osquery/bin/discover, which is bash. Run osqueryi.exe from cmd,
# because Windows PowerShell 5.1's > writes UTF-16. Keep the || del: on a table it lacks,
# osqueryi.exe prints valid empty JSON and exits 1, which classify would call a clean machine
> "C:\Program Files\osquery\osqueryi.exe" --json < osquery\dist\agents-windows.sql
> "C:\Program Files\osquery\osqueryi.exe" --json < osquery\dist\discovery-windows.sql > inventory.json || del inventory.json
$ bin/classify < inventory.json                       # off the machine, as above
```

`osquery/dist/` is committed, so a clone has nothing to build. Pin a tagged release in
production ([SECURITY.md](../SECURITY.md)). On a fleet, schedule `osquery/bin/discover --write`
and read the file instead ([Running it on a fleet](#running-it-on-a-fleet)).

`bin/classify` prints each agent with its evidence:

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

The inventory alone is the evidence rows ([SPEC.md §5.1](../SPEC.md#51-evidence-rows)):

```json
[
  {"kind":"app",  "id":"com.anthropic.claudefordesktop","ver":"1.37937.2","loc":"/Applications/Claude.app"},
  {"kind":"npm",  "id":"@openai/codex",                "ver":"0.150.1"},
  {"kind":"file", "id":"/Users/dana/.local/bin/claude"},
  {"kind":"ext",  "id":"kbhkmjgjmpbaeoinipbngmmpjppjlkmm","perms":"tabs,cookies,nativeMessaging,<all_urls>"}
]
```

## Two ways to match

- **Off the machine.** The endpoint runs the inventory, and `bin/classify` matches the JSON
  wherever you keep it. A new signature re-matches evidence you already have.
- **On the machine.** osquery runs `agents-darwin.sql`, `agents-linux.sql` or
  `agents-windows.sql` and returns one row per agent. Fleet loads `fleet-policies.yml`. A Jamf
  Extension Attribute runs `osquery/bin/discover --names`, which prints one line. A new
  signature reaches these files only when you redeploy them.

Both ways read the same `catalog/agents.yaml`: `bin/classify` at run time, the on-machine
files when they are rendered. CI holds the two to the same answer on the same evidence.

## What a release attaches

**20 assets**: `discovery-darwin.sql`, `discovery-linux.sql`, `discovery-windows.sql`,
`discovery-deep.sql`, `ai-detection-spec.conf`, `signatures.sql`, `agents-darwin.sql`,
`agents-linux.sql`, `agents-windows.sql`, `fleet-policies.yml`, `discover`, `container-scan`,
`classify`, `agents.yaml`, `routes.yaml`, `catalog.json`, `catalog.schema.json`,
`evidence.schema.json`, `ai-detection-spec-darwin.sh`, `ai-detection-spec-linux.sh`.

Each asset runs on the endpoint or off it. The tables below group them that way, so take the
ones for the place you deploy to.

**On the endpoint: the inventory**

| | |
|---|---|
| `discovery-darwin.sql`<br>`discovery-linux.sql`<br>`discovery-windows.sql` | The query for each platform. `discover` picks between the first two by `uname -s`, so you can ship both. Windows has no `discover`; run the third with `osqueryi` ([quickstart](#quickstart)) |
| `discovery-deep.sql` | The container query, a supplement rather than a superset. Only `container-scan` runs it, because the wall-clock bound lives there |
| `ai-detection-spec.conf` | The osqueryd pack, every platform's queries with osqueryd's per-query `platform` field. Take it *instead of* the `.sql` files if you schedule through osqueryd |
| `discover` | Runs the query for its platform and prints one JSON array |
| `container-scan` | Runs the deep query under a time limit |

**Off the machine**

| | |
|---|---|
| `classify` | The reference matcher: evidence in, agents out. Never runs on the endpoint |
| `agents.yaml`, `routes.yaml` | The catalog in this repository's authoring form, which `classify` reads by default. `routes.yaml` must sit beside `agents.yaml` |
| `catalog.json` | The catalog as the spec defines it ([SPEC.md §4](../SPEC.md#4-catalog)), which any conforming matcher reads, `classify --catalog catalog.json` included: every identifier with its status, its package URL where one exists, and the CI runs that proved it |
| `catalog.schema.json`, `evidence.schema.json` | The spec's schemas. `classify` validates `catalog.json` against the first before reading it, which needs `jsonschema` |

**On the endpoint: the match**, generated from `agents.yaml`; redeploy them when it changes

| | |
|---|---|
| `agents-darwin.sql`<br>`agents-linux.sql`<br>`agents-windows.sql` | One row per agent found: `sudo osqueryi --json < agents-darwin.sql`. No container images, because those need `container-scan`'s bound |
| `signatures.sql` | The catalog as SQL, for `discover --names`. Keep it next to `discover` |
| `fleet-policies.yml` | One Fleet policy per agent per platform: `fleetctl apply -f fleet-policies.yml` |

**Or, instead of the endpoint files, one script**

| | |
|---|---|
| `ai-detection-spec-darwin.sh`<br>`ai-detection-spec-linux.sh` | The endpoint files and `signatures.sql` for one platform, in one self-extracting script that takes `discover`'s arguments and installs nothing. It needs `base64` and `tar` |

Loose files go **side by side**, as `bin/`, `dist/`, `catalog/` and `schema/`, because
`discover` and `classify` each resolve what they need from their own parent directory.

## What it collects, and what it does not

The queries read **names, paths, versions and declared permissions**. They never read a file's
contents, capture a secret or credential, touch browser history, cookies or saved passwords,
or run a discovered binary. Nothing that runs on the endpoint changes the machine or makes a
network call; `curl` talks only to the local Docker socket.

`bin/classify` sends one anonymous usage event per run, counts only. `--telemetry-check`
prints it and `AI_DETECTION_SPEC_TELEMETRY=0` turns it off
([docs/telemetry.md](../docs/telemetry.md)).

## What it cannot see

It cannot see inside a VM. Inside a container it sees only what `--deep` reads: images,
running containers and their labels. It cannot see snap and Flatpak packages or AppImage
installs. It reports what an agent *may* do, never what it does. These are limits of the
platform and of osquery's tables, not of the tests:
[docs/limits.md](../docs/limits.md#what-osquery-cannot-see) has the list.

## Containers

An agent in a container leaves nothing on the host that another query reads, so one opt-in
branch asks the Docker daemon, under a wall-clock bound, because `docker_images` never
returns against a daemon that accepts the connection and does not answer.
[docs/containers.md](docs/containers.md) has the bound, the exit codes and how image names
match.

## Running it on a fleet

Do not run the queries on a synchronous reporting path, because the container branch can
hang. Schedule `osquery/bin/discover --write` and read the file. Its `status.txt` is one line
that tells a clean machine from a branch that could not look. With Jamf, point an Extension
Attribute at `osquery/bin/discover --names`; with Fleet, load `fleet-policies.yml`; with your
own pipeline, store the JSON and run `bin/classify` over it.
[docs/deployment.md](docs/deployment.md) has the schedule, the status line, the one-file
bundle and what a deployment supplies.

**On Windows there is no `bin/discover`**, which is bash. The [quickstart](#quickstart) has
the one-machine command, and [docs/deployment.md](docs/deployment.md#windows) has what to
schedule on a fleet and how to read what comes back.

## Scope, so you know what you are getting

**macOS, Linux and Windows ship.** CI installs the real software on macOS runners, on Ubuntu
runners (x86_64 and arm64), in Debian, Rocky, Fedora and Amazon Linux containers, and on
Windows Server 2025 runners. Windows has the queries and the rendered match, not the endpoint
scripts; a native PowerShell binding, for fleets that run no osquery, is not built.

Each route's platform, and the osquery table and version floor behind it
([SPEC.md §8.1](../SPEC.md#81-osquery)), are declared in
[`catalog/routes.yaml`](../catalog/routes.yaml). Each platform reads its own tables, so each
composed `discovery-<platform>.sql` runs on its own platform only, though a source query
declared `posix` or `all` is composed into several.

## Requirements

| | Needs |
|---|---|
| macOS | Apple Silicon or Intel. No lower bound has been established |
| Linux | Any distro with dpkg or rpm. One artifact serves both: each package table returns no rows on the other family and exits 0 |
| Windows | osquery's x64 MSI, run as an administrator or SYSTEM. CI runs Windows Server 2025; no lower bound has been established, and osquery's arm64 build is untested |
| osquery | **5.10.0** for `osquery/bin/discover --write`, which runs each query separately and reports any that fail. **5.18.0** to run the whole inventory as one query, for the JetBrains table. **5.17.0** on Windows, for MSIX packages |
| `bash` | 3.2, the macOS system `bash` |
| `python3` 3.7 and PyYAML | Off the machine only: `bin/classify`, `tools/` and `osquery/tools/render_match.py`. `bin/classify` also needs `jsonschema` to read `catalog.json` |

`sudo` lets the queries read other users' home directories; without it you see only your own.
[CLAUDE.md](CLAUDE.md) has the closed list of what the endpoint scripts may call.
