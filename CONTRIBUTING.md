# Contributing

The most valuable contribution is a **signature**: a new AI tool, or a correction to one we have
wrong. Second most valuable is a **detection gap** you can reproduce.

**First response within five working days.** That covers a maintainer actually running your
scenario, not just reading the diff.

## The one rule that breaks builds

Every query branch emits **six columns, in this order**:

| # | Column | Meaning |
|---|---|---|
| 1 | `kind` | Row type: `app`, `npm`, `brew`, `daemon`, `port`, `ext`, `file`, `nmh`, `model`, `image` |
| 2 | `id` | The identifier: bundle id, package name, port, path |
| 3 | `ver` | Version if statically readable, else `''` |
| 4 | `loc` | Where it lives on disk |
| 5 | `extra` | Kind-specific: `browser_type` for `ext`, process name for `port` |
| 6 | `perms` | Declared permissions, `ext` only |

Everything composes into one `UNION ALL`, so a branch emitting five columns breaks the whole
query. `test/lint.sh` catches it in about a second. Run it first.

Use `''` rather than `NULL` for a column a branch has nothing for. `NULL` propagates through
string concatenation and silently empties whole rows.

`image` is the one kind that is **not** in `dist/discovery.sql`. `containers.sql` is declared
`expensive`, so the build puts it in `dist/ai-discovery.conf` only, and the scenario matrix does
not exercise it — `KINDS` in `test/lint.sh` is the set every scenario must pin, and `image` is
deliberately absent from it. `test/docker_states.sh` covers that branch instead, against a fake
socket in every daemon state. Add a kind to both places when it belongs in the composed query;
add it here only when it does not.

## Adding a signature

1. Install the real thing on a Mac. Do not guess identifiers from vendor documentation.
2. Find how it actually presents:
   ```console
   $ osqueryi "SELECT bundle_identifier, bundle_short_version, path FROM apps WHERE path LIKE '%Thing%'"
   $ plutil -extract CFBundleIdentifier raw /Applications/Thing.app/Contents/Info.plist
   ```
3. Add a test scenario under `test/scenarios/`, with a `setup.sh` that installs it and an
   `expected.json` that says what should be found.
4. Open a PR. CI checks the scenario is well-formed; the full run happens on a macOS runner.

**Check every install route.** A single tool often ships several ways, and each lands somewhere
different. OpenClaw ships as a Homebrew cask *and* an npm global *and* a `curl | bash` installer
that wraps npm. A fleet that standardised on one route is invisible to a signature written for
another.

**Keep old identifiers as aliases.** When a vendor changes a bundle id, machines that installed
the old version still carry it. Add the new one; do not delete the old.

## The catalog

Signatures live in `catalog/agents.yaml`, one entry per tool carrying **every route it
ships through**:

```yaml
- id: openclaw
  name: OpenClaw
  classification: Personal agent
  bundle_ids: [ai.openclaw.mac, bot.molt.mac]   # current, and a retained alias
  homebrew: [openclaw]
  npm: [openclaw, clawdbot, moltbot]
  state_dirs: ["~/.openclaw"]
  launchd_prefixes: [ai.openclaw.]
  ports: [18789]
```

`tools/validate_catalog.py` checks it and runs in CI. It is strict about the mistakes that
fail *silently*: a duplicate id produces double findings, an unknown classification renders
as a blank pill, an entry with no route can never match anything, and the same identifier
claimed by two agents means one is wrong and both will fire.

`classification` describes **deployment shape**, not risk. See the vocabulary at the top of
the file.

## Query frontmatter

```sql
-- name: browser-extensions
-- description: Chrome/Brave/Edge extensions across every profile, with permissions
-- tables: users, chrome_extensions
-- min-osquery: 5.10.0
-- cost: fast          # fast <1s | slow 1-5s | expensive >5s
-- platform: darwin
```

## Performance is a build gate

**A query must be fast in its worst state, not its typical one**, and CI enforces it.

The case that taught us: a `docker_images` branch cost 0.35s with no Docker installed and
**10.4s with Docker installed but stopped**, returning zero rows either way. That is the common
state on a developer Mac, and it took the whole query from 1.0s to 11.2s.

Two ways this hides:

- **A clean test machine lacks the dependency entirely**, so it never exercises the slow path.
- **A liveness probe that only `connect()`s to a socket reports success** while the query still
  stalls, because osquery blocks on the *read*. Only a full round trip distinguishes them.

If your query touches a daemon, socket or external service, test it **stopped and mid-startup**,
not just healthy.

`tools/measure.py --check` times every query against its declared band and fails the build on an
overrun, naming the query and its measured cost. It runs on every pull request. Measured numbers
for each query, and the machine they were taken on, are in [queries/COST.md](queries/COST.md).

```console
$ tools/measure.py             # time every query, print a table
$ tools/measure.py --check     # fail if any query exceeds its declared band
```

Raise a query's declared band rather than tuning the budget, and say in the PR why the cost is
inherent. A `slow` query is fine; an undeclared one is not.

## Running the tests

```console
$ test/lint.sh                 # static checks, about a second, no VM
$ tools/measure.py --check     # cost bands, needs osquery and a few seconds
$ test/docker_states.sh        # container query against every daemon state, ~15s
$ test/run.sh 00-baseline      # one scenario in a disposable macOS VM
```

Scenarios run on GitHub-hosted macOS runners in CI. Locally they use
[Tart](https://tart.run), which needs an Apple Silicon Mac and a base image of roughly 25GB.
You do not need to run them locally to contribute: push the branch and let CI do it.

Assertions are on **counts and specific identifiers**, never "did it parse". Every defect found
in this project so far produced plausible-looking output with the wrong number of rows, and not
one of them errored.

## Versioning

Releases are [semantic](https://semver.org), with repository-specific meaning:

- **major** — the six-column contract or the catalog schema changes. Consumers must change code.
- **minor** — a new query, or new signatures. Additive and safe to take.
- **patch** — a corrected identifier, a fixed glob, documentation.

Releases are cut whenever signatures change, at most weekly. What changed in each one is on the
[Releases page](https://github.com/arthur-ai/osquery-ai-discovery/releases) rather than in a file
in the tree; there is no `CHANGELOG.md`. Publishing a release triggers
[`release.yml`](.github/workflows/release.yml), which rebuilds `dist/discovery.sql` and
`dist/ai-discovery.conf` from the tagged `queries/` and attaches them — so a deployment can pin
a tag instead of tracking `main`, and what it downloads is derived from the tag rather than
uploaded by hand.

## Reporting a detection gap

If you know of an agent this misses, open an issue with the tool, how you installed it, and what
`queries/discovery.sql` returned. If disclosing it publicly would be unwise, see
[SECURITY.md](SECURITY.md).

## Scope

macOS only. The catalog describes **what software is present**, not whether it is good, safe or
permitted. Classifications like `Personal agent` describe deployment shape. Whether a given agent
is acceptable is your judgement about your fleet, not ours about a vendor.
