# osquery-ai-discovery

**osquery queries that find AI agents on a Mac.** Which desktop apps, CLI tools, browser
extensions and local models are installed, how each one got there, and what browser extensions
are permitted to access.

> **macOS only.** These queries target macOS and are tested against it. Nothing here works on
> Linux or Windows today. That may change; claiming otherwise now would waste your time.

## Why this exists

Every team trying to inventory AI tooling rediscovers the same facts: that Cursor's bundle
identifier is an opaque ToDesktop string, that ChatGPT's desktop app is `com.openai.codex` and
not `com.openai.chat`, that a single agent ships through a Homebrew cask *and* npm *and* a curl
installer. None of it is written down anywhere.

This is that knowledge, as queries you can run and a catalog you can read.

## Quickstart

```console
$ brew install --cask osquery          # or https://osquery.io/downloads
$ sudo osqueryi --json < dist/discovery.sql | bin/classify
```

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

## What it cannot see

Stated plainly, because a discovery tool that hides its blind spots is worse than none:

| Blind spot | Why |
|---|---|
| Anything inside a VM or container | The queries see the host filesystem, not a guest's |
| Agents on a cloud dev box or Codespace | Same reason. The scanner sees the machine it runs on |
| Which filesystem roots an MCP server exposes | Requires parsing arbitrary JSON config; osquery has no table for it |
| Outbound destinations by hostname | `process_open_sockets` returns an IP, not a name |
| A cloned-but-never-run source checkout | Nothing has been created on disk yet |

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
