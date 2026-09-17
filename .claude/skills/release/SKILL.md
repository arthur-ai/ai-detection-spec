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
| a **route key** falls out of use | `model_stores` is still *accepted* by `validate_catalog.py` with no entry carrying it, so the route just never fires. `ports` was the other, and is now declared `retired: true` in `routes.yaml` — that one is visible, the silent case is the undeclared one |
| a **row kind** stops being emitted | `kind='model'` left with the model runners |
| an identifier is **superseded** | it stays in the catalog and stays matched, but leaves continuous testing — and `agent_status.py` drops it from the coverage denominator, so the identifier count falls with nothing removed. Say which value, and that machines on the old build still report it |

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

**Both artifacts, because a kind can move on one platform only.** The composed file is per
platform and they name disjoint tables, so diffing just one hides half the answer — and the
half it hides is whichever platform you are not sitting on.

`catalog/agents.yaml`'s own `version:` key does not track the release, and it moves for its own
reasons — it read `2` at v0.3.0 and reads `2` now, across a release that removed a schema key.
Reading it unchanged is not evidence the schema held. Diff the keys.

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
| `check_workflows.py` | a step referencing a deleted file, a scenario in no job's matrix, a scenario paired with a runner that cannot host it, and an input missing from `docs.yml`'s path trigger. An unparseable workflow *vanishes* from the checks list instead of going red |
| `agent_status.py --check` | a stale `docs/agents.md`, which is where the notes' coverage figures come from |

The last three commands need osquery or sudo, so they are outside `gates.sh`. Run them:
**several things ship and they are not the same query** (`CLAUDE.md` has the table). A release
that checks one composed artifact has verified a fraction of what it attaches, and the pack once
shipped with four of five queries silently returning zero rows.

### You cannot verify both platforms from one machine, and the tools say which they checked

**`measure.py`, `check_pack.py` and `docker_states.sh` each resolve the platform themselves and
skip the other's queries by name.** That is deliberate — a Linux query measured on macOS reported
`0.24s, 0 rows`, which is a query that ERRORED being recorded as fast — but it means the three
commands above verify **only the half you are sitting on**. They say so:

```console
  skipped (other platform): desktop-linux(linux), filesystem-linux(linux), ...
pack: ok, 10 of 15 queries run on darwin
```

**Read that line.** If it says `darwin`, nothing local has run a Linux query. Two ways to cover
the other half, and CI is the one that counts:

```console
$ gh run list --workflow=ci.yml --branch=main --limit=1     # Runtime on macOS AND on Linux
$ test/run-linux.sh                                          # locally, in containers, needs Docker
```

`test/run-linux.sh` skips several scenarios for reasons that are facts about the container or the
host arch rather than about the software — `76-linux-systemd` needs a real system bus,
`79-linux-image` needs a reachable Docker daemon, and `73`, `75` and `78` need an x86_64 host for
the vendor builds they install — so a clean local run is not the same claim as a green CI run.
Each prints its reason and exits 3; **read them**, because a suite reporting SKIP for the half
you care about has verified nothing about it.

### Confirm the Scenarios run for the exact commit you are tagging

Scenarios run **per pull request** as well as on push, schedule and dispatch, so the suite is
usually already green for the commit you are about to tag. Check the commit rather than the
branch, because a `pull_request` run reports against the PR's MERGE commit and a `push` run
against `main` — and reading the wrong one is how a release gets cut on someone else's result:

```console
$ sha=$(git rev-parse HEAD)
$ gh run list --workflow=scenarios.yml --branch=main --limit=6 \
    --json headSha,status,conclusion,databaseId \
    --jq ".[] | select(.headSha==\"$sha\") | \"\(.databaseId) \(.status)/\(.conclusion)\""
```

A run that is **queued has no jobs yet**, and an empty job list is not the same as nothing
failing. If that prints nothing for a commit someone pushed, the suite has not run for it —
wait, do not read the previous one.

**With one exception, and you will hit it on almost every release: the `collect` commit can
never have a run of its own.** A push made by a workflow with the default `GITHUB_TOKEN` does
not trigger further workflow runs, and `collect` pushes with it. So the "record identifier
coverage" commits get no `push` run — the runs that appear against those SHAs are the next
*scheduled* one, which merely started there. Read the `event` field and you can see it:

```console
$ gh run list --workflow=scenarios.yml --branch=main --limit=6 \
    --json headSha,event,conclusion,databaseId \
    --jq '.[] | "\(.databaseId) \(.headSha[0:7]) \(.event) \(.conclusion)"'
```

Taken with the next section — which tells you to move to the post-`collect` commit — waiting
for a run there deadlocks. What resolves it is that `collect` commits **generated files only**.
Verify that rather than assume it, then tag it on the strength of the run at the commit it sits
on top of:

```console
$ git diff --name-only <verified-sha> HEAD | grep -v 'observed.json\|docs/agents.md'
```

Empty output means the code, queries and catalog are byte-identical to the commit the suite
actually ran on. Anything else printed means this is not just a `collect` commit and the run
you were about to rely on does not describe it.

### Confirm the observations landed, or the coverage figures are a merge behind

The `collect` job runs **only on `main`** — a pull request asserts and uploads without committing,
because a PR must not be able to move recorded coverage. It commits two things: each scenario's
`observed.json` **and the regenerated `docs/agents.md`**. So immediately after merging a PR that
adds an identifier's first real install, the page still describes the tree as it was.

This has already happened: `79-linux-image` pulled `paulgauthier/aider` for real and passed on
the PR, and `docs/agents.md` read *"47 of them by a real install"* until collect ran on `main` and
moved it to 48. **A release cut in that window quotes a figure that is stale by one merge**, and
every coverage number in the notes comes from that page.

```console
$ git log --oneline -3 origin/main            # a "record identifier coverage" commit after your merge
$ gh run list --workflow=scenarios.yml --branch=main --limit=1 \
    --json databaseId,status,conclusion
$ tools/gates.sh                              # agent_status --check fails on a stale page
```

`gates.sh` catches the stale page but not the *pending* one: a tree whose `agents.md` matches its
own uncommitted observations is internally consistent and still a merge behind. Pull `main` again
after collect lands, and tag the commit it produced — checking, per the section above, that it
holds nothing but generated files.

**`collect` also fails on a push race, and that failure is not a gate failure.** Two runs
finishing close together both try to push to `main` and the loser reports
`! [rejected] main -> main (fetch first)`. It is self-healing — the next run commits what the
loser could not — but it puts a red Scenarios run on `main` that a releaser will read as a
broken suite. Check which job failed before concluding anything:

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
- **Which platform a claim is about.** The coverage figure is all-or-nothing and says nothing
  about where — `docs/agents.md` has no per-platform fraction, deliberately: three figures that
  looked like they should agree were unreadable, and a fraction invites "91% done" when the
  real meaning is "the build would be red". For a platform claim, name the SCENARIOS that
  proved it; the Linux ones say so in their names.
- **A cold cost, where one is recorded.** `measure.py` reports the floor of three warm runs; the
  composed Linux artifact measured 1.12s that way and 8–14s cold under `sudo` on a loaded
  runner. The cold number is what an endpoint's first scheduled scan pays, so that is the one a
  reader is deciding with.
- **Known gaps** carried forward, with the reason each is a gap.

Every quantity is read off the tree. Each source below is the **only** copy of what it holds, so
quoting a second one against it is how the notes and the docs come to disagree:

| source | what to take from it |
|---|---|
| `tools/agent_status.py` | *generated* — entry and identifier counts, per-identifier CI coverage, and the **Identifiers that did not pass** table. Its `did not appear` and `no test` states are the honest gaps. There is no longer an exception register to quote: the `unverified:` block and its evidence grades are gone, and an agent no scenario installs now fails `validate_catalog.py` outright |
| `docs/agents.md` | *generated* — the page a reader checks the notes against. Take figures from the tool, not by re-counting this |
| `docs/blind-spots.yaml` | hand-maintained; "the canonical list, and the only copy". It lived in the README too, and which copy a reader met depended on which page they opened |
| `queries/COST.md` | measured costs, **and the machine they came from**. A cost without its machine is not a measurement — and on Linux, without saying whether it is the warm floor or the cold run, which differ by 8x |
| `catalog/routes.yaml` | which routes exist, how each matches, and **which platform each one is on**. The only copy: the matcher, the validator, the coverage report and lint all derive from it |

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
