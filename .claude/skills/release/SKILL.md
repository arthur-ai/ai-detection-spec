---
name: release
description: Cut a release of osquery-ai-discovery — pick the version, verify the tree is green and dist/ is in sync, write notes from commit bodies, and open a draft GitHub Release with the dist artifacts attached. Use when asked to cut, tag, or publish a release, or to draft release notes.
---

# Cutting a release

There is no `CHANGELOG.md`. The [Releases page](https://github.com/arthur-ai/osquery-ai-discovery/releases)
is the record, and each release carries the artifacts a fleet deploys. Write it for someone
deciding whether to take the upgrade.

## 1. Pick the version

Rules are in `CONTRIBUTING.md` under **Versioning**. Read the diff, not the commit subjects.

| bump | trigger |
|---|---|
| **major** | the six-column contract or `catalog/agents.yaml`'s schema changed. Consumers must change code |
| **minor** | a new query, or new signatures. Additive |
| **patch** | a corrected identifier, a fixed glob, documentation |

A changed catalog *value* is a patch; a changed *key* is major. **Check removals too** — none of
these shows up in a diff of the six-column contract:

| removal | what breaks |
|---|---|
| an **entry** leaves | its findings stop appearing, and nothing errors |
| a **classification** empties | a consumer mapping it to a UI loses a value |
| a **route key** falls out of use | `ports` and `model_stores` are still *accepted* by `validate_catalog.py` with no entry carrying either, so the route just never fires |
| a **row kind** stops being emitted | `kind='model'` left with the model runners |

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
$ diff <(git show <prev-tag>:dist/discovery-darwin.sql | grep -oE "SELECT '[a-z]+'" | sort -u) \
       <(grep -oE "SELECT '[a-z]+'" dist/discovery-darwin.sql | sort -u)
```

`catalog/agents.yaml`'s own `version:` key does not track the release. It reading `1` is not
evidence the schema held.

**On `0.x` the rule above over-fires**: it was written for a stable tag, and pre-1.0 a break
conventionally rides the minor. Say which convention you followed, and lead with the breaks
either way.

## 2. Verify before you tag

`release.yml` re-runs the static gates on publish, but learning that from a failed workflow means
a published release with no artifacts on it.

```console
$ git switch main && git pull
$ tools/gates.sh                      # every fast gate, and a non-zero exit when one fails
$ python3 tools/measure.py --check    # cost bands; needs osquery locally
$ sudo python3 tools/check_pack.py    # every pack query actually returns rows
$ sudo test/docker_states.sh          # every Docker state, guard, bound, catalog
```

**Call `gates.sh`; don't re-list the gates.** It exists because a hand-rolled loop reported `FAIL`
twice and exited 0 anyway, and it is the only place the list is maintained — so a gate added after
this file was written still runs. Three of them fail in ways that reach the notes:

| gate | what it catches |
|---|---|
| `check_doc_numbers.py` | a number in prose that is no longer true — `CLAUDE.md` claimed 40/40 after it became 38/38. The notes are prose full of numbers |
| `check_workflows.py` | a step referencing a deleted file. An unparseable workflow *vanishes* from the checks list instead of going red, and `scenarios.yml` never runs per PR |
| `agent_status.py --check` | a stale `docs/agents.md`, which is where the notes' coverage figures come from |

The last three commands need osquery or sudo, so they are outside `gates.sh`. Run them: **four
things ship and they are not the same query** (`CLAUDE.md` has the table). A release that checks
only `discovery.sql` has verified a quarter of what it attaches, and the pack once shipped with
four of five queries silently returning zero rows.

Then confirm the last Scenarios run on `main` was green — it runs on dispatch and schedule, so a
red matrix sits undetected:

```console
$ gh run list --workflow=scenarios.yml --branch=main --limit=3
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
  artifact a new query landed in. An `expensive` one is pack-only and never reaches the composed
  file.
- **What the deployer must do** that the repo cannot. `containers.sql` is the standing case:
  `bin/container-scan` is the supported way to run the deep artifact, on its own schedule, scoped
  to machines with Docker — **never inlined on a synchronous reporting path**. Say that non-zero
  outcomes print a `kind=scan` marker row, since a consumer recording stdout and discarding the
  exit status sees only what was printed. And say what folding it into the inventory costs, which
  is not obvious: measured, a bound on the combined query returns the full base inventory, exits
  0, silently omits the container half and spends 6 of the 10 seconds doing it. Unbounded, the
  value blanks outright.
- **Detection changes** — new agents, corrected identifiers, routes now covered. Say plainly
  whether a Mac must rescan or whether reclassifying retained evidence repairs history. **A
  removal on scope grounds is a detection change too**: the honest framing is that the last
  release overstated the finding, and `catalog/agents.yaml`'s `removed:` block already has the
  wording.
- **Payload and cost** if either moved, with the measured number and the machine it came from.
  `queries/COST.md` must say so as well — and if enumeration is pushing the payload toward the
  self-imposed 30KB budget, that number belongs in the notes, not only in the file.
- **Known gaps** carried forward, with the reason each is a gap.

Every quantity is read off the tree. Each source below is the **only** copy of what it holds, so
quoting a second one against it is how the notes and the docs come to disagree:

| source | what to take from it |
|---|---|
| `tools/agent_status.py` | *generated* — entry and identifier counts, per-identifier CI coverage, the exception register. Its `did not appear` and `no test` states are the honest gaps |
| `docs/agents.md` | *generated* — the page a reader checks the notes against. Take figures from the tool, not by re-counting this |
| `docs/blind-spots.yaml` | hand-maintained; "the canonical list, and the only copy". It lived in the README too, and which copy a reader met depended on which page they opened |
| `queries/COST.md` | measured costs, **and the machine they came from**. A cost without its machine is not a measurement |

For a gap belonging to one query rather than the platform, use that query's own comment — the
`npx`/`bunx` cache is the standing case, at the foot of `queries/filesystem.sql`.

## 4. Open it as a draft

Never publish directly. A draft creates no tag, notifies nobody, and can be deleted; publishing
is one click once a human has read it.

**Check for an open draft first** — one can sit for days while `main` moves underneath it, and a
second leaves two plausible releases:

```console
$ gh release list --limit 5      # a Draft row means stop and read it
$ gh release view v<X.Y.Z> --json createdAt,targetCommitish
$ git log --format='%h %ad %s' --date=iso --since='<draft createdAt>' origin/main | cat
```

A draft holds no tag, so **its version is not spent**. Keep it for continued work and rewrite the
body in place (`gh release edit --notes-file` replaces it outright); otherwise
`gh release delete v<X.Y.Z> --yes`, because two drafts is an ambiguity.

**Rewrite the notes, never append.** A draft's body describes a tree that has since changed, and
the stale parts are the specific ones — a route table, a coverage figure, a row count — which are
also the parts that read most convincingly. Re-derive every quantity and confirm every identifier
it names is still in the catalog.

```console
$ gh release create v<X.Y.Z> --draft --target main \
    --title "v<X.Y.Z> — <the one-line reason this release exists>" \
    --notes-file <notes.md>
```

Hand the user the draft URL and let them publish; that creates the tag on `main`.

**Do not upload `dist/` by hand.** `release.yml` fires on publish, checks the tag is an ancestor
of `main`, re-runs the static gates at that commit, rebuilds `dist/` from `queries/` and attaches
the rebuild — so the artifacts are derived from the tagged source by construction rather than by
someone having remembered to run `build.py`. Uploading from a working copy defeats that.

After they publish:

```console
$ gh run list --workflow=release.yml --limit=1
$ gh release view v<X.Y.Z> --json assets --jq '[.assets[].name]'
```

Nine assets, and a missing one is a broken release rather than a tidier one:
`discovery-darwin.sql`, `discovery-linux.sql`, `discovery-deep.sql`, `ai-discovery.conf`,
`discover`, `container-scan`, `classify`, `agents.yaml`, `routes.yaml`.

**There is no unqualified `discovery.sql` any more.** It named one platform while claiming none,
and fed to the wrong `osqueryi` it returns `[\n\n]` and exits 1. A consumer pinning the old
name now gets a 404, which is the failure worth having. `bin/discover` picks by `uname -s`.

**The two catalog files are new to the release** and were a real gap: `bin/classify` defaults to
`catalog/agents.yaml` relative to its own parent, so a downloaded classifier had nothing to
match against unless the consumer also cloned the repo. `routes.yaml` is required beside it --
it is the registry the matcher derives its whole route vocabulary from.

The scripts resolve each other by relative path, so the notes must say the layout is `bin/`,
`dist/` and `catalog/` side by side — loose in one folder, `bin/discover` will not find its
artifact.

**Deployment glue for a particular MDM is not released from here.** A consumer wraps these; this
repo ships osquery materials.

## Don'ts

- Don't tag a commit that isn't on `main`, or tag before the PR that belongs in the release merges.
- Don't re-tag a published version. Cut a patch instead; a moved tag breaks every pin.
- Don't reintroduce `CHANGELOG.md`. A note that belongs in the tree belongs next to the thing it
  describes — `CONTRIBUTING.md`, `README.md` or `queries/COST.md`.
