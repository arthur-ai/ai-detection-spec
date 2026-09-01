---
name: release
description: Cut a release of osquery-ai-discovery — pick the version, verify the tree is green and dist/ is in sync, write notes from commit bodies, and open a draft GitHub Release with the dist artifacts attached. Use when asked to cut, tag, or publish a release, or to draft release notes.
---

# Cutting a release

This repo has no `CHANGELOG.md`. The record of what changed lives on the
[Releases page](https://github.com/arthur-ai/osquery-ai-discovery/releases), and each release
carries the artifacts a fleet actually deploys. That makes the release the deliverable, not a
formality — write it for someone deciding whether to take the upgrade.

## 1. Pick the version

Rules are in `CONTRIBUTING.md` under **Versioning**. Read the diff, don't guess from the commit
subjects:

| bump | trigger |
|---|---|
| **major** | the six-column contract changed, or `catalog/agents.yaml`'s schema did. Consumers must change code. |
| **minor** | a new query, or new signatures. Additive. |
| **patch** | a corrected identifier, a fixed glob, documentation. |

A changed *value* in the catalog is a patch. A changed *key* is major — a consumer parsing the
YAML breaks. Check for both.

**Check what was removed, not only what was added**, because a removal is the bump that gets
under-called. Each kind below breaks a consumer in a way the six-column contract holding would
not reveal:

| removal | what breaks |
|---|---|
| an **entry** leaves the catalog | findings for it stop appearing. A consumer tracking counts sees a drop with no error |
| a **classification** loses its last member | a consumer mapping classifications to a UI has a value vanish. `Container runtime`, `Framework` and `Local model` all went this way |
| a **route key** stops being used | `ports` and `model_stores` are still *accepted* by `validate_catalog.py` while no entry carries either. Nothing errors; the route simply never fires |
| a **row kind** stops being emitted | `kind='model'` left `dist/discovery.sql` with the model runners. A consumer branching on it now gets silence |

```console
$ python3 - <<'EOF'   # entry, key and classification diff across a tag
import subprocess, yaml
old = yaml.safe_load(subprocess.run(["git","show","<previous-tag>:catalog/agents.yaml"],
                                    capture_output=True, text=True).stdout)
new = yaml.safe_load(open("catalog/agents.yaml"))
k = lambda a: set().union(*(set(e) for e in a))
c = lambda a: {e.get("classification") for e in a}
print("entries  ", len(old["agents"]), "->", len(new["agents"]))
print("gone     ", sorted({e["id"] for e in old["agents"]} - {e["id"] for e in new["agents"]}))
print("keys gone", sorted(k(old["agents"]) - k(new["agents"])))
print("class gone", sorted(c(old["agents"]) - c(new["agents"])))
EOF
$ diff <(git show <previous-tag>:dist/discovery.sql | grep -oE "SELECT '[a-z]+'" | sort -u) \
       <(grep -oE "SELECT '[a-z]+'" dist/discovery.sql | sort -u)
```

`catalog/agents.yaml`'s own `version:` key is a **separate** number and does not track the
release. It saying `1` is not evidence the schema held.

**Pre-1.0, the repository is not at the version its own rule implies.** The rule above was
written for a stable tag and says major for a schema change; on `0.x` a breaking change
conventionally rides the minor instead. Say which convention you are following in the notes and
put the breaking changes first either way — but do not silently downgrade a break to a minor and
leave the reader to find it.

## 2. Verify before you tag

`release.yml` re-runs the static gates on publish and will refuse a stale `dist/`, but finding
that out from a failed workflow means a published release with no artifacts on it. Check first.

```console
$ git switch main && git pull
$ tools/gates.sh                      # every fast gate, and a non-zero exit when one fails
$ python3 tools/measure.py --check    # cost bands; needs osquery locally
$ sudo python3 tools/check_pack.py    # every pack query actually returns rows
$ sudo test/docker_states.sh          # every Docker state, guard, bound, catalog
```

**Run `tools/gates.sh` rather than the gates by hand.** It exists because a hand-rolled loop
reported `FAIL` for two gates and exited 0 anyway, and the commit that followed went in
regardless — a checklist that cannot fail is a checklist nobody has to obey. It is also the only
place the list of fast gates is maintained, so a gate added after this file was written still
runs — which is why no list of them is repeated here. These are the ones whose failure mode is
specifically a bad release:

| gate | what it stops shipping |
|---|---|
| `build.py --check` | a `dist/` that does not match `queries/`. `release.yml` refuses one anyway, but from a failed workflow after publish |
| `check_doc_numbers.py` | **a number in prose that is no longer true.** It exists because `CLAUDE.md` claimed 40/40 coverage after the figure became 38/38. Release notes are prose full of numbers; this is the gate that has your back |
| `check_workflows.py` | a workflow step referencing a deleted file. A workflow that does not parse *disappears* from the checks list rather than going red, and `scenarios.yml` does not run per PR — that is how `measure_payload.py` was removed while CI stayed green |
| `agent_status.py --check` | a stale `docs/agents.md`, which is where the notes' coverage and exception figures come from |

The three that follow it are not in `gates.sh` because they need osquery, sudo or both. The last
two of those exist because **four things ship and they are not the same query**.
`dist/discovery.sql` is the composed `fast` and `slow` queries. `dist/ai-discovery.conf` is the
pack, and it additionally carries `containers.sql`, which is `expensive`.
`dist/discovery-deep.sql` composes the `expensive` queries on their own — a **supplement, not a
superset**. And `bin/container-scan` is not a query at all: it is the only supported way to run
the deep artifact, because that artifact can block forever and the bound lives in the runner.
`bin/discover` joins the two. A release that only checks `discovery.sql` has verified a quarter
of what it attaches — and the pack once shipped with four of five queries silently returning
zero rows.

Confirm the last Scenarios run on `main` was green — it runs on dispatch and schedule, not per
PR, so a red matrix can sit undetected:

```console
$ gh run list --workflow=scenarios.yml --branch=main --limit=3
```

If the payload moved, `queries/COST.md` must say so. Enumeration means every Mac reports its
whole inventory; a 30KB value channel binds around 1150 rows, and a release that
pushes toward it needs the number in the notes, not just in the file.

## 3. Write the notes

**Source them from commit bodies, not PR titles.** `git log` in this repo carries the reasoning,
the measurements and the rejected alternatives; the subject line carries almost none of it.
`--generate-notes` produces a list of PR titles and is not adequate here.

```console
$ git log <previous-tag>..HEAD --format='%H%n%B%n---'
```

Write in the repo's register: state the change, then its consequence for someone running this on
a fleet. Cover, when each applies:

- **What consumers deploy** — `dist/discovery.sql` and `dist/ai-discovery.conf`, and whether the
  six-column contract or the row kinds moved. Say which artifact a new query landed in: an
  `expensive` one is pack-only and does not reach anyone running the composed file.
- **Anything the deployer must do**, where the repo cannot do it for them. `containers.sql` is
  the standing case, and what it asks for has changed: the repo now ships the runner, so tell
  people to use it rather than to build their own. **`bin/container-scan` is the supported way
  to run the deep artifact** — never inline it on a synchronous reporting path. It carries a round
  trip demanding HTTP 200 *and* a wall-clock kill, because a daemon that pings 200 and then
  stops serving passes the health check and blocks the query anyway. Say in the notes that it
  deploys on its own schedule, scoped to machines that have Docker; that its non-zero outcomes
  print a `kind=scan` marker row, because a consumer that records stdout and discards the exit
  status sees only what was printed; and what folding it into the inventory EA
  actually costs, which is not obvious: measured, a bound on the combined query returns the
  full base inventory and exits 0 while silently omitting the container half, and spends 6
  of the 10 seconds doing it. Left unbounded, the inventory value blanks outright. A release that ships the query without
  this is a stall waiting to happen.
- **Detection changes** — new agents in the catalog, corrected identifiers, which install routes
  are covered. Say plainly whether a Mac must rescan, or whether reclassifying retained evidence
  repairs history. **An agent removed on scope grounds is a detection change too**, and the
  honest framing is that the previous release overstated the finding rather than that this one
  detects less: `catalog/agents.yaml`'s `removed:` block says what each thing actually is, and
  the notes should use its wording rather than invent another.
- **Payload and cost**, if either moved, with the measured number and the machine it came from.
- **Known gaps** carried forward, with the reason they are gaps.
- **Breaking changes** first, with the migration, if the bump is major.

### Where each fact comes from

Every quantity is read off the tree, never recalled and never carried over from the previous
release's notes. Each source below is the **only** copy of what it holds, so quoting a second
one against it is how the notes and the docs come to disagree:

| source | generated? | what to take from it |
|---|---|---|
| `python3 tools/agent_status.py` | yes, from the catalog and the scenarios | entry and identifier counts, per-identifier CI coverage, and the exception register. Its `did not appear` and `no test` states are the honest gaps |
| `docs/agents.md` | yes, by `agent_status.py --write` | the page a reader will check the notes against. Take figures from the tool, not by re-counting this |
| `docs/blind-spots.yaml` | no — hand-maintained data | the platform blind spots. It says of itself "the canonical list, and the only copy": it lived in the README too, and which copy a reader met depended on which page they opened |
| `queries/COST.md` | no — measured and written down | costs per query, **and the machine they were taken on**. A cost without its machine is not a measurement |

For a gap that is a property of one query rather than of the platform, the comment in that query
is the wording to use — the `npx`/`bunx` cache is the standing case and lives at the foot of
`queries/filesystem.sql`. **Do not restate a number `check_doc_numbers.py` guards** unless you
are prepared for it to be checked; that gate runs inside `gates.sh` and will tell you which line
is wrong.

## 4. Open it as a draft

Never create a release straight to published. A draft creates no tag, sends no notifications, and
can be deleted outright; publishing is one click once a human has read it.

**First check whether a draft is already open**, because a draft can sit unpublished for days
while `main` moves underneath it, and creating a second one leaves two plausible releases where a
human has to work out which is live:

```console
$ gh release list --limit 5                       # a Draft row means stop and read it
$ gh release view v<X.Y.Z> --json createdAt,targetCommitish,body --jq '{createdAt,targetCommitish}'
$ git log --format='%h %ad %s' --date=iso --since='<the draft createdAt>' origin/main | cat
```

An unpublished draft carries no tag, so **the version it claims is not spent**. If the work since
is a continuation, keep that version and rewrite the draft in place with `gh release edit`; a
`--notes-file` replaces the body outright.

**Rewrite the notes, do not append to them.** A draft's body is a claim about a tree that has
since changed, and the parts most likely to be stale are the specific ones — a table of catalog
routes, a coverage figure, a row count. Re-derive every quantity from the sources in step 3 and
confirm each identifier the draft names is still in the catalog, rather than trusting a section
that reads fine. A stale draft published as-is is exactly the failure this repo exists to avoid:
a plausible, well-written, wrong answer.

If you are not keeping the version, **delete the old draft** rather than leaving it. Two drafts
is an ambiguity, and this one has no tag to preserve:

```console
$ gh release delete v<X.Y.Z> --yes
```

Otherwise, create it:

```console
$ gh release create v<X.Y.Z> \
    --draft \
    --target main \
    --title "v<X.Y.Z> — <the one-line reason this release exists>" \
    --notes-file <notes.md>
```

Then hand the user the draft URL and let them publish. Publishing creates the tag on `main`.

**Do not upload `dist/` by hand.** `.github/workflows/release.yml` fires on publish: it checks
the tag is an ancestor of `main`, re-runs the static gates against the tagged commit, rebuilds
`dist/` from `queries/` at that tag and attaches the rebuild. That makes the attached file
derived from the tagged queries by construction rather than by someone having remembered to run
`build.py`. Uploading from a working copy defeats it.

After the user publishes, confirm the workflow went green and the assets are attached:

```console
$ gh run list --workflow=release.yml --limit=1
$ gh release view v<X.Y.Z> --json assets --jq '[.assets[].name]'
```

Six assets, and a missing one is a broken release rather than a tidier one:
`discovery.sql`, `discovery-deep.sql`, `ai-discovery.conf`, `discover`, `container-scan`,
`classify`.

The scripts resolve each other and the artifacts by relative path, so the notes must say the
layout is `bin/` and `dist/` side by side — downloaded loose into one folder, `bin/discover`
will not find `dist/discovery.sql`.

**Deployment glue for a particular MDM is not released from here.** A consumer wraps these
artifacts; this repo ships osquery materials.

## Don'ts

- Don't tag a commit that isn't on `main`, and don't tag before the PR that belongs in the
  release is merged.
- Don't re-tag a published version. Cut a patch instead; a moved tag breaks every pin.
- Don't reintroduce `CHANGELOG.md`. If a note belongs in the tree it belongs in
  `CONTRIBUTING.md`, `README.md` or `queries/COST.md`, next to the thing it describes.
