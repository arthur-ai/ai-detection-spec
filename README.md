# osquery-ai-discovery

**osquery queries that find AI agents on a Mac.** Which desktop apps, CLI tools, browser
extensions and local models are installed, how each one got there, and what browser extensions
are permitted to access.

> **macOS only.** These queries target macOS and are tested against it. Nothing here works on
> Linux or Windows today. That may change; claiming otherwise now would waste your time.

### 📋 [What we detect, and what tests it →](docs/agents.md)

Every agent, every identifier, and what proves each one — **generated and kept current by CI**,
so it can never describe a catalog that has moved on without it. The numbers are counted from
the tree at generation time, never written by hand.

## Why this exists

Every team trying to inventory AI tooling rediscovers the same facts: that Cursor's bundle
identifier is an opaque ToDesktop string, that ChatGPT's desktop app is `com.openai.codex` and
not `com.openai.chat`, that a single agent ships through a Homebrew cask *and* npm *and* a curl
installer. None of it is written down anywhere.

This is that knowledge, as queries you can run and a catalog you can read.

## Requirements

| | Minimum | Tested on |
|---|---|---|
| macOS | Apple Silicon or Intel. **No lower bound established** — see below | 15.7.7 (CI) and 26 |
| osquery | **5.10.0** — every query declares it in `min-osquery:` | 5.23.1 |
| `bash` | 3.2 — macOS system `bash`, so `/bin/bash` is enough | 3.2.57 |
| `python3` | **3.7** (`subprocess` `capture_output`) — for `bin/classify`, `bin/discover`'s writer, and `tools/` | 3.12 |
| `curl` | System `curl`. Only used to health-probe the Docker socket | — |
| PyYAML | Only for `bin/classify` and `tools/validate_catalog.py`, which read the catalog | — |
| Docker | Optional, and only for container images | Docker Desktop 28.4.0 |

Running the queries needs **osquery alone**. `python3` and PyYAML are for the classifier and
the scheduled writer, not the endpoint's reporting path — which is a `cat`.

`sudo` is needed because some tables read other users' home directories. Without it you see
only your own account.

**Two cautions on the table above.** The macOS row says *no lower bound established* rather
than naming one: these queries are tested on the two versions listed and nothing older, so a
floor would be a guess. And on a fleet, `/usr/bin/python3` is a **stub** until Command Line
Tools are installed — on a Mac without them the scheduled writer produces nothing at all,
which surfaces as `no-cache` rather than as an error.

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
    port    18789
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
  {"kind":"port", "id":"11434",                        "loc":"/Applications/Ollama.app/…/ollama"},
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

Stated plainly, because a discovery tool that hides its blind spots is worse than none:

| Blind spot | Why |
|---|---|
| Anything inside a VM | The queries see the host filesystem, not a guest's |
| What is *running* in a container | `--deep` lists container **images**, and an image named `ollama/ollama` is evidence. What a running container is doing is not: `docker_containers` needs a per-container inspect document osquery reads strictly, and a hand-built one it merely accepts is worse than none |
| Containers outside Docker Desktop | Colima, Rancher Desktop and Podman keep their sockets elsewhere, and `docker_images` does not read containerd or Podman image stores at all. On those Macs `--deep` says "did not scan" rather than "none" |
| An untagged (dangling) image | Whether `docker_images` reports one is untested — no dangling image could be produced on the machine this was measured on. Treat it as unknown, not as covered |
| Agents on a cloud dev box or Codespace | Same reason. The scanner sees the machine it runs on |
| Which filesystem roots an MCP server exposes | Requires parsing arbitrary JSON config; osquery has no table for it |
| Outbound destinations by hostname | `process_open_sockets` returns an IP, not a name |
| A cloned-but-never-run source checkout | Nothing has been created on disk yet |
| Which agent holds a port, when it runs under an interpreter | A port is only attributed to an agent when the process holding it names that agent — otherwise 8080-held-by-java would be reported as llama.cpp. An agent run through `node` or `python` reports the interpreter's path, so the `ports` route is nearly inert for it. Measured on a real OpenClaw gateway: the listener opened, the row was collected, and the classifier correctly declined it |
| What an agent *does* | Every route here reports presence and declared capability. `permissions` says an extension **may** read every page, never that it did. No osquery table carries use |
| The identity of a sideloaded extension | osquery derives `identifier` from the manifest `key`, which unpacked and sideloaded extensions do not carry — so they report an **empty** one. The Web Store's signed CRX does carry it |
| VS Code extensions | osquery has no table for them at all. An agent shipping as one is invisible on that route, whatever else it also installs |
| Behaviour that only appears after launch or sign-in | Installing proves the bundle id. Nothing here launches an app — `open -a` needs an Aqua session and SSH has none — so first-launch launchd jobs, listening ports and state directories go unobserved, and account-gated products are never signed in to |

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
everything else. Three carry one: `ollama`, `llama-cpp`, `aider`. **An image
name is chosen by whoever tagged it**, which no other route here is true of: `docker tag
alpine ollama/ollama` produces an Ollama finding and nothing can tell it from the real image.
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

## Contributing

New AI tools appear weekly and identifiers change under you. Corrections and additions are the
most useful thing you can send.

**A signature contribution needs a passing test scenario, not a plausible-looking identifier.**
We shipped `bot.molt.mac` for OpenClaw once. It came from the vendor's own Homebrew metadata, it
looked entirely right, and it matched nothing on any Mac. The real identifier is
`ai.openclaw.mac`, and only installing the thing revealed it.

See [CONTRIBUTING.md](CONTRIBUTING.md). First response within five working days.

## License

MIT. See [LICENSE](LICENSE).

Maintained by the Arthur Unify team.
