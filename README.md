<div align="center">

# 🔎 ai-detection-spec

**An open format for finding the AI agents on a machine, and a catalog in which every
identifier was proved by installing the real software.**

[![CI](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-113%2F113-2E7D57)](docs/agents.md)
[![osquery](https://img.shields.io/badge/osquery-5.23.1-1D4E89)](https://osquery.io)
[![macOS](https://img.shields.io/badge/macOS-shipping-2E7D57)](osquery/README.md#requirements)
[![Linux](https://img.shields.io/badge/Linux-shipping-2E7D57)](osquery/README.md#requirements)
[![Windows](https://img.shields.io/badge/Windows-not_yet-6B7480)](osquery/README.md#scope-so-you-know-what-you-are-getting)
[![License](https://img.shields.io/badge/license-Apache--2.0-6B7480)](LICENSE)

**[What we detect, and what tests it →](docs/agents.md)**

</div>

Teams taking stock of the AI tools on their machines keep rediscovering the same facts the hard
way: that Cursor's bundle id is an opaque ToDesktop string, that ChatGPT's desktop app is
`com.openai.codex` on current builds and `com.openai.chat` on the ones before, so a fleet needs
both, that one agent ships as a Homebrew cask *and* an npm package *and* a curl installer. This
repository writes those facts down, keeps them true, and defines a format so that any tool can
use them.

## What is here

| | |
|---|---|
| [**`SPEC.md`**](SPEC.md) | **The Open Agent Detection Format.** What a catalog of agents contains, what evidence a collector reports, and how the two are matched, so that tools written by different people give the same answer about the same machine |
| [`schema/`](schema) | JSON Schemas for a catalog and for the evidence a collector reports |
| [`conformance/`](conformance) | The test vectors a matcher must pass |
| [`catalog/`](catalog) | This repository's catalog: **42 agents and 113 identifiers**, each one seen on a real install in CI |
| [`bin/classify`](bin/classify) | The reference matcher. It reads collected evidence and names the agents it proves |
| [`osquery/`](osquery) | **The first binding:** osquery queries for macOS and Linux, and the scripts that run them on a machine. [Start here](osquery/README.md) to find the agents on yours |

## What the format guarantees

**An empty result is never ambiguous.** A collector that could not read something says so, so
"nothing was found" and "nothing was looked at" are different answers.

**Every identifier was seen on a real install.** Not taken from documentation, which is how this
repository once shipped an identifier that matched nothing on any Mac. CI installs the real
software, the build fails if an identifier does not appear, and [the report](docs/agents.md) is
generated, so it cannot flatter itself.

## What counts as an agent

Software that acts on your behalf. A protocol SDK is a library an agent is *built with*, a
gateway is something it *calls through*, a model runner *serves* models, and a container runtime
is *how we look*. All four were catalogued once and all four were removed: counting them as
agents overstates what was found on a machine.

## Using it

- **To find agents on your machines**, use the osquery binding: [its README](osquery/README.md)
  has the quickstart, what each release file is for, and how to run it across a fleet.
- **To build your own collector or matcher**, implement [`SPEC.md`](SPEC.md), validate against
  [`schema/`](schema), and pass [`conformance/vectors.json`](conformance/vectors.json).
- **To use only the data**, take `catalog/agents.yaml` and `catalog/routes.yaml`, which every
  release attaches.

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

**Apache-2.0** — use it, fork it, vendor it into your own tooling, ship it inside a product.
See [LICENSE](LICENSE) and [NOTICE](NOTICE). Releases up to and including v0.14.1 were published
under MIT, and copies of those stay MIT.

Maintained by the Arthur Unify team, and built on [osquery](https://osquery.io), which does all
the hard parts.
