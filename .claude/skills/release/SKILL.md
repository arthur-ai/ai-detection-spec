---
name: release
description: Cut a release of ai-detection-spec — pick the version, verify the tree is green and osquery/dist/ is in sync, write notes from commit bodies, and open a draft GitHub Release, whose artifacts release.yml attaches on publish. Use when asked to cut, tag, or publish a release, or to draft release notes.
---

# Cutting a release

No `CHANGELOG.md`. The [Releases page](https://github.com/arthur-ai/ai-detection-spec/releases)
is the record, and each release carries the artifacts a fleet deploys. Write it for someone
deciding whether to take the upgrade.

## 1. Pick the version

The rules are in `CONTRIBUTING.md` under **Versioning**. Read the diff, not the commit subjects.
A changed catalog *value* is a patch; a changed *key* is major. **On `0.x` the major rule
over-fires**: pre-1.0 a break conventionally rides the minor. Say which convention you followed,
and lead with the breaks either way.

**Check removals too** — none of these appears in a diff of the six-column contract:

| removal | what breaks |
|---|---|
| an **entry** leaves | its findings stop appearing, and nothing errors |
| a **classification** empties | a consumer mapping it to a UI loses a value |
| a **route key** falls out of use | `validate_catalog.py` still accepts it with no entry carrying it, so the route never fires. `model_stores` is in that state; `ports` is `retired: true`, which is the visible case |
| a **row kind** stops being emitted | a consumer reading that kind gets no rows, and nothing errors |
| an identifier is **superseded** | it stays matched but leaves continuous testing, so the identifier count falls with nothing removed. Say which value, and that machines on the old build still report it |
| a **flag, mode or environment variable** leaves a shipped script | nothing in `osquery/dist/` or `catalog/` moves, so every check above says patch. It is not: a script in `bin/` is an interface, and someone has the old invocation in a LaunchDaemon. Say which invocation to replace, and confirm the flag is refused by name rather than falling through to "unknown argument". A variable cannot be refused, only no longer read, so a renamed opt-out turns back on what it turned off |

```console
$ python3 - <<'EOF'
import subprocess, yaml
o = yaml.safe_load(subprocess.run(["git","show","<prev-tag>:catalog/agents.yaml"],
                                  capture_output=True, text=True).stdout)["agents"]
n = yaml.safe_load(open("catalog/agents.yaml"))["agents"]
f = lambda a, g: sorted(set().union(*(g(e) for e in a)))
print("entries   ", len(o), "->", len(n))
for label, g in (("ids", lambda e: {e["id"]}), ("keys", set),
                 ("classes", lambda e: {e.get("classification")})):
    print(f"{label:10}", sorted(set(f(o,g)) - set(f(n,g))), "gone")
EOF
$ art() {  # discovery-$2.sql at $1, comments stripped, one UNION ALL branch per line
    local sql
    sql=$(git show "$1:osquery/dist/discovery-$2.sql" 2>/dev/null \
          || git show "$1:dist/discovery-$2.sql") || return 1
    python3 -c 'import importlib.util as u, sys
s = u.spec_from_file_location("osquery_build", sys.argv[1]); b = u.module_from_spec(s)
s.loader.exec_module(b)
flat = b.flatten(sys.argv[2]) or sys.exit("art: nothing left after flatten")
print(flat.replace(" UNION ALL ", "\nUNION ALL "))' \
      "$(git rev-parse --show-toplevel)/osquery/tools/build.py" "$sql"; }
$ kinds() { printf '%s\n' "$1" | grep -oE "SELECT '[a-z]+'" | sort -u; }
$ for p in darwin linux windows deep; do
    o=$(art <prev-tag> $p) && n=$(art HEAD $p) && [ -n "$(kinds "$o")" ] && [ -n "$(kinds "$n")" ] \
      || { echo "$p: NOT COMPARED, see the error above"; continue; }
    diff <(kinds "$o") <(kinds "$n") && echo "$p: same kinds"
    diff <(printf '%s\n' "$o") <(printf '%s\n' "$n") && echo "$p: same SQL, comments aside"
  done
$ envs() { git grep -hoE '\$\{[A-Z][A-Z0-9_]*:?[-+=?]|(environ\.get\(|environ\[|getenv\(|_env_off\()"[A-Z][A-Z0-9_]*"' \
             "$1" -- :/bin :/osquery/bin | grep -oE '[A-Z][A-Z0-9_]*' | sort -u; }
$ if o=$(envs <prev-tag>) && n=$(envs HEAD) && [ -n "$o" ] && [ -n "$n" ]; then
    diff <(printf '%s\n' "$o") <(printf '%s\n' "$n") && echo "same environment variables"
  else echo "envs: NOT COMPARED, see the error above"; fi
```

**Diff all four artifacts**: three are per platform and name disjoint tables, and `deep` alone
carries the container kinds, so diffing one hides the others. An artifact new since
`<prev-tag>` prints `NOT COMPARED` under git's `does not exist`, the one expected case: read it
whole with `art HEAD <platform>`. `art` strips comments with
`build.py`'s own `flatten`, which is quote-aware, so neither a comment nor a reindent reads as
a change, and prints one line per `UNION ALL` branch. **Read every branch the SQL diff
prints**: a column can change meaning with every kind and key intact, as when a token moved
from `perms` to `extra`, and that is the six-column contract breaking.

**Each side is read before it is compared.** A read that fails inside `<( )` leaves both sides
empty and `diff` says *same*: run from `osquery/`, the old `art` imported another package
called `build` and reported every artifact unchanged. So a failed read, an empty side or no
kinds prints `NOT COMPARED`, `flatten` is loaded by path, and every path resolves from the
repository root.

`envs` is complete because both scripts run under `set -u`: an environment read must be a
guarded expansion, and it takes every guard form. `SUDO_USER` is read only as `:+`, which a
`:-`-only pattern missed. It also lists a few of the scripts' own guarded variables, which
cancel in a diff.

`agents.yaml`'s `version:` is the authoring form's, not the release's, and `bin/classify`
refuses any other, so a move is a break: a classifier from one release will not read the
other's catalog. Diff the keys for the rest.

**Check the spec separately.** It has its own version (`SPEC.md`'s header and a catalog
document's `format`), which moves only when the normative text does:

```console
$ git diff --stat <prev-tag>..HEAD -- :/SPEC.md :/schema :/conformance
```

A change there that alters an existing result, or removes or renames a member, is a breaking
spec change (SPEC.md §10), and a breaking change for every implementer, not only this repo's
users. While the spec is `0.x`, §10 also has a consumer reject any minor it does not support,
so every move of `format` breaks a matcher already deployed.

## 2. Verify before you tag

`release.yml` re-runs the static gates on publish, but learning that from a failed workflow means
a published release with no artifacts on it.

```console
$ git switch main && git pull
$ tools/gates.sh                      # every fast gate, non-zero when one fails
$ python3 tools/export.py --strict > /dev/null   # release.yml runs this; an unproved identifier fails it
$ python3 osquery/tools/measure.py --check    # cost bands; needs osquery locally
$ sudo python3 osquery/tools/check_pack.py    # every pack query actually returns rows
$ sudo osquery/test/docker_states.sh          # every Docker state, guard, bound, catalog
```

**Call `gates.sh` rather than re-listing the gates**: it is the one maintained list, and it exits
non-zero. Three of its failures reach the notes directly:

| gate | what it means |
|---|---|
| `check_doc_numbers.py` | a number in prose is no longer true. The notes are prose full of numbers |
| `check_workflows.py` | a workflow references a deleted file, or a scenario is in no job |
| `agent_status.py --check` | `docs/agents.md` is stale, and that is where the notes' coverage figures come from |

The last three commands need osquery or sudo, so they sit outside it. Run them: several things
ship and they are not the same query (`osquery/CLAUDE.md` has the table).

Without `pwsh`, `test/lint.sh` skips the PowerShell parse and says so. `ci.yml`'s Lint job
requires it, so read that job at the commit you tag.

### One machine verifies one platform

`measure.py`, `check_pack.py` and `docker_states.sh` each resolve the platform and skip the
other's queries by name. They say which half they ran — read that line:

```console
pack: ok, 10 of 15 queries run on darwin
```

For the other platforms, CI is the one that counts: `ci.yml`'s Runtime jobs run the cost bands
and `check_pack.py` on each platform, and `docker_states.sh` on macOS and Linux, since osquery
has no Docker tables on Windows.

```console
$ gh run list --workflow=ci.yml --branch=main --commit <verified-sha> --json databaseId \
    --jq '.[].databaseId'
$ gh run view <id> --json jobs --jq '.jobs[] | "\(.name) \(.conclusion)"'
$ test/run-linux.sh                                          # locally, needs Docker
```

Read the run at the commit the suite ran on, not the newest: a later `.md`-only push gets its
own run. Each `Runtime on <platform>` job must read `success`. The scope job skips them for a
diff it judges documentation, and the run still concludes `success`.

Windows has no local harness: its scenarios run only in `scenarios.yml`, one
`<scenario> on windows-2025` job each.

`run-linux.sh` skips a scenario the container, image or host arch cannot host, prints the
reason and exits 3 — a SKIP for the half you care about has verified nothing about it. CI's
container job is the same script, one `Linux scenarios on <image>` job per image, so a green
check per image can hold a SKIP: the job's step summary has a `PASS`, `SKIP` or `FAIL` line per
scenario. `76` and `79` skip on every image and run for real on the Ubuntu job.

### Confirm the suite ran for the exact commit you are tagging

Check the commit, not the branch: a `pull_request` run reports against the PR's merge commit and
a `push` run against `main`.

```console
$ sha=$(git rev-parse HEAD)
$ gh run list --workflow=scenarios.yml --branch=main --commit "$sha" \
    --json event,status,conclusion,databaseId \
    --jq '.[] | "\(.databaseId) \(.event) \(.status)/\(.conclusion)"'
```

Nothing printed means the suite has not run for that commit — wait, do not read the previous one.
A **queued** run has no jobs yet, which is not the same as nothing failing.

**A `push` run is not always the suite.** It runs the scenarios its merge could move
(`tools/ci_scope.py`), and every scenario only when the scoper falls back. Its scope job's
summary says which: every job reading `runs N of N` is the suite. A `schedule` run always runs
every scenario, and so does a `workflow_dispatch` with its `scenarios` input empty; given names,
a dispatch runs only those, and its summary opens with `dispatched with names:`.

**Expect to dispatch.** The schedule is weekly (Mondays 06:00 UTC) and pushes are scoped, so a
release commit usually has no full run. Start one with no input, once, at the commit you will
tag, after the last merge: `gh workflow run scenarios.yml --ref main`. Its `collect` lands on
top, and the next paragraph is how to tag past that.

**The `collect` commit can never have a run of its own.** A push made with the default
`GITHUB_TOKEN` triggers no further runs, and `collect` pushes with it — a run appearing against
one of those SHAs is the weekly or a dispatch that merely started there. Check the `event` field,
and for a `workflow_dispatch` its scope summary:

```console
$ gh run list --workflow=scenarios.yml --branch=main --limit=6 \
    --json headSha,event,conclusion,databaseId \
    --jq '.[] | "\(.databaseId) \(.headSha[0:7]) \(.event) \(.conclusion)"'
```

Waiting for a run at the `collect` commit deadlocks. What resolves it is that `collect` commits
**generated files only** — verify that, then tag on the strength of the run at the commit
beneath it:

```console
$ git diff --name-only <verified-sha> HEAD | grep -v 'observed.json\|docs/agents.md\|README.md'
$ badge() { git show "$1:README.md" | sed -E \
    's/identifiers_covered_by_a_CI_test-[0-9]+%2F[0-9]+-[0-9A-Fa-f]{6}/identifiers_covered_by_a_CI_test-N%2FN-C/'; }
$ diff <(badge <verified-sha>) <(badge HEAD)
```

`collect` rewrites README's coverage badge and README is also hand-edited, so the second line
blanks exactly the fields `collect` writes (the `BADGE` pattern in `tools/agent_status.py`)
before diffing. Both empty means the code, queries and catalog are byte-identical to what the
suite ran on. Anything printed means this is not just a `collect` commit.

### Confirm the observations landed

`collect` checks coverage on every run and **commits only on `main`**: each scenario's
`observed.json`, README's coverage badge and the regenerated `docs/agents.md`, which is where
every coverage figure in the notes comes from, so immediately after merging that page is a merge
behind.

```console
$ git log --oneline -3 origin/main    # expect a "record identifier coverage" commit after your merge
$ gh run list --workflow=scenarios.yml --branch=main --limit=1 --json databaseId,status,conclusion
$ tools/gates.sh                      # agent_status --check fails on a stale page
```

`gates.sh` catches a stale page but not a *pending* one: a tree matching its own uncommitted
observations is internally consistent and still a merge behind. Pull again after collect lands.

`collect` re-merges onto current main and retries its push three times, so one
`! [rejected] main -> main` in its log is not a failure; three in a row are. If a run is red,
find the job, then the scenario:

```console
$ gh run view <id> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | "\(.databaseId) \(.name)"'
$ gh api repos/<owner>/<repo>/check-runs/<job id>/annotations --jq '.[].title'
```

A macOS or Ubuntu job is named for its scenario. A `Linux scenarios on <image>` job is named for
its image, and the second line reads the `<scenario> on <image>` annotation the harness writes,
which is also in the job's step summary. To rerun one scenario rather than the image's whole
list, dispatch with its name in the `scenarios` input.

## 3. Write the notes

**Source them from commit bodies, not PR titles** — the reasoning, measurements and rejected
alternatives are in the body, and `--generate-notes` gives you neither.

```console
$ git log <prev-tag>..HEAD --format='%H%n%B%n---'
```

State the change, then its consequence for someone running this on a fleet. Cover what applies:

- **Breaking changes first**, with the migration. A renamed file, flag or environment variable
  is one, and a renamed opt-out is the worst kind: the old setting stops working in silence.
- **The spec**, if `SPEC.md`, `schema/` or `conformance/` changed: whether the version moved,
  and what an implementer of a catalog, binding or matcher must change.
- **What consumers deploy** — whether the six-column contract or the row kinds moved, and which
  artifact a new query landed in. An `expensive` one is pack-only and never reaches the composed file.
- **What the deployer must do** that the repo cannot. The standing case: `osquery/bin/container-scan` is
  the supported way to run the deep artifact, on its own schedule, scoped to machines with
  Docker, never inlined on a synchronous reporting path. Its non-zero outcomes are a `kind=scan`
  marker row, which is all a consumer sees if it records stdout and discards the exit status.
- **What the endpoint needs installed**, if that moved. A prerequisite that disappears is as
  deployment-relevant as one that appears, and easier to omit because nothing breaks. Say what
  the endpoint runs on now, what a deployer can stop provisioning, and whether a machine that
  was failing recovers on its own.
- **Telemetry**, if `docs/telemetry.md` moved: what `bin/classify` now sends or stopped
  sending.
- **Detection changes** — new agents, corrected identifiers, routes now covered. Say plainly
  whether a Mac must rescan or whether reclassifying retained evidence repairs history. **A
  removal on scope grounds is a detection change**: the honest framing is that the last release
  overstated the finding, and `agents.yaml`'s `removed:` block already has the wording.
- **Payload and cost** if either moved, with the measured number and the machine. `osquery/queries/COST.md`
  must say so too, and if enumeration is pushing the payload toward the 30KB budget, that number
  belongs in the notes.
- **Which platform a claim is about.** The coverage figure is all-or-nothing and says nothing about
  where. For a platform claim, name the scenarios that proved it.
- **A cold cost, where one is recorded.** `measure.py` reports the floor of three warm runs;
  `osquery/queries/COST.md` carries the cold number, which is what an endpoint's first scheduled scan pays.
- **Known gaps** carried forward, with the reason each is a gap. A gap belonging to one query is
  in that query's own header comment.

Every quantity is read off the tree, and each source is the **only** copy of what it holds —
quoting a second one against it is how the notes and the docs come to disagree:

| source | take from it |
|---|---|
| `tools/agent_status.py` | *generated* — entry and identifier counts, per-identifier CI coverage, and the **Identifiers that did not pass** table. Its `did not appear` and `no test` states are the honest gaps |
| `docs/agents.md` | *generated* — the page a reader checks the notes against. Take figures from the tool, not by re-counting this |
| `docs/blind-spots.yaml` | hand-maintained, and the canonical list |
| `osquery/queries/COST.md` | measured costs **and the machine they came from** — and on Linux, whether it is the warm floor or the cold run |
| `catalog/routes.yaml` | which routes exist, how each matches, and **which platform each is on** |

### The title

It is read where nobody chose to open anything — the Releases page, a watcher's email, a Slack
unfurl — so the house register does not apply. It answers two things in order: **what changed**,
then **must I act**, which is usually `nothing to redeploy` or the one thing to do.
`v0.7.1 — Nothing to redeploy: clearer bundle errors and complete download docs` is the shape.

- **No term the notes themselves have to define.** If the body explains a word, the title cannot
  use it: `kind=scan`, `superseded` and `six-column contract` are body words.
- **No quoted internal argument**, and no clause that is a punchline to a comment in the tree.
- **Say the effect, not the edit**: "Clearer error when you pass the wrong file", not what moved
  inside which `try`.
- **Plain words over repo nouns**: *downloads* for assets, *the scanner* or *the Mac* for the
  endpoint, *what gets detected* for coverage.
- **Under about 80 characters**, because the Releases page and every email subject truncate.
- **A patch that changes nothing a fleet deploys says so in the title.**

Write it last: if you cannot say what changed without a body word, the summary is not settled.

## 4. Open it as a draft

Never publish directly. A draft creates no tag, notifies nobody, and can be deleted.

**Check for an open draft first** — one can sit for days while `main` moves underneath it:

```console
$ gh release list --limit 5      # a Draft row means stop and read it
$ gh release view v<X.Y.Z> --json createdAt,targetCommitish
$ git log --format='%h %ad %s' --date=iso --since='<draft createdAt>' origin/main | cat
```

A draft holds no tag, so its version is not spent. Keep it and rewrite the body in place
(`gh release edit --notes-file` replaces outright), or `gh release delete v<X.Y.Z> --yes`. Two
drafts is an ambiguity. **Rewrite, never append**: the stale parts of an old draft — a route
table, a coverage figure, a row count — are the ones that read most convincingly. Re-derive every
quantity and confirm every identifier it names is still in the catalog.

```console
$ gh release create v<X.Y.Z> --draft --target <verified-sha> \
    --title "v<X.Y.Z> — <what changed, then must I act. Plain words: see The title above>" \
    --notes-file <notes.md>
```

**Target the full SHA step 2 verified** (the `collect` commit, if you tagged past one), never
`main`. A draft's tag is created on publish, at whatever its target names then, so `main` would
tag anything merged since, including a `.md`-only commit, for which CI runs no scenario.

Hand the user the draft and let them publish; that creates the tag at that commit. **A draft's
`untagged-<hash>` URL changes on every edit**, a retitle included, so the one `create` printed is
dead after the first `gh release edit`. Re-read it after the last edit:

```console
$ gh api repos/<owner>/<repo>/releases --jq '.[] | select(.draft) | .html_url'
```

Better, hand over the two links that cannot go stale: `https://github.com/<owner>/<repo>/releases`,
where drafts sit at the top, and `…/releases/edit/untagged-<hash>`, which opens the editor where
the Publish button is. Both need write access.

**Do not upload anything by hand.** `release.yml` fires on publish, checks the tag is an
ancestor of `main`, re-runs the static gates at that commit, rebuilds `osquery/dist/` from
`osquery/queries/`, builds the two bundles and `catalog.json`, which are never committed, and
attaches them all, so the artifacts derive from the tagged source by construction.

```console
$ gh run list --workflow=release.yml --limit=1
$ gh release view v<X.Y.Z> --json assets --jq '[.assets[].name]'
```

**20 assets**, and a missing one is a broken release: `discovery-darwin.sql`,
`discovery-linux.sql`, `discovery-windows.sql`, `discovery-deep.sql`, `ai-detection-spec.conf`,
`signatures.sql`, `agents-darwin.sql`, `agents-linux.sql`, `agents-windows.sql`,
`fleet-policies.yml`, `discover`, `container-scan`,
`classify`, `agents.yaml`, `routes.yaml`, `catalog.json`, `catalog.schema.json`,
`evidence.schema.json`, `ai-detection-spec-darwin.sh`, `ai-detection-spec-linux.sh`.
`tools/check_workflows.py` holds this list to `release.yml`'s upload step.

The notes must say two things about layout, because the scripts resolve each other by relative
path: ship `bin/`, `dist/`, `catalog/` and `schema/` **side by side** — loose in one folder,
`bin/discover` will not find its artifact — and `classify` needs both catalog files beside it,
or `catalog.json` and `schema/catalog.schema.json`. The two
`ai-detection-spec-*.sh` bundles are that layout packed into one file; they carry no catalog and no
classifier. Windows has neither a bundle nor `discover`, which are bash: it takes
`discovery-windows.sql` and `agents-windows.sql` through `osqueryi`, the pack or the Fleet
policies. Deployment glue for a particular MDM is not released from here.

## Don'ts

- Don't tag a commit that isn't on `main`, or tag before the PR that belongs in the release merges.
- Don't re-tag a published version. Cut a patch instead; a moved tag breaks every pin.
- Don't reintroduce `CHANGELOG.md`. A note that belongs in the tree belongs next to the thing it
  describes — `CONTRIBUTING.md`, `README.md` or `osquery/queries/COST.md`.
