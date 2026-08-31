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

## 2. Verify before you tag

`release.yml` re-runs the static gates on publish and will refuse a stale `dist/`, but finding
that out from a failed workflow means a published release with no artifacts on it. Check first.

```console
$ git switch main && git pull
$ test/lint.sh                        # six-column contract, dangling UNION ALL, kind coverage
$ python3 tools/build.py --check      # dist/ matches queries/ — catches a stale artifact
$ python3 tools/validate_catalog.py
$ python3 tools/check_no_catalog.py   # no agent identifiers leaked back into the SQL
$ python3 tools/measure.py --check    # cost bands; needs osquery locally
$ sudo python3 tools/check_pack.py    # every pack query actually returns rows
$ sudo test/docker_states.sh          # every Docker state, guard, bound, catalog, ~35s
```

The last two exist because **four things ship and they are not the same query**.
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
whole inventory; the 30KB Extension Attribute cap binds around 1150 rows, and a release that
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
  to run the deep artifact** — never inline it in an Extension Attribute. It carries a round
  trip demanding HTTP 200 *and* a wall-clock kill, because a daemon that pings 200 and then
  stops serving passes the health check and blocks the query anyway. Say in the notes that it
  deploys as **its own** Extension Attribute, with its own ten seconds and its own 30KB, scoped
  to Macs with Docker; that its non-zero outcomes print a `kind=scan` marker row because Jamf
  records stdout and discards exit status; and what folding it into the inventory EA
  actually costs, which is not obvious: measured, a bound on the combined query returns the
  full base inventory and exits 0 while silently omitting the container half, and spends 6
  of the 10 seconds doing it. Left unbounded, the inventory value blanks outright. A release that ships the query without
  this is a stall waiting to happen.
- **Detection changes** — new agents in the catalog, corrected identifiers, which install routes
  are covered. Say plainly whether a Mac must rescan, or whether reclassifying retained evidence
  repairs history.
- **Payload and cost**, if either moved, with the measured number and the machine it came from.
- **Known gaps** carried forward, with the reason they are gaps. `npx`-invoked packages are the
  standing one; check the foot of `queries/filesystem.sql` for the current wording.
- **Breaking changes** first, with the migration, if the bump is major.

Quantities are facts read off the tree, not recalled: count the catalog entries and the scenarios
rather than repeating a number from a previous release.

## 4. Open it as a draft

Never create a release straight to published. A draft creates no tag, sends no notifications, and
can be deleted outright; publishing is one click once a human has read it.

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

Eight assets, and a missing one is a broken release rather than a tidier one:
`discovery.sql`, `discovery-deep.sql`, `ai-discovery.conf`, `jamf-collect.sh`, `discover`,
`container-scan`, `classify`, `com.arthur.ai-discovery.plist`.

`jamf-collect.sh` is the one most consumers will actually deploy: it is self-contained, so it
needs neither the other assets beside it nor a package. It embeds `bin/` and `dist/`, which is
why `build.py` writes it last and `--check` compares it against a fresh build of the tree. The scripts resolve each other and the artifacts by relative path, so the notes
must say the layout is `bin/` and `dist/` side by side — downloaded loose into one folder,
`bin/discover` will not find `dist/discovery.sql`.

## Don'ts

- Don't tag a commit that isn't on `main`, and don't tag before the PR that belongs in the
  release is merged.
- Don't re-tag a published version. Cut a patch instead; a moved tag breaks every pin.
- Don't reintroduce `CHANGELOG.md`. If a note belongs in the tree it belongs in
  `CONTRIBUTING.md`, `README.md` or `queries/COST.md`, next to the thing it describes.
