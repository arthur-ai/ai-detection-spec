# Working in this repo

This repo is **ai-detection-spec**: the spec (`SPEC.md`, `schema/`, `conformance/`), its
reference catalog and matcher (`catalog/`, `bin/classify`), and `osquery/`, the spec's first
**binding**, which collects evidence on an endpoint. The binding's own rules are in
[`osquery/CLAUDE.md`](osquery/CLAUDE.md). Deployment glue for a particular MDM belongs to
whoever wraps these artifacts. **One name**: the repository, the spec, the `format` identifier,
the release assets and the environment variables all say `ai-detection-spec`.

**The spec is open and normative, and may not depend on this repo.** It exists for other tools
to adopt, so this repo's code is one implementation of it. `SPEC.md`, `schema/` and
`conformance/` name no implementation path; `test/test_conformance.py` fails if one does. A
change to what matching means moves four things together: the section of `SPEC.md`, the schema,
the vectors, and both matchers (`bin/classify` and the rendered SQL). When a matcher and a
vector disagree, the vector is right until `SPEC.md` says otherwise. Match modes and scan
outcomes are declared in the schemas; `bin/classify` ships without `schema/`, so it keeps a copy
of the modes, and `test/test_conformance.py` holds the copy equal.

**The catalog and the matcher never read `osquery/`.** `bin/classify`, `catalog/` and their
tools work on evidence rows from any binding. A check that needs both the catalog and the
binding's files belongs to the binding. `test/lint.sh` enforces it.

## The one rule everything else follows

**An empty result must never be indistinguishable from a clean machine.** Nearly every bug this
repo has shipped was a wrong answer that looked like a right one:

- A SIGTERM'd `osqueryi` **exits 0 and prints `[\n\n]`**. **The kill decides, not the child**:
  a bounded query discards its own output.
- A Docker daemon can answer `200` on `/_ping` and never serve `/images/json`. A health check
  is necessary and not sufficient; that state is `wedge` in `osquery/test/lib/fake_docker.py`.
- `$HOME` unguarded under `set -u` crashed the socket probe, which then reported
  `containers=absent` on a Mac with a healthy daemon.
- A `kind` no route in `catalog/routes.yaml` declares is **dropped, not unmatched**, invisible
  even under `--show-unmatched`. `ext` sat like that from the beginning, unnoticed because
  Claude was still found through its native-messaging host.

So every failure carries a reason, in a `kind=scan` marker whose closed vocabulary is
[SPEC.md §5.2](SPEC.md#52-scan-markers). **Declining to look and finding nothing may not share a
word**: a Podman host gets `unreadable:podman`, named from a socket or binary on disk, never
`absent`, and never a probe, because Podman's socket passes the health guard and serves zero
images. **A vocabulary term needs a producer**: `stale:<n>` was documented and accepted by CI
while nothing emitted it, and was removed. A reader computes staleness from a marker's `ver`.

## The catalog

**Identifiers are read off real installs**, never vendor documentation;
[README](README.md#contributing--genuinely-please-do) has the story that set the rule.

**The scope is agents**: [SPEC.md §3](SPEC.md#3-scope-what-counts-as-an-agent) is the test,
and `removed:` in `catalog/agents.yaml` records what failed it, because the temptation to re-add
each is obvious. Overstating what was found is the error this repo exists to avoid.

- **A removed entry keeps its fixture rows**, with the assertion inverted to *must not match*,
  so *correctly not an agent* stays distinguishable from *route quietly broken*.
  `25-python-agents` still installs LiteLLM for that reason.
- **A query branch no agent is found through is payload nobody reads.** The `model` branch went
  with the model runners, whose rows had been dropped all along. If the scope widens, they are
  the strongest candidates to return, with that branch.

**Nothing ships in the catalog without a real install in CI.** `tools/validate_catalog.py`
refuses an agent no scenario installs, and `tools/agent_status.py --gate` fails lint on an
identifier no CI scenario produced. A fixture proves the matcher, never the identifier. There is
no exception register, and `retired:`, `untested:` and `unverified:` fail the build, as does any
unknown agent field. When an identifier stops appearing, the triage and the `superseded:`
workflow are in [`docs/signature-lifecycle.md`](docs/signature-lifecycle.md). Its rules
in brief: a superseded value **stays on its route**, which keeps old machines matching;
`--supersede` stays a deliberate mode, because a week-long outage and a rename look identical;
and the record's provenance is checked against an archived observation, so it cannot be typed.

**A catalog may carry a guess but may not hide one.** Say what cannot be verified in the tree.
The lifecycle page's `NOT BUILT: naming the successor with a model` marks where design begins;
do not write code against what is below it, or widen the claim above it.

The **10s EA timeout** and the **30KB EA value cap** are this project's conventions, not Jamf
limits. Jamf documents neither.

## Architecture

The endpoint **enumerates**: the enumeration queries hold no catalog and do no filtering, so a
new identifier re-matches evidence already collected. `osquery/tools/check_no_catalog.py` fails
the build if an agent identifier leaks into them. Matching happens off the machine in
`bin/classify`, or **on the machine as a peer, not a fallback**: the binding renders the catalog
into SQL, kept in step with `bin/classify` by the rules in `osquery/CLAUDE.md`.

Every row is the **six-column contract**: `kind, id, ver, loc, extra, perms`.

**Telemetry lives on one side of that boundary.** `bin/classify` sends one anonymous event per
run; nothing that runs on the endpoint sends anything, because it runs as root on machines
whose owners did not choose this tool. [`docs/telemetry.md`](docs/telemetry.md) is the field
list, gated against `EVENT_FIELDS`, and `test/test_telemetry.py` asserts nothing from the
payload comes back out.

**The endpoint may not add a dependency**; `osquery/CLAUDE.md` has the closed list.
`bin/classify` is outside it for the same reason telemetry is: off the machine, a missing
interpreter is one operator's problem rather than a fleet's.

**`catalog/routes.yaml` is the route registry, and adding a route there is the whole edit.** The
matcher, validator, coverage report and lint all derive from it; five hand-kept copies of the
list were how `ext` went missing. It carries **no field nothing reads**.

## Testing

`tools/gates.sh` runs every fast gate and exits non-zero on any failure;
[CONTRIBUTING.md](CONTRIBUTING.md#running-the-tests) lists the osquery gates and the scenario
harnesses.

- **Each gate measures the platform it runs on** and skips the other's queries by name, never
  silently: a Linux query measured on macOS once recorded an error as `0.24s, 0 rows`.
- **Assert on what must not match.** `libxdmcp` must not be claimed by the `mcp` identifier.
  Only that shape tells *correctly declined* from *never looked at*.
- **Verify a test by breaking what it covers.** A multi-tag assertion was vacuous for months
  because its fixture had no agent on either tag.
- **Every workflow job declares `timeout-minutes`, at most 60**; `tools/check_workflows.py`
  fails one that does not. The default is 360, and a hung `open -a` billed it in full.
- **Each scenario declares its `platform`**, and `tools/check_workflows.py` asserts a runner
  that can host it, or a misplaced scenario skips forever while looking scheduled.
- **Be slow to conclude something cannot be tested.** A scenario that cannot run `exit 3`s to
  SKIP with the reason in `requires.json`. This repo once concluded the Claude extension needed
  MDM to install; Chrome had simply never been launched, so no profile existed.

## Two shell traps

- **A heredoc inside `$( )` is scanned for the closing paren without respecting its quoted
  delimiter**, so one apostrophe in a comment swallows the `)`. `bash -n` catches it.
- **`python3 - <<'X'` reads the script from stdin**, so a pipe into it is silently discarded.
  Pass data as arguments.

## Register

State the measurement, then the consequence. Where a number is unverified, say so. Comments
carry the reasoning and the rejected alternative, because the *why* stops the bug coming back.

**Be concise, in comments and docs alike.** Keep the rule and the fact that stops the bug; cut
the retelling, the second example, the restatement in capitals, and the history of a tree that
has no users yet. **Each fact has one home**; elsewhere, link to it in a clause. A number in
prose that `tools/check_doc_numbers.py` does not check is a liability: point to where it is
counted.
