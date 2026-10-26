# Contributing

The most valuable contribution is **a new agent, or a correction to an identifier we have
wrong**. Next is a **detection gap** you can reproduce. Changes to [the spec](SPEC.md) are
welcome too; [Versioning](#versioning) says how one is released.

**First response within five working days**, and that covers a maintainer running your
scenario, not only reading the diff. Contributions are accepted under the
[Apache-2.0](LICENSE) license.

## Adding an agent or an identifier

1. **Check it is an agent.** [SPEC.md §3](SPEC.md#3-scope-what-counts-as-an-agent) is the test,
   and `removed:` in `catalog/agents.yaml` lists what failed it.
2. **Install the real thing**, on the platform it ships for, and read the identifier off the
   install, never off vendor documentation:
   ```console
   $ osqueryi "SELECT bundle_identifier, bundle_short_version, path FROM apps WHERE path LIKE '%Thing%'"
   $ osqueryi "SELECT name, version FROM deb_packages WHERE name LIKE '%thing%' AND status LIKE '%ok installed'"
   ```
   [The *New AI agent* issue template](.github/ISSUE_TEMPLATE/new-agent.md) has a query per
   route.
3. **Add it to `catalog/agents.yaml`**, one entry per agent carrying every route it ships
   through. A single agent often ships as a Homebrew cask, an npm global and a curl installer,
   and each lands somewhere different. `catalog/routes.yaml` declares each route's kind, match
   mode and platform.
   ```yaml
   - id: openclaw
     name: OpenClaw
     classification: Personal agent             # deployment shape, not risk
     platforms: [darwin, linux]                 # each must have one of its routes
     bundle_ids: [ai.openclaw.mac]
     npm: [openclaw, clawdbot, moltbot]
     state_dirs: ["~/.openclaw"]
   ```
4. **Prove it in a scenario** under `test/scenarios/`: a `setup.sh` that installs it and an
   `expected.json` that puts it in `classified.must_find`. Under `classified.forbid`, list any
   agent the new rows could be mistaken for: Roo Code's extension id,
   `rooveterinaryinc.roo-cline`, contains Cline's name. Add the scenario to the matrix in
   `.github/workflows/scenarios.yml`.
5. **Regenerate and check**:
   ```console
   $ python3 osquery/tools/build.py          # osquery/dist/
   $ python3 tools/agent_status.py --write   # docs/agents.md, docs/limits.md, the README badge
   $ tools/gates.sh
   ```
   Lint fails while a generated page is stale, so regenerate in the same commit. If the agent
   or identifier totals in README's prose changed, edit them; `tools/check_doc_numbers.py`
   names the line.
6. **Open a pull request.** CI runs the scenarios the diff can move.

`tools/validate_catalog.py` refuses an agent no scenario installs, with no way to record an
exception. If no scenario can install yours, it is not an identifier yet: say so in
[`docs/blind-spots.yaml`](docs/blind-spots.yaml). It is equally strict about the mistakes that
fail silently: a duplicate id, an unknown classification, an entry with no route, and one value
claimed by two agents.

**Removing an entry?** Leave its rows in the fixtures and assert they are declined, so *correctly
not an agent* stays distinguishable from *route quietly broken*.

**A vendor changed an identifier?** Keep the old one and add the new one; machines on the old
build still report it. When no installable build produces the old one, supersede it:
[the lifecycle](docs/signature-lifecycle.md#superseding).

### Recording the observation

Coverage is counted from what each run recorded in `test/scenarios/<name>/observed.json`, not
from what `expected.json` asserts. The `collect` job writes those files only on `main`, so a
pull request cannot move recorded coverage. **A pull request that adds an identifier's first
real install should commit the observation**, or the generated page calls it uncovered until
the merge lands:

```console
$ python3 tools/agent_status.py --record /tmp/out.json test/scenarios/<name> \
    --platform linux --os 24.04 --arch x86_64
```

A run proving fewer identifiers than the committed record is refused, because that is also what
a broken query looks like. `--allow-shrink` overrides it for an identifier genuinely removed.
When an identifier stops appearing, [the triage](docs/signature-lifecycle.md#triage-why-did-it-stop-appearing)
tells a wrong identifier from one that is no longer installable.

### The `images` route

A container image repository, collected only by `osquery/bin/discover --deep` and compared as
[SPEC.md §6.4.3](SPEC.md#643-exact-normalised) normalises it: tag removed, and no `docker.io/`
or `library/` on Docker Hub.

```yaml
  images: [paulgauthier/aider]        # Docker Hub
  images: ["ghcr.io/block/goose"]     # anywhere else, the registry host is part of it
```

- **Give the repository, never a tag.** `paulgauthier/aider:latest` would never match, and
  `tools/validate_catalog.py` rejects it.
- **Prefer the two-segment published name.** A local build is shaped like a Docker Hub library
  image, so a bare `aider` would claim anyone's `aider:latest`.
- **It is weaker evidence than other routes.** An image name is chosen by whoever ran
  `docker tag`. Say so when you rely on it.

Read the value off a real `docker_images` row, not off the registry. If Docker Hub pulls are
blocked daemon-side (`access token has insufficient scopes`; an isolated `DOCKER_CONFIG` will
not help), side-load the image:

1. Get an anonymous pull token from `auth.docker.io` and the index from
   `registry-1.docker.io`, and pick your architecture's manifest.
2. Download config and layers into `blobs/sha256/<digest>`, **verifying each blob's sha256**:
   a truncated layer loads and is wrong.
3. Write `oci-layout` (`{"imageLayoutVersion":"1.0.0"}`) and an `index.json` whose manifest
   carries `"io.containerd.image.name": "docker.io/<repo>:<tag>"`, which decides what
   `docker_images` reports.
4. `tar -cf - -C <dir> . | docker load`. This needs the containerd image store
   (`containerd-snapshotter=true` in `docker info`).

## Writing a query

The osquery binding's rules, and the traps that have already cost a day, are in
[`osquery/CLAUDE.md`](osquery/CLAUDE.md). The ones that break a build:

**Every branch emits six columns, in this order**, because everything composes into one
`UNION ALL` and a five-column branch breaks the whole query:

| column | meaning |
|---|---|
| `kind` | the row kind, which `catalog/routes.yaml` must declare or the row is dropped |
| `id` | the identifier: bundle id, package name, path |
| `ver` | the version, if statically readable |
| `loc` | where it lives on disk |
| `extra`, `perms` | kind-specific, documented in the header of the query that emits the kind |

Use `''` rather than `NULL` for a column a branch has nothing for: `NULL` propagates through
concatenation and empties the row.

**A scenario pins the kinds its platform's queries emit**, and `osquery/test/lint.sh` derives
which. The deep-only kinds (`image`, `container`, `ilabel`) are pinned only by a `deep: true`
scenario, `79-linux-image`. `scan` is pinned by every Linux scenario, because
`osquery/queries/runtime-linux.sql` emits a marker on every run: `systemd_units` fails soft, and
the marker is what tells *no agent units* from *could not read the unit list*.

**Frontmatter** on every query:

```sql
-- name: browser-extensions
-- description: Chrome/Brave/Edge extensions across every profile, with permissions
-- tables: users, chrome_extensions
-- min-osquery: 5.10.0
-- cost: fast          # fast | slow | expensive: osquery/tools/measure.py's BANDS
-- platform: darwin    # darwin | linux | posix
```

**A query must be fast in its worst state, not its typical one.** A `docker_images` branch cost
0.35s with no Docker installed and 10.4s with Docker installed but stopped, returning zero rows
either way. A clean test machine lacks the dependency, a socket `connect()`
succeeds while the read stalls, and a `200` on a health check says nothing about the next
request. Test anything that touches a daemon or socket **stopped and mid-startup**. A table with
no timeout of its own cannot go in a composed artifact: it goes in
`osquery/dist/discovery-deep.sql`, behind a runner that can kill it.

`osquery/tools/measure.py --check` fails the build when a query overruns its declared band, and
[`osquery/queries/COST.md`](osquery/queries/COST.md) has the measurements. Raise a band rather
than tuning the budget, and say why the cost is inherent.

## Running the tests

`tools/gates.sh` runs every fast gate and exits non-zero if any fails. Run it first. The gates
that need osquery measure the platform they run on:

```console
$ python3 osquery/test/test_match_sql.py   # the rendered SQL against bin/classify; SKIPs without osqueryi
$ osquery/tools/measure.py --check         # cost bands
$ sudo osquery/test/docker_states.sh       # every Docker daemon state, the guard and the bound
$ sudo python3 osquery/tools/check_pack.py # every pack query returns rows
```

Scenarios install real software, so each harness hosts one platform:

```console
$ test/run.sh 00-baseline               # macOS, in a disposable Tart VM (Apple Silicon)
$ test/run-linux.sh 70-linux-baseline   # Linux, in a disposable container; needs only Docker
$ LINUX_IMAGE=quay.io/rockylinux/rockylinux:9 test/run-linux.sh   # every scenario, another distro
$ test/run-gce.sh --family debian-12    # a real Compute Engine VM: systemd, OS Login; needs gcloud
$ test/run-ec2.sh --family al2023-arm64 # a real EC2 instance over SSM; needs the AWS CLI
```

A scenario a runner cannot host exits 3 and **skips**, with the reason, which is always a fact
about the runner: `76-linux-systemd` needs a system bus, `79-linux-image` a Docker daemon, the
deb and rpm scenarios their own package manager, and `75-linux-browser` x86_64, because Google
ships no arm64 Linux Chrome.

You do not need to run scenarios locally. **CI runs the ones a pull request's diff can move**,
on macOS and Linux, and all of them weekly. `tools/ci_scope.py` decides, and when it cannot tell
it runs every scenario; the scope job's summary says what ran and why. A `workflow_dispatch`
runs everything, or only the scenarios named in its `scenarios` input. A new identifier
over-matching rows in an unrelated scenario is the one thing scoping can miss, and the weekly
run catches it.

Assert on **counts and specific identifiers**, and on what must **not** match. Every defect
found here produced plausible output with the wrong number of rows, and none errored.

## Adding a binding

osquery is the first way to collect evidence, not the only one. A binding for an EDR's
inventory, an MDM's app list or another agent needs what
[SPEC.md §8](SPEC.md#8-bindings) requires:

- **its fields on each route it feeds**, beside osquery's in `catalog/routes.yaml`, declared in
  `tools/validate_catalog.py`'s `BINDINGS`, and a check, like `osquery/tools/build.py`'s, that
  they are true of its source;
- **rows that validate** against [`schema/evidence.schema.json`](schema/evidence.schema.json);
- **a scan marker for every source it could not read**;
- **its own proofs**: an identifier proved through osquery is not proved for a binding that
  reads a different source. `observed.json` does not yet record which binding produced an
  observation, so `tools/export.py` refuses to publish proof once a second binding exists.

A matcher written elsewhere is held to [`conformance/vectors.json`](conformance/vectors.json),
as `bin/classify` and the rendered SQL are.

## Versioning

Releases are [semantic](https://semver.org):

- **major**: the six-column contract or the authoring form (`catalog/agents.yaml`,
  `catalog/routes.yaml`) changes incompatibly, or the spec's major version moves. Consumers
  must change code.
- **minor**: a new query, agent or identifier, or a spec addition that leaves every existing
  result unchanged.
- **patch**: a corrected identifier, a fixed glob, documentation.

The spec has its own version, at the top of [`SPEC.md`](SPEC.md) and in a catalog document's
`format`, and it moves only when the normative text does ([§10](SPEC.md#10-versioning)). A
release that moves it says so in its notes.

Releases are cut when identifiers change, at most weekly, and each one's changes are on the
[Releases page](https://github.com/arthur-ai/ai-detection-spec/releases); there is no
`CHANGELOG.md`. Publishing a release runs [`release.yml`](.github/workflows/release.yml), which
builds what it attaches from the tag, so a deployment can pin a tag rather than track `main`.

## Reporting a detection gap

Open an issue with the *Detection gap* template for an agent we know and fail to find, or
*New AI agent* for one we do not know. A technique that deliberately evades detection goes to
[SECURITY.md](SECURITY.md) instead.

## Scope

The catalog says what software is present, not whether it is good, safe or permitted. Whether
an agent is acceptable is your judgement about your fleet.
