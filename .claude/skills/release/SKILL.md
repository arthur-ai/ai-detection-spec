---
name: release
description: Cut a release of osquery-ai-discovery — pick the version, verify the tree is green and dist/ is in sync, write notes from commit bodies, and open a draft GitHub Release with the dist artifacts attached. Use when asked to cut, tag, or publish a release, or to draft release notes.
---

# Cutting a release

No `CHANGELOG.md`. The [Releases page](https://github.com/arthur-ai/osquery-ai-discovery/releases)
is the record, and each release carries the artifacts a fleet deploys. Write it for someone
deciding whether to take the upgrade.

## 1. Pick the version

Rules are in `CONTRIBUTING.md` under **Versioning**. Read the diff, not the commit subjects.

| bump | trigger |
|---|---|
| **major** | the six-column contract or `catalog/agents.yaml`'s schema changed. Consumers must change code |
| **minor** | a new query, or new signatures. Additive |
| **patch** | a corrected identifier, a fixed glob, documentation |

A changed catalog *value* is a patch; a changed *key* is major.

**Check removals too** — none of these appears in a diff of the six-column contract:

| removal | what breaks |
|---|---|
| an **entry** leaves | its findings stop appearing, and nothing errors |
| a **classification** empties | a consumer mapping it to a UI loses a value |
| a **route key** falls out of use | `validate_catalog.py` still accepts it with no entry carrying it, so the route never fires. `model_stores` is in that state now; `ports` is declared `retired: true`, which is the visible case |
| a **row kind** stops being emitted | `kind='model'` left with the model runners |
| an identifier is **superseded** | it stays matched but leaves continuous testing, and `agent_status.py` drops it from the coverage denominator — so the identifier count falls with nothing removed. Say which value, and that machines on the old build still report it |
| a **flag or mode** leaves a shipped script | nothing in `dist/` or `catalog/` moves, so every check above says patch. It is not: a script in `bin/` is an interface, and someone has the old invocation in a LaunchDaemon or a runbook. `--pretty` went this way at v0.5.0. Say which invocation to replace, and confirm the flag is refused by name rather than falling through to "unknown argument" |

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
$ for p in darwin linux; do
    diff <(git show <prev-tag>:dist/discovery-$p.sql 2>/dev/null \
             | grep -oE "SELECT '[a-z]+'" | sort -u) \
         <(grep -oE "SELECT '[a-z]+'" dist/discovery-$p.sql | sort -u) \
      && echo "$p: same kinds"
  done
```

**Diff both artifacts**: they are per platform and name disjoint tables, so diffing one hides
whichever platform you are not sitting on.

`catalog/agents.yaml`'s `version:` key does not track the release — it read `2` across a release
that removed a schema key. Diff the keys instead.

**On `0.x` the major rule over-fires**: pre-1.0 a break conventionally rides the minor. Say which
convention you followed, and lead with the breaks either way.

## 2. Verify before you tag

`release.yml` re-runs the static gates on publish, but learning that from a failed workflow means
a published release with no artifacts on it.

```console
$ git switch main && git pull
$ tools/gates.sh                      # every fast gate, non-zero when one fails
$ python3 tools/measure.py --check    # cost bands; needs osquery locally
$ sudo python3 tools/check_pack.py    # every pack query actually returns rows
$ sudo test/docker_states.sh          # every Docker state, guard, bound, catalog
```

**Call `gates.sh`; don't re-list the gates.** A hand-rolled loop once reported `FAIL` twice and
exited 0, and this is the only place the list is maintained, so a gate added later still runs.
Three of its failures reach the notes directly:

| gate | what it means |
|---|---|
| `check_doc_numbers.py` | a number in prose is no longer true. The notes are prose full of numbers |
| `check_workflows.py` | a workflow references a deleted file, or a scenario is in no job's matrix. An unparseable workflow *vanishes* from the checks list instead of going red |
| `agent_status.py --check` | `docs/agents.md` is stale, and that is where the notes' coverage figures come from |

The last three need osquery or sudo, so they sit outside it. Run them: **several things ship and
they are not the same query** (`CLAUDE.md` has the table). The pack once shipped with four of five
queries silently returning zero rows.

### One machine verifies one platform

`measure.py`, `check_pack.py` and `docker_states.sh` each resolve the platform and skip the
other's queries by name — deliberately, because a Linux query measured on macOS reported
`0.24s, 0 rows`, which is an error recorded as speed. They say which half they ran:

```console
pack: ok, 10 of 15 queries run on darwin
```

**Read that line.** For the other half, CI is the one that counts:

```console
$ gh run list --workflow=ci.yml --branch=main --limit=1     # macOS AND Linux
$ test/run-linux.sh                                          # locally, needs Docker
```

`run-linux.sh` skips scenarios for reasons about the container or host arch, not the software —
`76` needs a real system bus, `79` a reachable Docker daemon, and `73`/`75`/`78` an x86_64 host.
Each prints its reason and exits 3. **Read them**: a suite reporting SKIP for the half you care
about has verified nothing about it.

### Confirm the suite ran for the exact commit you are tagging

Check the commit, not the branch: a `pull_request` run reports against the PR's merge commit and
a `push` run against `main`, and reading the wrong one cuts a release on someone else's result.

```console
$ sha=$(git rev-parse HEAD)
$ gh run list --workflow=scenarios.yml --branch=main --limit=6 \
    --json headSha,status,conclusion,databaseId \
    --jq ".[] | select(.headSha==\"$sha\") | \"\(.databaseId) \(.status)/\(.conclusion)\""
```

Nothing printed means the suite has not run for that commit — wait, do not read the previous one.
A **queued** run has no jobs yet, which is not the same as nothing failing.

**The `collect` commit can never have a run of its own, and you will hit this nearly every
release.** A push made with the default `GITHUB_TOKEN` triggers no further runs, and `collect`
pushes with it — so the runs appearing against those SHAs are the next *scheduled* one, which
merely started there. Check the `event` field:

```console
$ gh run list --workflow=scenarios.yml --branch=main --limit=6 \
    --json headSha,event,conclusion,databaseId \
    --jq '.[] | "\(.databaseId) \(.headSha[0:7]) \(.event) \(.conclusion)"'
```

With the next section telling you to move to the post-`collect` commit, waiting for a run there
deadlocks. What resolves it is that `collect` commits **generated files only** — verify that,
then tag on the strength of the run at the commit beneath it:

```console
$ git diff --name-only <verified-sha> HEAD | grep -v 'observed.json\|docs/agents.md'
```

Empty means the code, queries and catalog are byte-identical to what the suite ran on. Anything
printed means this is not just a `collect` commit.

### Confirm the observations landed

`collect` runs **only on `main`** — a PR asserts and uploads without committing, so coverage
cannot be moved by a PR. It commits each scenario's `observed.json` **and the regenerated
`docs/agents.md`**, which is where every coverage figure in the notes comes from. Immediately
after merging, that page is a merge behind: `79-linux-image` installed `paulgauthier/aider` for
real and the page still read *"47 of them by a real install"* until collect ran and moved it to 48.

```console
$ git log --oneline -3 origin/main    # expect a "record identifier coverage" commit after your merge
$ gh run list --workflow=scenarios.yml --branch=main --limit=1 --json databaseId,status,conclusion
$ tools/gates.sh                      # agent_status --check fails on a stale page
```

`gates.sh` catches a stale page but not a *pending* one: a tree matching its own uncommitted
observations is internally consistent and still a merge behind. Pull again after collect lands.

**A `collect` push race is not a gate failure.** Two runs finishing together both push; the loser
reports `! [rejected] main -> main (fetch first)`. Self-healing, but it leaves a red run a
releaser reads as a broken suite. Check which job failed:

```console
$ gh run view <id> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .name'
```

## 3. Write the notes

**Source them from commit bodies, not PR titles** — the reasoning, measurements and rejected
alternatives are in the body, and `--generate-notes` gives you neither.

```console
$ git log <prev-tag>..HEAD --format='%H%n%B%n---'
```

State the change, then its consequence for someone running this on a fleet. Cover what applies:

- **Breaking changes first**, with the migration.
- **What consumers deploy** — whether the six-column contract or the row kinds moved, and which
  artifact a new query landed in. An `expensive` one is pack-only and never reaches the composed file.
- **What the deployer must do** that the repo cannot. `containers.sql` is the standing case:
  `bin/container-scan` is the supported way to run the deep artifact, on its own schedule, scoped
  to machines with Docker — **never inlined on a synchronous reporting path**. Non-zero outcomes
  print a `kind=scan` marker row, which is all a consumer sees if it records stdout and discards
  the exit status. Folding it into the inventory costs more than it looks: measured, a bound on
  the combined query returns the full base inventory, exits 0, silently omits the container half,
  and spends 6 of the 10 seconds doing it. Unbounded, the value blanks outright.
- **What the endpoint needs installed**, if that moved. A prerequisite that DISAPPEARS is as
  deployment-relevant as one that appears, and it is the easier one to omit because nothing
  breaks by omitting it: a fleet that provisioned for the old requirement keeps working and
  nobody learns they can stop. v0.5.0 is the standing case — the endpoint stopped needing
  `python3`, which on a Mac without Command Line Tools was a stub that made the scheduled writer
  emit nothing at all. Say what it runs on now, what a deployer can stop provisioning, and
  whether a machine that was failing recovers on its own.
- **Detection changes** — new agents, corrected identifiers, routes now covered. Say plainly
  whether a Mac must rescan or whether reclassifying retained evidence repairs history. **A
  removal on scope grounds is a detection change**: the honest framing is that the last release
  overstated the finding, and `agents.yaml`'s `removed:` block already has the wording.
- **Payload and cost** if either moved, with the measured number and the machine. `queries/COST.md`
  must say so too, and if enumeration is pushing the payload toward the 30KB budget, that number
  belongs in the notes.
- **Which platform a claim is about.** The coverage figure is all-or-nothing and says nothing about
  where. For a platform claim, name the scenarios that proved it.
- **A cold cost, where one is recorded.** `measure.py` reports the floor of three warm runs; the
  composed Linux artifact measured 1.12s that way and 8–14s cold under `sudo`. Cold is what an
  endpoint's first scheduled scan pays.
- **Known gaps** carried forward, with the reason each is a gap.

Every quantity is read off the tree, and each source is the **only** copy of what it holds —
quoting a second one against it is how the notes and the docs come to disagree:

| source | take from it |
|---|---|
| `tools/agent_status.py` | *generated* — entry and identifier counts, per-identifier CI coverage, and the **Identifiers that did not pass** table. Its `did not appear` and `no test` states are the honest gaps |
| `docs/agents.md` | *generated* — the page a reader checks the notes against. Take figures from the tool, not by re-counting this |
| `docs/blind-spots.yaml` | hand-maintained, and the canonical list |
| `queries/COST.md` | measured costs **and the machine they came from** — and on Linux, whether it is the warm floor or the cold run, which differ by 8x |
| `catalog/routes.yaml` | which routes exist, how each matches, and **which platform each is on**. The matcher, validator, coverage report and lint all derive from it |

For a gap belonging to one query rather than the platform, use that query's own comment — the
`npx`/`bunx` cache at the foot of `queries/filesystem.sql` is the standing case.

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
drafts is an ambiguity.

**Rewrite the notes, never append.** A draft describes a tree that has changed, and the stale
parts — a route table, a coverage figure, a row count — are the ones that read most convincingly.
Re-derive every quantity and confirm every identifier it names is still in the catalog.

```console
$ gh release create v<X.Y.Z> --draft --target main \
    --title "v<X.Y.Z> — <the one-line reason this release exists>" \
    --notes-file <notes.md>
```

Hand the user the draft URL and let them publish; that creates the tag on `main`.

**Do not upload `dist/` by hand.** `release.yml` fires on publish, checks the tag is an ancestor
of `main`, re-runs the static gates at that commit, rebuilds `dist/` from `queries/` and attaches
the rebuild — so the artifacts derive from the tagged source by construction. Uploading from a
working copy defeats that.

```console
$ gh run list --workflow=release.yml --limit=1
$ gh release view v<X.Y.Z> --json assets --jq '[.assets[].name]'
```

**Eleven assets**, and a missing one is a broken release: `discovery-darwin.sql`,
`discovery-linux.sql`, `discovery-deep.sql`, `ai-discovery.conf`, `discover`, `container-scan`,
`classify`, `agents.yaml`, `routes.yaml`, `ai-discovery-darwin.sh`, `ai-discovery-linux.sh`.
`tools/check_workflows.py` derives this list from `release.yml` and fails when the two
disagree — it read `Nine` for a release after the bundles were added, because no gate read
this file.

Two things the notes must say about layout, because the scripts resolve each other by relative
path: ship `bin/`, `dist/` and `catalog/` **side by side** — loose in one folder, `bin/discover`
will not find its artifact — and `classify` needs both catalog files beside it, since it defaults
to `catalog/agents.yaml` relative to its own parent and derives its route vocabulary from
`routes.yaml`. The two `ai-discovery-*.sh` bundles are that layout packed into one file, for a
consumer who would rather not reproduce it; they carry no catalog and no classifier.


**Deployment glue for a particular MDM is not released from here.** This repo ships osquery
materials; a consumer wraps them.

## Don'ts

- Don't tag a commit that isn't on `main`, or tag before the PR that belongs in the release merges.
- Don't re-tag a published version. Cut a patch instead; a moved tag breaks every pin.
- Don't reintroduce `CHANGELOG.md`. A note that belongs in the tree belongs next to the thing it
  describes — `CONTRIBUTING.md`, `README.md` or `queries/COST.md`.
