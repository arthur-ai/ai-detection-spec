# Signature drift: keeping an identifier the software has moved past

An identifier is a fact about one build of one product. When a vendor changes it, the fact
does not become false — it stops being **current**. Machines on the old build still report
the old identifier, and they are exactly the machines an inventory most wants to name.

So the old identifier must keep matching. What has to change is the *claim the tree makes
about it*. Every failure below is a variation on deleting a true signature because the
tooling could no longer prove it was current.

`docs/signature-lifecycle.md` covers whether a signature is true at all — the real-install
bar and how coverage is counted. This document covers what happens after it was true and the
software moved on.

## The rule

**A signature is admitted only if a CI scenario has proved it by a real install — now, or in
the past. There is no third way in.**

| state | what it means | how it is tested |
|---|---|---|
| **current** | the release CI installs today produces this identifier | a scenario, on every pull request |
| **superseded** | a scenario proved it, and the release CI installs today no longer produces it | the matcher test, on every pull request: the value still resolves to its agent |

A superseded signature leaves continuous testing and **stays in the matcher**. Nothing else
is admitted: a value no run has ever produced is not a signature, it is a guess with a
comment beside it, and the two are indistinguishable until something tries to install it.

That rule has a cost and it is the right cost. It is stated in full under
[What the rule refuses](#what-the-rule-refuses).

> **The rule is a decision, not yet a mechanism.** Today the tree enforces the first state and
> not the second: `retired:` is the unfinished version of `superseded:`, and it is accepted on
> assertion rather than evidence. **Part one describes what the tree does today, part two the
> workflow either way, and part three what is not built.** Read the part-three marker before
> writing code against anything in it — a vocabulary term with no producer is the `stale:<n>`
> mistake, and this document is arranged so it cannot become one.

## Why `superseded`, and not `retired` or `archived`

The word is load-bearing, because the one thing a reader must not conclude is that these
signatures stop being matched. Industry vocabulary splits along a useful line:

| precedent | word | what it means there |
|---|---|---|
| CPE dictionary | `deprecated`, with a pointer to the replacement | an identifier for a renamed platform, kept because old scan data references it |
| MITRE ATT&CK | `deprecated`, and `revoked` where a specific successor exists | revoked carries the successor; deprecated does not |
| Sigma | `status: deprecated` / `unsupported` | plus a directory that deprecated rules move into |
| npm, PyPI | `deprecated` | still resolvable, still installable, marked |
| RFC, IANA | `Historic` | superseded, kept for the record |
| HTTP | `Deprecation`, then `Sunset` | advice, then an end date |

The common word is **deprecated**; where the point is that a specific newer thing took over,
it is **revoked** or **superseded**. This catalog is the second case, and three things decide
it:

1. **It names what was measured.** `retired` and `archived` describe what *we* did.
   `superseded` describes what the *vendor* did — a newer identifier took over. That is the
   fact the record holds.
2. **It is silent about matching.** `archived` means "moved out of the active set" nearly
   everywhere, and `retired` reads as "no longer in service". Both invite the one misreading
   that would break the fleet. A superseded identifier is matched on every host, forever.
3. **`retired` is already taken, for the near-opposite meaning.** See below.

`deprecated` is the more recognisable word and was rejected for one reason: it carries *do
not use this*, and here you very much should keep using it.

**`archived` survives, for the other half of the pair.** A *signature* is superseded — it
stays in the matcher and nothing about it moves out of the active set. Its *observation* is
archived, because that genuinely does leave live coverage: the run stops reproducing it and
the record is set aside as history. Two words for two things, which is why part three uses
`superseded:` in the catalog and `archived` in `observed.json`.

## `retired` means two opposite things today

The word appears in both catalogs with nearly inverted meanings. This is the trap most likely
to cost someone an afternoon, and it is why the new field does not reuse the name:

| where | what it means | effect on matching |
|---|---|---|
| `catalog/routes.yaml`, on a **route** | the route no longer identifies anything. `ports` is the only one | the route **cannot claim** a row unless the process holding it already names the agent |
| `catalog/agents.yaml`, on an **agent** | these values are identifiers from an earlier release, kept for machines that still carry them | none. They match exactly like current values |

`bin/classify` reads the first (`registry.retired`, applied in the match loop) and **does not
read the second at all**. A reader who sees `registry.retired` in the matcher and concludes
that old identifiers get special handling has it backwards: the route flag *withholds* a
match, and the agent field does not reach the matcher.

# Part one: how the tree behaves today

## Several generations, all live at once

Nothing special happens for an older generation. It is an ordinary catalog value, indexed and
matched exactly like the current one. Three layers carry the version spread, each doing a
different job:

| layer | how it holds several generations | read it in |
|---|---|---|
| **catalog** | every generation is a normal value on its route. `retired:` labels the ones from an earlier release | `catalog/agents.yaml` |
| **assertion** | a `must_contain` entry may be a **list**, meaning *any of these satisfies the probe* — so a scenario passes on whichever generation the runner installs | `test/lib/assert.sh` |
| **coverage** | credit is keyed `(route, value)` and recorded per `(platform, os, arch)` with the `agent_version` that produced it, so two runners producing two generations both get recorded | `tools/agent_status.py` |

OpenClaw is the widest case in the tree: `moltbot` → `clawdbot` → `openclaw` on npm, and
`bot.molt.mac` → `ai.openclaw.mac` as a bundle id. All of them are in the index at the same
time; a machine reports whichever it has.

The alternation in `must_contain` was not a design, it was a **measurement**. One run
installed the same `chatgpt` cask on two runner images and got two builds — a current one
reporting `com.openai.codex`, and one whose Homebrew metadata was stale enough to still
resolve the pre-rename release, reporting `com.openai.chat`. A single-value probe would have
gone red on one runner and named the wrong cause.

**What the coexistence costs.** On the exact-match routes, an extra generation is one more
dict entry and no extra comparison. On the prefix and path routes it is one more comparison
per candidate row — `bot.molt.` is a `launchd_prefixes` value, so it is compared against
every daemon row on every host. That is the ceiling worth watching if a lineage grows long,
and it is a property of the route, not of the value being old.

## Does the classifier check the old identifiers?

**Yes — they are matched, and no, the output does not say so.**

- `build_index` indexes every value on every route, and an agent's `retired:` list is not
  consulted, so an older generation is matched on exactly the same terms as the current one.
- Because the list is not consulted, a finding on `com.openai.chat` and a finding on
  `com.openai.codex` render identically. The reader cannot tell *this Mac runs a current
  build* from *this Mac has a build old enough that its identifier changed* — which is the one
  fleet fact a match on an older generation uniquely carries.

**The invariant, and it governs everything in part three:** superseding a signature means *no
longer proved by a live CI install*. It must never mean *no longer matched*. A superseded set
the matcher does not consult would stop detecting precisely the machines it exists for, and it
would do it silently — an empty result indistinguishable from a clean machine, which is the
one error this repo exists to avoid. Whatever marks an identifier as historic must be a
**label on the finding, never a filter on it**.

## What tells you a signature has drifted

Three things fire, at different moments, and they see different halves of the problem. All
three run on every pull request.

| trigger | when it fires | where |
|---|---|---|
| **the shrink guard** | a scenario run proves *fewer* identifiers than the committed record. Refuses to record and names each loss, the key it compared on, and the keys the file holds | `tools/agent_status.py`, in `record()` |
| **`tested-absent`** | a CI scenario asserts this agent and this identifier never showed up. `--check` fails the build | `tools/agent_status.py`, in `collect()` |
| **an assertion** | `must_contain` names the value and the row is gone. Fires *before* recording, so the job goes red without reaching the guard above | `test/lib/assert.sh` |

The order matters when reading a red suite: an assertion failure means the value was named
explicitly by a scenario, and the shrink guard means it was only being counted. A value under
an alternation list fires neither until the *last* alternative goes.

## Where today's tree falls short

Three gaps, and part three closes all three:

- **`retired:` is an assertion that excuses itself.** It exempts a value from the coverage
  gate, and nothing checks that the value was ever real. Of OpenClaw's four retired
  identifiers, the two npm names are backed by a real CI install and the two from the old
  `.app` are backed by nothing — no fixture, no scenario, no observation. They are the
  excluded aliases the gate reports, and they are the last hand-typed exemption in a repo
  whose rule is that nothing ships without a real test.
- **The only automated exit from a lost identifier discards the evidence.** `--allow-shrink`
  **replaces** the record for that `(platform, os, arch)` key, so the observation that proved
  the identifier is dropped in the same step that keeps the identifier.
- **An observation carries no run identity.** It holds the agent version, platform, OS and
  arch, and nothing that distinguishes a CI runner from a maintainer's Mac. That single
  missing field is why proof cannot survive the scenario that produced it.

# Part two: the workflow

## Triage: why did it stop appearing

`docs/signature-lifecycle.md` lists three causes and `CLAUDE.md` adds a fourth. Drift is the
fifth, and it is the one whose correct action is the opposite of the others':

| it means | how you tell | what to do |
|---|---|---|
| the scenario installs by another route | another route's value appeared in the same run | install that route — on **another machine**, because two routes claiming one binary name cannot share a host |
| the artifact only exists once the agent **runs** | it is a `state_dirs` value and the scenario only installed | invoke the agent. A state directory is not created by installing |
| the identifier is **wrong** | **it has never appeared in any committed observation**, and a registry lookup names something else | remove it. Both catalog bugs found so far were this |
| the route cannot identify at all | it only ever matched when something else had already named the agent | remove the route. `ports` went for this |
| **the identifier is right and is no longer installable** | **it appeared in a committed observation before, and does not now** | supersede it. The value stays; continuous testing stops |

The discriminator between the third row and the last is one command, and it is the whole
triage:

```console
$ grep -rl '"value": "com.openai.chat"' test/scenarios/*/observed.json
test/scenarios/10-desktop-apps/observed.json

$ grep -rl '"value": "bot.molt.mac"' test/scenarios/*/observed.json
```

A value some run once produced is a fact with provenance behind it. A value nothing has ever
produced is a guess — that is the shape both catalog bugs made, and each sat beside a comment
explaining the discrepancy rather than questioning it.

## Proving an old identifier

This section carries more weight under the rule than it did before, because there is no
register to put an unproved value in. If you want a signature, you prove it.

Do not conclude that an older generation is untestable. That conclusion was reached once, in
writing, and was wrong: OpenClaw's retired npm names were recorded as coverable only by a
fixture on the reasoning that nothing installs them any more, and both packages turned out to
be still published. `56-openclaw-retired-names` installs them for real.

Two things that scenario had to get right, and both generalise:

- **The old generation usually cannot share a host with the current one.** All three OpenClaw
  packages provide the same global binary, so npm would have them fight over it and one would
  mask another. Testing a lineage means one scenario per generation, not one scenario
  installing the lineage.
- **It installs deliberately outdated software**, which is safe only because the guest is
  disposable, unenrolled and holds no credentials. That warning belongs in the setup script,
  where someone reads it before running it — not in `expected.json`, where it is rendered into
  a coverage report nobody consults first.

## What the version field can and cannot say

A superseded record keeps the version that last produced the identifier. It is the most useful
field in the record and it is a **sighting, not a bound.** The temptation is to read it as
*version X or below*, and the counterexample is in this catalog:

- `com.openai.chat` was last proved at `1.2026.160`. Current builds number from `26.` — the
  exact figure moves with every release, and `test/scenarios/10-desktop-apps/observed.json`
  holds whichever one CI last saw. **The version scheme changed at the same rename that
  superseded the identifier**: the app and Codex converged and the numbering went with them.
  So `1.2026.160 or below` cannot be ordered against a current version at all; any comparison
  across that boundary compares two numbering systems.
- Even within one scheme, the interval was never sampled. We saw the identifier present at one
  build and absent at another. The true ceiling is somewhere between, and no run has looked
  there. Recording the sighting as a ceiling rounds an observation into a fact.

So the field is named for what it is, `last_seen`, and the rule that follows from it:

> **Say it in prose; never compute on it.** The report may render *last seen at 1.2026.160, so
> a machine reporting this is on that era or older*. Nothing may filter findings by it — a
> consumer gating on `<= X` would silently drop a machine whose scheme differs or whose build
> sits in the unsampled gap, and a filter on findings is the one thing this design cannot have.

# Part three: not built — the design

**Nothing in the tree produces or reads any of what follows.** It is recorded here as a
design, not as a contract. A vocabulary term with no producer is the `stale:<n>` mistake —
documented in three places and emitted by nobody — and this part is marked so it cannot
quietly become one. If it ships, this heading changes and the rest of this document is what
gates it.

## The record

`superseded:` replaces `retired:` on the agent, as records rather than bare strings. Today's
field says only *this value is old*, which is a claim nothing can check. The record says what
was measured:

```yaml
superseded:
  - {route: bundle_ids, value: com.openai.chat,
     last_seen: 1.2026.160, by: 10-desktop-apps, run: 33511815638}
```

Same structure, same place in the file, one concept instead of two. `run` is the workflow run
that last produced the identifier, and the report renders that run's date beside it, so a
reader gets an age without the catalog storing one.

`run` is the one field an observation does not carry today, and adding it pays twice: it is
also what distinguishes a CI runner from a maintainer's Mac, which is the missing
discrimination named in part one.

**Where the evidence lives afterwards, because the transition is the step that would destroy
it.** The shrink guard fires precisely when a run stops producing the identifier, and the
record step then replaces that platform's observations — so a design that only wrote the
catalog entry would point `by` and `run` at an observation it had just deleted, and the
"checkable" record would be unverifiable one commit later. So the observation is **moved, not
dropped**: `observed.json` grows an `archived` list beside `identifiers`, holding the lost
record unchanged.

That gives each file one job, and the two check each other:

| file | holds | answers |
|---|---|---|
| `catalog/agents.yaml` | `superseded:` — the signature's status | what the matcher should match and how a finding is labelled |
| `test/scenarios/<name>/observed.json` | `archived` — the observation, moved | what a run actually saw, beside the scenario that saw it |

That split is the repo's existing shape rather than a new one: the catalog claims, the tests
verify, and evidence stays next to the scenario that produced it so a reviewer reads the diff
beside its cause. It is also what lets `validate_catalog.py` check a superseded record by
reading a file, rather than by trusting whoever typed it or by digging through git history.

## The value stays on its route

`bundle_ids` keeps `com.openai.chat`; `superseded:` annotates it. This is not tidiness.
`build_index` builds the matcher's index from the route lists, so leaving the value there is
what keeps it matching with **no matcher change at all**. Moving superseded values into a
block of their own would make that block a sixth list which has to agree with the other five,
and the one failure this repo has paid most for is a value present in the catalog, correct,
and never indexed.

## What each file does with it

| file | change |
|---|---|
| `bin/classify` | reads `superseded:` **only to label**. Matching is unchanged by construction. An evidence row carries a flag; a finding whose *every* match is superseded says so in one line, because "this machine is on a build old enough that its identifier changed" is the actionable fact and it is invisible today |
| `test/test_matcher.py` | generates one assertion per superseded value: it still resolves to its agent. This is the live test of a superseded signature |
| `tools/agent_status.py` | one coverage state replacing `alias`, out of both halves of the badge — no live test can cover it, so the numerator would claim a test that does not exist and the denominator would cap the figure for a reason nobody can act on. Named and counted in the report |
| `tools/validate_catalog.py` | keeps today's check that the value is one of the agent's identifiers, which is what guards the section above. Adds: `last_seen`, `by` and `run` must match an archived observation, field for field — a record whose evidence is not in the tree is a guess wearing provenance-shaped fields |

If the labelling in `bin/classify` were ever dropped, the result is silence about generation,
not lost detection. That is the right way round, and it is the reason labelling is the only
thing the matcher gains.

**The matcher test is the honest test for a historic signature.** It cannot prove the
identifier is current — nothing can, it is historic — and it does prove the classifier still
finds it, which is the whole of what a superseded record owes the fleet. It is already the
practice for both of today's aliases, hand-written, and `com.openai.chat`'s comment there
reasons its way to exactly this rule for one value: *a real install found it exactly once,
that is not repeatable, so the fixture row is the standing proof.* Generating the assertion
from the block makes that total instead of remembered.

## What is deleted

The rule admits two states, both earned by a real install, so every mechanism that existed to
admit a third is removed:

| removed | what it was for |
|---|---|
| `untested:` | a dated reason excusing an identifier no CI test covers |
| `unverified:` | an agent-level exception when no scenario installs the agent at all |
| the `evidence` grades — `vendor-documentation`, `registry-manifest`, `artifact-metadata` | ranking evidence that is *not* a real install |
| the `alias` coverage state | exempting a `retired:` value from the gate. Absorbed by the superseded state |
| `grade()`'s exception branch, and the exception register in `docs/agents.md` | reporting the above |

**Nothing migrates: both registers are absent from the catalog.** Not empty — absent.
`validate_catalog` reports no recorded exceptions and the gate reports no excused identifiers.
The escape hatches were built and never used, and the rule is what the tree has been living by
in practice.

`validate_catalog.py` gets simpler rather than looser: its refusal of an agent with no
scenario stops being conditional on an `unverified` block and becomes unconditional.

## The entry condition

**A signature is superseded when the evidence stops being reproducible — the shrink guard
fires — and never because a passing test became inconvenient.**

This is the line to hold, and it is not academic. `clawdbot` and `moltbot` are proved by a real
install on every pull request today. Choosing to supersede them would trade the strongest
evidence in the tree for a dated record, on the same assumption — *nothing installs them any
more* — that was written down here once and turned out to be false. Superseded must mean
**cannot be proved**, not **is not being proved**; the moment it means the second, it is
`untested:` with better manners.

Two consequences fall out of that condition, and both are deliberate:

- **A scenario leaving the CI matrix is a coverage regression, not a supersession.** Supersession
  requires that the vendor moved on, which is a fact about the software, not a scheduling
  decision. So dropping a scenario while its agent is still current leaves its identifiers in
  the state that means *observed, but never by CI*, and the build stays red. The gap named in
  part one is closed by ruling the case out rather than by accommodating it.
- **An identifier that never appeared stays red.** It cannot be superseded, because
  supersession requires a prior observation. That is the same discriminator as the triage
  table: appeared-then-stopped versus never-appeared.

## What the rule refuses

`bot.molt.mac` and `bot.molt.` were never proved by CI, so they do not qualify as superseded
either — the rule requires having been tested. Under it, they must be **proved or removed**,
and removing them plausibly blinds us to a Moltbot-era Mac that carries neither the new bundle
id nor `~/.openclaw`.

The rule is still right, because it converts that from a paperwork problem into a testing
problem. The tree records that whether an old build is still downloadable is UNVERIFIED —
meaning **nobody has checked**. And this repo has already been wrong once about precisely these
values: `56-openclaw-retired-names` exists because *nothing installs them any more* was false
for the npm names. So the action the rule forces is to go looking for a Moltbot-era artifact,
prove the two values if one is fetchable, and supersede them properly. That is strictly better
than a register that let them sit unproved indefinitely.

If someone looks and no artifact is obtainable, *then* they come out, and the loss is recorded
in `docs/blind-spots.yaml` — but only then. That file holds what no amount of test coverage can
move, and "nobody has tried to fetch the old build" is not that. Writing the entry before the
search would file a coverage gap as a platform property, which is how a gap stops being worked
on.

# How much of this is automated

**Today: measurement and enforcement are automated end to end; every decision and every
catalog edit is manual.** The design automates one more step — the transition — and
deliberately leaves the judgement manual.

| automated today | where |
|---|---|
| recording what each scenario run matched, per identifier, with the agent version, platform, OS and arch that produced it | `--record`, in every scenario job |
| merging one scenario's observations across every runner in a run | the `collect` job, main-only |
| regenerating `docs/agents.md` and the README badge, committing when coverage moved | `--write`, plus `docs.yml` as a safety net for direct pushes |
| computing per-identifier and per-platform coverage against the CI matrix — not against "has anyone run this" | `tools/agent_status.py` |
| refusing a run that proves less than the committed record, and naming every loss | the shrink guard |
| failing the build on an identifier no CI test covers | `--gate` and `--check`, both in `test/lint.sh` |
| rejecting a `retired:` value that is not one of that agent's identifiers | `tools/validate_catalog.py` |
| failing prose whose numbers no longer match the tree | `tools/check_doc_numbers.py` |

| the design adds | why there and not elsewhere |
|---|---|
| moving the lost observation into `observed.json`'s `archived` list instead of replacing it | the shrink guard is the one place that already knows an identifier was proved and is not being reproduced, and this is the step that would otherwise destroy the evidence |
| writing the superseded record — route, value, `last_seen`, `by`, `run` — from that observation | every field is knowable at that moment and none has to be typed, which is the whole difference between this and `retired:` |
| asserting every superseded value still resolves | generated from the block, so the assertion cannot be forgotten for a value added later |
| refusing a superseded record whose `by`/`run` matches no committed observation | otherwise the record is a guess with provenance-shaped fields, which is worse than a guess |

| stays manual | why |
|---|---|
| triaging **why** an identifier stopped appearing | five causes, five different actions, and only two are separable from the record alone |
| confirming supersession rather than accepting the first red run | a vendor pulling a download for a week and a rename look identical for that week |
| widening an assertion to an alternation list | which generations a runner may produce is read off runs, not predicted |
| deciding a signature cannot be proved at all | the rule makes this the one decision that removes a signature, so it should cost a person |
