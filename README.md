<div align="center">

# 🔎 ai-detection-spec

**An open specification for finding the AI agents on a machine, and a catalog in which every
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
repository writes those facts down, keeps them true, and publishes them as an open
specification, so that any tool can use them.

## What is here

| | |
|---|---|
| [**`SPEC.md`**](SPEC.md) | **The specification.** What a catalog of agents contains, what evidence a binding reports, and how the two are matched, so that tools written by different people give the same answer about the same machine |
| [`schema/`](schema) | JSON Schemas for a catalog and for the evidence a binding reports |
| [`conformance/`](conformance) | The test vectors a matcher must pass |
| [`catalog/`](catalog) | This repository's catalog: **42 agents and 113 identifiers**, each one seen on a real install in CI |
| [`bin/classify`](bin/classify) | The reference matcher. It reads collected evidence and names the agents it proves |
| [`osquery/`](osquery) | **The first binding:** osquery queries for macOS and Linux, and the scripts that run them on a machine. [Start here](osquery/README.md) to find the agents on yours |

## What the spec guarantees

**An empty result is never ambiguous.** A binding that could not read a source says so, so
"nothing was found" and "nothing was looked at" are different answers.

**Every identifier carries its proof.** An identifier enters a catalog only after an
installation of the real software produced it, and the catalog records which. In this
repository's catalog that installation is a CI scenario, and [the report](docs/agents.md) is
generated from what the runs recorded.

## What counts as an agent

Software that acts on your behalf. Libraries, gateways, model runners, container runtimes and
completion engines do not count, however easy they are to detect, because counting them
overstates what was found. [SPEC.md §3](SPEC.md#3-scope-what-counts-as-an-agent) is the test.

## Adopting it

The spec is open, and it is meant to be implemented by tools other than the ones here: an
MDM, an EDR, an asset inventory, a script of your own. Its parts are independent, so take the
one you need.

- **To find agents on your machines today**, use the osquery binding: [its
  README](osquery/README.md) has the quickstart, what each release file is for, and how to run
  it across a fleet.
- **To collect evidence with your own tool**, write a binding ([§8](SPEC.md#8-bindings)): emit
  rows that validate against [`schema/evidence.schema.json`](schema/evidence.schema.json), emit
  a scan marker for every source you could not read, declare your fields under
  `bindings.<name>` on the routes you feed, and prove identifiers from your own rows. Any
  conforming matcher then reads your output.
- **To match in your own tool**, implement [§6](SPEC.md#6-matching) and pass
  [`conformance/vectors.json`](conformance/vectors.json). The vectors are the contract:
  `bin/classify` is one implementation of them and has no authority they do not give it.
- **To use only the catalog**, take `catalog.json` from a release. It is a catalog document
  that validates against [`schema/catalog.schema.json`](schema/catalog.schema.json), with each
  identifier's status, package URL and the CI runs that proved it. `catalog/agents.yaml` and
  `catalog/routes.yaml` are this repository's authoring form, which `tools/export.py` turns
  into that document.

If something in the spec stops you adopting it, [open an
issue](https://github.com/arthur-ai/ai-detection-spec/issues): that is a defect in the spec.

## Used by

- [Arthur Platform](https://www.arthur.ai/)
- [Deckard](https://github.com/arthur-ai/arthur-deckard)

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

[CONTRIBUTING.md](CONTRIBUTING.md) has the details, and `tools/gates.sh` runs every fast check,
so you can see a green result before you open anything. **First response within five working
days.**

## License

**Apache-2.0** — use it, fork it, vendor it into your own tooling, ship it inside a product.
See [LICENSE](LICENSE) and [NOTICE](NOTICE). Releases up to and including v0.14.1 were published
under MIT, and copies of those stay MIT.

Maintained by the Arthur Unify team, and built on [osquery](https://osquery.io), which does all
the hard parts.
