<div align="center">

# 🔎 ai-detection-spec

**An open specification for finding the AI agents on a machine. Every identifier in its
catalog comes from installing the real software, and it runs on osquery today.**

[![CI](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/ci.yml/badge.svg)](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/ci.yml)
[![Scenarios](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/scenarios.yml/badge.svg)](https://github.com/arthur-ai/ai-detection-spec/actions/workflows/scenarios.yml)
[![Coverage](https://img.shields.io/badge/identifiers_covered_by_a_CI_test-154%2F167-A26A16)](docs/agents.md)
[![osquery](https://img.shields.io/badge/osquery-5.23.1-1D4E89)](https://osquery.io)
[![macOS](https://img.shields.io/badge/macOS-shipping-2E7D57)](osquery/README.md#requirements)
[![Linux](https://img.shields.io/badge/Linux-shipping-2E7D57)](osquery/README.md#requirements)
[![Windows](https://img.shields.io/badge/Windows-shipping-2E7D57)](osquery/README.md#requirements)
[![License](https://img.shields.io/badge/license-Apache--2.0-6B7480)](LICENSE)

**[What we detect, and the test behind each →](docs/agents.md)**

</div>

## What is here

Three things. Each can be taken on its own.

| | What it is | Who takes it |
|---|---|---|
| **The spec** [`SPEC.md`](SPEC.md), [`schema/`](schema), [`conformance/`](conformance) | The contract between a catalog, a collector and a matcher, [defined below](#what-the-spec-is). [`bin/classify`](bin/classify) is the reference matcher | People building it into an MDM, an EDR or an inventory tool |
| **The catalog** [`catalog/`](catalog) | **61 agents and 167 identifiers**, written to the spec. CI must see each identifier on a real install, in a job called a scenario, and [the coverage page](docs/agents.md) is generated from what those jobs recorded | Anyone who needs the facts |
| **The osquery implementation** [`osquery/`](osquery) | The catalog rendered as queries for macOS, Linux and Windows, and the scripts that run them. The spec calls a collector a *binding*, and this is the first one | Security and IT teams who want to run it on a fleet this week |

## Run it

```console
$ git clone https://github.com/arthur-ai/ai-detection-spec && cd ai-detection-spec
$ brew install --cask osquery          # or https://osquery.io/downloads
$ python3 -m pip install pyyaml        # for bin/classify only; the endpoint needs nothing
$ sudo osquery/bin/discover --deep | bin/classify  # --deep adds the container scan
```

The findings below came off one Mac. The first two lines are what the same run prints when
the Docker daemon accepts the connection and then stalls, a state most inventories report as
*no containers*.

```
COULD NOT LOOK: containers -- whatever answers at /var/run/docker.sock accepted the connection and then stalled; gave up at 6s
  These are not findings and not an absence of them. That part of the machine was not read.

Claude Code  [Coding agent]  running
    file    /Users/dana/.local/bin/claude  2.1.314
    file    /Users/dana/.claude/
    proc    /Users/dana/.local/share/claude/versions/2.1.314  2.1.314

Cursor  [Coding agent]
    app     com.todesktop.230313mzl4w4u92  3.22.7
            /Applications/Cursor.app
```

[The osquery README](osquery/README.md) has Linux and Windows, matching on the machine for a
Jamf Extension Attribute or a Fleet policy, and running it across a fleet.

## Why this exists

Anyone taking stock of the AI tools on a fleet runs into the same surprises. Cursor's bundle
id is `com.todesktop.230313mzl4w4u92`, which you cannot guess from the product's name.
ChatGPT's desktop app renamed its bundle id from `com.openai.chat` to `com.openai.codex`, so a
fleet with old and new builds needs both. A single agent can arrive as a Homebrew cask, an npm
package or a curl installer, and each leaves a different trace.

Inventory tools can read a machine, but they do not know what an agent looks like on it.
Agent standards know what an agent is, but only for agents someone chose to register. This
repository is the in-between: a proven list of what each agent leaves on a machine, a rule for
what counts as an agent, and a way to say *could not look* that is different from *nothing
there*. It does not replace osquery, an MDM or an EDR. It tells them what to look for.

| Existing | Answers | Cannot answer |
|---|---|---|
| osquery, MDM and EDR inventories | What is on the machine | Which of it is an agent, what Cursor's bundle id is, and whether a source it skipped was empty or unread |
| A2A Agent Cards, OASF, the CSA Agent Registry | What a registered agent is | Whether an unregistered one is installed |
| CycloneDX AI-BOM, SPDX AI | What an agent is built from | Whether it is on any machine |

## What the spec is

The spec is the written contract that lets a catalog, a collector and a matcher built by three
different people give the same answer about the same machine. It fixes three things the parties
exchange, and one rule for each.

| What is exchanged | Defined in | The rule attached to it |
|---|---|---|
| A **catalog document**: agents, the routes their identifiers sit on, each identifier's status, and the proof a catalog distributed for others to use must carry for every current identifier | [§4](SPEC.md#4-catalog), [`schema/catalog.schema.json`](schema/catalog.schema.json) | Only agents go in ([§3](SPEC.md#3-scope-what-counts-as-an-agent)), and only identifiers a real install has produced ([§7](SPEC.md#7-provenance)). No two agents may claim the same row |
| **Evidence rows** from a collector, six defined members each and any a binding adds, plus scan markers with a closed vocabulary of outcomes | [§5](SPEC.md#5-evidence), [`schema/evidence.schema.json`](schema/evidence.schema.json) | A source the collector could not read is reported as such. *Could not look* never shares a word with *nothing there* |
| **Findings** from a matcher, with the rows that prove each one, and the markers sorted into scans, absences and gaps | [§6](SPEC.md#6-matching) | Rows are compared by the named match modes in the named order. A row of an unregistered kind is counted, not lost. Findings are never presented as complete while a gap is open |

The match modes, the home roots that let a `~/` value match a Windows profile path, and the
evaluation order are what make *the same answer* literal, and
[`conformance/vectors.json`](conformance/vectors.json) pins them: two matchers agree on every
vector, or one of them does not conform.

**So an empty result is never ambiguous.** No findings can mean a clean machine or a scan that
could not look everywhere, and the output says which.

The spec is not the catalog, osquery or `bin/classify`. Those are one document written to it,
one collector bound to it and one matcher that passes its vectors. It names no implementation
path, and `test/test_conformance.py` fails if one appears.

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
  [`conformance/vectors.json`](conformance/vectors.json).
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
See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Maintained by the Arthur Unify team. The first binding is built on
[osquery](https://osquery.io), which does the collecting.
