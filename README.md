<div align="center">

# 🔎 ai-detection-spec

**An open specification for finding the AI agents on a machine. Every identifier in its
catalog comes from installing the real software.**

[![CI](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-119%2F119-2E7D57)](docs/agents.md)
[![osquery](https://img.shields.io/badge/osquery-5.23.1-1D4E89)](https://osquery.io)
[![macOS](https://img.shields.io/badge/macOS-shipping-2E7D57)](osquery/README.md#requirements)
[![Linux](https://img.shields.io/badge/Linux-shipping-2E7D57)](osquery/README.md#requirements)
[![Windows](https://img.shields.io/badge/Windows-shipping-2E7D57)](osquery/README.md#requirements)
[![License](https://img.shields.io/badge/license-Apache--2.0-6B7480)](LICENSE)

**[What we detect, and the test behind each →](docs/agents.md)**

</div>

Anyone taking stock of the AI tools on a fleet runs into the same surprises. Cursor's bundle
id is `com.todesktop.230313mzl4w4u92`, which you cannot guess from the product's name.
ChatGPT's desktop app renamed its bundle id from `com.openai.chat` to `com.openai.codex`, so a
fleet with old and new builds needs both. A single agent can arrive as a Homebrew cask, an npm
package or a curl installer, and each leaves a different trace. This repository records those
facts, checks each one against a real install, and publishes them as an open specification
that any tool can use.

## What is here

| | |
|---|---|
| [**`SPEC.md`**](SPEC.md) | **The specification.** What a catalog of agents contains, what evidence a collector reports (the spec calls a collector a *binding*), and how the two are matched, so that tools written by different people give the same answer about the same machine |
| [`schema/`](schema) | JSON Schemas for a catalog and for the evidence a binding reports |
| [`conformance/`](conformance) | The test vectors a matcher must pass |
| [`catalog/`](catalog) | This repository's catalog: **42 agents and 119 identifiers**, each one seen on a real install in CI |
| [`bin/classify`](bin/classify) | The reference matcher. It reads collected evidence and names the agents the evidence proves |
| [`osquery/`](osquery) | **The first binding:** osquery queries for macOS, Linux and Windows, and the scripts that run them on a Mac or a Linux machine. [Start here](osquery/README.md) to find the agents on your own machine |

## What the spec guarantees

**An empty result is never ambiguous.** No findings can mean a clean machine, or a scan that
could not look everywhere. The spec keeps those apart: a collector that cannot read something,
such as a Docker daemon that does not answer, must report that in its output. So a reader
never mistakes a scan that failed for a machine that is clean.

**Every identifier carries its proof.** An identifier enters a catalog only after an
installation of the real software produced it, and the catalog records which installation. In
this repository every such installation is a CI job, called a scenario, and
[the coverage report](docs/agents.md) is generated from what those jobs recorded.

## What counts as an agent

An agent is software that acts on your behalf. That is the whole test, and
[SPEC.md §3](SPEC.md#3-scope-what-counts-as-an-agent) states it. A library an agent is built
with, a gateway it calls through, a model runner, a container runtime or a code-completion
engine is not an agent, even when it is easy to detect. Listing one of those as an agent found
on a machine would claim more than the scan saw.

## Adopting it

The spec is open, and it is meant to be implemented by tools other than the ones here: an
MDM, an EDR, an asset inventory, a script of your own. Its parts are independent, so take the
one you need.

- **To find agents on your machines today**, use the osquery binding: [its
  README](osquery/README.md) has the quickstart, what each release file is for, and how to run
  it across a fleet.
- **To collect evidence with your own tool**, write a binding ([§8](SPEC.md#8-bindings)). It
  emits rows that validate against
  [`schema/evidence.schema.json`](schema/evidence.schema.json), and a scan marker for every
  source it could not read. It declares its fields on each route it feeds, and it proves
  identifiers from its own rows. Any conforming matcher then reads its output.
- **To match in your own tool**, implement [§6](SPEC.md#6-matching) and pass
  [`conformance/vectors.json`](conformance/vectors.json). The vectors are the contract.
  `bin/classify` is one implementation of them, not the definition of conformance.
- **To use only the catalog**, take `catalog.json` from a release. It is a catalog document
  that validates against [`schema/catalog.schema.json`](schema/catalog.schema.json), with each
  identifier's status, package URL and the CI runs that proved it. The YAML files under
  `catalog/` are the source this repository edits; `tools/export.py` renders them into
  `catalog.json`.

If something in the spec stops you adopting it, [open an
issue](https://github.com/arthur-ai/ai-detection-spec/issues): that is a defect in the spec.

## Used by

- [Arthur Platform](https://www.arthur.ai/)
- [Deckard](https://github.com/arthur-ai/arthur-deckard)

## Contributing — genuinely, please do

New AI tools appear weekly and identifiers change underneath you, so **a correction is worth as
much as a new agent.** Found an id that has moved? Know a route we are missing? Either is the
most useful thing anyone can send, and it does not have to be a big change: one line in
`catalog/agents.yaml` plus a test is a complete contribution.

**We ask for one thing: a passing test, not a plausible-looking identifier.** The rule comes
from a mistake we made, not a hoop we invented. We shipped `bot.molt.mac` for OpenClaw once. It
came from the vendor's own Homebrew metadata, it looked entirely right, and it matched nothing
on any Mac. The real id is `ai.openclaw.mac`, and only installing the thing revealed it. The
scenario harness exists so you never have to take an identifier on trust.

[CONTRIBUTING.md](CONTRIBUTING.md) has the details, and `tools/gates.sh` runs every fast check,
so you can see a green result before you open a pull request. **First response within five
working days.**

## License

**Apache-2.0** — use it, fork it, vendor it into your own tooling, ship it inside a product.
See [LICENSE](LICENSE) and [NOTICE](NOTICE). Releases up to and including v0.14.1 were published
under MIT, and copies of those stay MIT.

Maintained by the Arthur Unify team, and built on [osquery](https://osquery.io), which does all
the hard parts.
