# Keeping signatures true as agents change

An identifier is a fact about one build of one product on one machine, and products change
theirs. This repo has been bitten twice:

- **`bot.molt.mac`** shipped for OpenClaw straight from the vendor's own Homebrew metadata and
  matched nothing on any Mac. The real id is `ai.openclaw.mac`.
- **`aider`** installs as `aider-chat` under `uv` and `pipx` while its state directory is
  `~/.aider`, so evidence and signature never met.

Both were silent and neither was caught by review. This is how the catalog is kept true.

## A real install is the bar

A signature is verified when a CI scenario installs the real software and asserts the
classifier finds it. Coverage is counted **per identifier** — an agent can pass while carrying
an identifier nothing exercised — and only from scenarios in the `scenarios.yml` matrix, which
runs on every pull request. `tools/agent_status.py --check` fails the build below complete, so
there is no partial state to manage.

Each run records what it actually matched in `test/scenarios/<name>/observed.json`, beside the
scenario that wrote it, so a run changes one file and a reviewer reads the diff next to its
cause.

## When something cannot be verified, say so

`tools/validate_catalog.py` refuses an agent that is neither covered by a scenario nor carrying
an exception:

```yaml
unverified:
  - identifier: {route: bundle_ids, value: com.example.enterprise-agent}
    reason: requires a paid licence and an interactive sign-in; no unattended install
    evidence: vendor-documentation
    raised: 2026-08-31
```

`evidence` grades what you actually have, weakest first:

| grade | meaning |
|---|---|
| `vendor-documentation` | what produced `bot.molt.mac`. Lowest trust |
| `registry-manifest` | the artifact resolves under that exact name from its registry |
| `artifact-metadata` | the artifact's own config confirms what it is — an image entrypoint, a bundle `Info.plist` |

There is deliberately no `real-install` grade: a real install needs no exception. The validator
also refuses a reason too short to be a reason, a date that is not a date, and a block on an
agent that *is* covered — in which case the block contradicts the scenario and one of them is
stale.

The exception is permitted and **reported on every regeneration** of `docs/agents.md`, so it
cannot quietly become permanent. **A catalog may carry a guess. It may not hide one.**

## The state that does the most work

`did not appear` — a CI scenario installed the agent and the identifier never showed up. It
means one of three things, and they are worth telling apart:

| it means | what to do |
|---|---|
| the scenario installs by another route | install that route, on **another machine** — two routes claiming one binary name cannot share a host |
| the artifact only exists once the agent **runs** | invoke it; a state directory is not created by installing |
| the identifier is wrong | remove it |

Both catalog bugs found so far surfaced through the third case, and neither survived a registry
lookup: npm `mcp` is Mintlify's package, and npm `aider` is a static-site component by an
unrelated maintainer. Each sat beside a comment explaining the discrepancy rather than
questioning it, which is how a guess survives review.

## One route grades stronger than observation

A Chromium extension id is not assigned, it is **derived**: SHA-256 over the developer's DER
public key, first 16 bytes, hex mapped `0-f` to `a-p`. The Web Store's signed CRX carries that
key, so the id can be recomputed from the publisher's own signed artifact rather than observed
on a machine.

An observation says one machine reported an id once; a derivation says the id belongs to that
signing key and could not belong to anyone else's. It also explains exactly why a planted or
unpacked extension reports an **empty** identifier — no key, nothing to derive from.

Most routes offer nothing like it. A bundle id is a string in a plist anyone can write, an
image tag is chosen by whoever ran `docker tag`, and a Homebrew token is a name in a
repository. For those, a real install remains the bar.

## Two things only a real run exposed

**Credits are keyed by (route, value), never by value alone.** OpenClaw ships an npm package
*and* a Homebrew cask both called `openclaw`, so a value-keyed credit let an npm-only scenario
record the Homebrew token as observed — a real install no row supported.

**Coverage counts against CI, not against "has anyone run this".** A scenario passing only on a
maintainer's machine catches nothing on a pull request, and one sat in exactly that state:
passing locally, absent from the matrix, indistinguishable from covered.

## The gap that is still open

**No observation carries an age.** An identifier reads *covered by CI* on the strength of a run
from months ago, and nothing says which. Marker rows carry the scan time in `ver` and
`bin/classify` computes staleness from it, but coverage records do not, so a freshness gate
does not exist yet.
