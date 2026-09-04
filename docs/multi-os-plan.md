# Multi-OS catalog schema + an importable classify module

> **SUPERSEDED FOR LINUX, AND TWO OF ITS FACTS WERE WRONG.** Steps 1-5 of this plan shipped,
> with corrections; the query-layer work it puts out of scope shipped alongside them. What
> remains open is Step 6 (the `aidiscovery` package) and Step 7 (`schema_version: 2`).
>
> The corrections matter more than the status, because this document's own closing section
> asked for them:
>
> - **`snap_packages` and `flatpak_packages` do not exist as osquery tables at any version.**
>   Checked against the source tree at 5.10.0 and 5.23.1 and confirmed live -- `SELECT * FROM
>   snap_packages` returns `[]` and exits 1. Both were listed here as Linux routes. That is
>   precisely the `bot.molt.mac` shape this plan warned about in *What this plan has NOT
>   verified*, and it is why that section was right to exist. `deb_packages`, `rpm_packages`
>   and `systemd_units` are all real and all present at 5.10.0.
> - **`home_pattern(value, platform)` cannot take a platform.** `bin/classify` reads payloads a
>   fleet collector may have merged from many hosts, so there is no single platform to pass; it
>   matches every platform's home roots at once, as one alternation.
> - **The `$` anchor is per route, not blanket.** Anchoring `state_dirs` fixes
>   `~/.claude` matching `.claudefoo`; anchoring `binaries` would break
>   `~/.local/bin/hermes` matching `hermes-acp` and `hermes-agent`, which
>   `catalog/agents.yaml` records as deliberate.
> - **`vscode_extensions` exists** from osquery 5.11.0, which retired a blind spot rather than
>   adding one. Its identifier is the `name` column alone: `publisher_id` is a GUID, so the
>   obvious `publisher_id || '.' || name` yields something that matches nothing.
>
> `docs/blind-spots.yaml`, `catalog/routes.yaml` and `queries/*.sql` carry the current facts.

## Context

`osquery-ai-discovery` ships macOS-only. Every query declares `-- platform: darwin`, every
catalog route is macOS-shaped (`bundle_ids`, `homebrew`, `launchd_prefixes`), and `README.md:63-67`
records the intent — "**Windows and Linux are coming** — no code yet, and no date."

This plan takes three steps toward that, deliberately not the whole port:

1. **Model the catalog schema for Linux + Windows + macOS**, so a signature can be written for
   any of the three and every tool can tell which platform an identifier belongs to.
2. **Capture vendor, product and version** as data — the catalog records none of the three today.
3. **Extract `bin/classify` into an importable module with a versioned output contract**, so MDM
   glue and other teams consume a stable structure instead of parsing a CLI's stdout.

The query-layer port is **out of scope** — see *Not in scope* at the end for what it involves and
why it is the larger job.

## Decisions taken

| Decision | Choice |
|---|---|
| First-class platforms | `darwin`, `linux`, `windows` |
| Catalog shape | **Route name implies platform.** Routes stay flat; a per-agent `platforms:` list declares where the agent is expected |
| Schema vs data | **Per-OS schema, one catalog.** Route definitions are platform-scoped and strict; agent identity stays in one file |
| Output shape | **Uniform on every platform.** `platform` is a field value, never part of the structure |
| Vendor/product/version | Industry-standard coordinates: vendor + product in the catalog, version emitted from evidence at match time |
| Coverage gate | **Per-platform counting.** The gate demands CI coverage only for platforms CI runs, and names the rest |
| Module | In-repo package; `bin/classify` becomes a thin CLI wrapper |
| Output | Versioned `schema_version` with a documented compatibility rule |

Nested-per-platform and split-per-OS-file catalog layouts were both rejected: nesting rewrites all
16 entries and duplicates the genuinely portable routes (`npm`, `pypi`, `images`,
`extension_ids`), and per-OS files spread one agent's identity across four. Flat routes keep all
45 existing identifiers valid unedited and match `docs/signature-lifecycle.md`'s mandate that the
matcher's input stays flat.

## Verified constraints

Read off the tree, not assumed. Each has bitten this repo or is one line from doing so.

**A new route must be registered in two places or its rows are dropped.**
`catalog/agents.yaml:3-6` names them: `validate_catalog.py`'s `ROUTES` and `bin/classify`'s
`KIND_ROUTES`. A kind absent from `KIND_ROUTES` is **dropped, not unmatched** — invisible even
under `--show-unmatched` (`bin/classify:181-188`). `ext` sat like that from the beginning.
*Step 1 below removes this trap at the root rather than adding a third list to keep in sync.*

**`~/` expands to a hardcoded `/Users/[^/]+/` in three places** — `bin/classify:58`,
`bin/classify:178` (`TOOL_DIR`), `tools/agent_status.py:118`. The catalog convention looks
portable; the matcher is not.

**`test/lint.sh:92-137` requires every kind in `KINDS` to be pinned by *every* scenario.** All 13
`expected.json` pin exactly the current 8 — zero slack. Adding a Linux kind fails all 13.

**`bin/classify` ships as a standalone release artifact** (`release.yml:86`,
`.claude/skills/release/SKILL.md:180`).

**`--gate` demands CI coverage for every identifier and CI is macOS-only**
(`scenarios.yml:38` matrix is `[macos-15, macos-14]`).

**`tools/check_no_catalog.py` forbids product identifiers in SQL**, so new-platform literals must
live in the catalog. Its npm-scope and reverse-DNS rules would **not** catch a Windows registry
path or a `.desktop` id — only the brand regex would. Extend it when Windows routes land.

**`docs/agents.md` is 100% generated**; `--check` fails when stale; README carries a generated
badge. Any schema change moves both.

**`catalog/agents.yaml:75` carries `version: 1` that no code reads** — verified by grep across
`bin/`, `tools/`, `test/`. A version field with no enforcement, which this plan makes
load-bearing rather than leaving a second number to disagree with `schema_version`.

**Python 3.7** (`README.md:82`), stdlib-only except PyYAML, `load_catalog` imports yaml lazily so
`image_repo()` works without it. No `actions/setup-python` — CI uses the system python3.

---

## Step 1 — `catalog/routes.yaml`: one declared route registry

The single highest-value change, and it goes first because everything else reads it.

Today the route vocabulary is spread across four hardcoded copies that must agree:
`validate_catalog.py:18-22` (`ROUTES`), `bin/classify:129-163` (`KIND_ROUTES`),
`agent_status.py:47-49` (`EXACT_KINDS`, `GLOB_ROUTES`), and `test/lint.sh:111` (`KINDS`).
Drift between them is *the* recurring bug class in this repo. Replace them with one file that all
four read:

```yaml
# catalog/routes.yaml -- the route registry. Adding a route here is the ONLY edit needed;
# the matcher, the validator, the coverage report and lint all read it. This file exists
# because the same vocabulary used to live in four hardcoded lists, and `ext` was missing
# from one of them since the beginning -- rows DROPPED, not unmatched.
version: 1
platforms: [darwin, linux, windows]      # the validated vocabulary

routes:
  bundle_ids:
    platform: darwin
    kind: app                 # the row kind that carries it
    match: exact
    table: apps
    version: bundle_short_version   # what `ver` holds on this route
    purl: null                # no PURL type for a macOS bundle
    # Reverse-DNS, and case-SENSITIVE by necessity: com.kagi.kagimacOS is a real shipped
    # identifier. A lowercase-only pattern rejects it -- verified by running the pattern
    # against all 10 bundle_ids in the catalog before writing it down.
    value_pattern: '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$'
  homebrew:
    platform: darwin
    kind: brew
    match: exact
    table: homebrew_packages
    version: package
    purl: brew
  launchd_prefixes:
    platform: darwin
    kind: daemon
    match: prefix
    table: launchd
    version: none
  npm:
    platform: any
    kind: npm
    match: exact
    table: npm_packages
    version: package
    purl: npm
  pypi:
    platform: any
    kind: file                # reached via TOOL_DIR, not python_packages (15.6s, no push-down)
    match: exact
    version: none
    purl: pypi
  extension_ids:
    platform: any             # Chromium ids are key-derived; identical on every OS
    kind: ext
    match: exact
    table: chrome_extensions
    version: extension
    value_pattern: '^[a-p]{32}$'
  native_messaging_hosts:
    platform: any             # the VALUE is a portable filename; the directory is per-OS
    kind: nmh
    match: exact
    table: file
    version: none
  images:
    platform: any
    kind: image
    match: exact-normalised
    table: docker_images
    version: tag              # NOT a version, and attacker-choosable -- see below
    purl: docker
  state_dirs:   {platform: any, kind: file, match: home-glob, version: none}
  binaries:     {platform: any, kind: file, match: home-glob, version: none}
  model_stores: {platform: any, kind: file, match: home-glob, version: none}

  # --- new: linux ---
  deb_packages:     {platform: linux, kind: deb,    match: exact,  table: deb_packages,     version: package, purl: deb}
  rpm_packages:     {platform: linux, kind: rpm,    match: exact,  table: rpm_packages,     version: package, purl: rpm}
  snap_packages:    {platform: linux, kind: snap,   match: exact,  table: snap_packages,    version: package}
  flatpak_packages: {platform: linux, kind: flatpak,match: exact,  table: flatpak_packages, version: package}
  systemd_units:    {platform: linux, kind: unit,   match: prefix, table: systemd_units,    version: none}

  # --- new: windows ---
  programs:            {platform: windows, kind: prog,  match: exact, table: programs,            version: package}
  chocolatey_packages: {platform: windows, kind: choco, match: exact, table: chocolatey_packages, version: package, purl: chocolatey}
  appx_packages:       {platform: windows, kind: appx,  match: exact, table: appx_packages,       version: package}
```

**Routes deliberately NOT added, and why.** `ports` was retired for being "a second opinion from
the same witness" — it only fires once something else has already named the agent. Two candidates
have the same defect and must not be added on detection grounds:

- **Windows `services`** and **Run-key/`startup_items`**: the value is a display name or a command
  line chosen by the installer. Where it names the agent, a package route already found it; where
  it does not, it identifies nothing. Same witness.
- **`systemd_units`** is included only as a `prefix` route on the unit *name*, which a vendor
  controls the way a launchd label is controlled. If the first Linux install shows unit names are
  user-chosen, drop it — do not keep it because it was easy to add.

`match: home-glob` is the new name for the three path routes, replacing the implicit
"anything starting `~/`" convention with a declared match mode.

`value_pattern` is what makes this a **per-OS schema without a per-OS catalog**. Today
`validate_catalog.py` hardcodes the `[a-p]{32}` extension-id rule and the `~/` path rule as
special-case branches; moving them into the registry means a new Windows route arrives carrying
its own validation instead of needing a new branch in the validator. Each platform's routes get
to be as strict as that platform allows.

**Files changed:** new `catalog/routes.yaml`; `validate_catalog.py` (delete `ROUTES` and the
per-route special cases, load the file); `bin/classify` (delete `KIND_ROUTES`, derive
kind→routes); `agent_status.py` (delete `EXACT_KINDS`/`GLOB_ROUTES`); `test/lint.sh` (derive
`KINDS`).

### Why one catalog, but a per-OS schema

The question of a separate schema *and* catalog per OS is worth recording, because the two halves
have different answers.

**Per-OS schema: yes**, and `value_pattern` above is how. A single merged schema can only validate
the union of every platform's routes, which forces every field optional and weakens the validator
to "at least one route present". A platform-scoped route definition can be strict.

**Per-OS catalog data: no**, for three reasons that are specific to this repo rather than general
taste:

- **Agent identity is OS-independent and must not be duplicated.** Cursor is one product with one
  vendor, one product slug, one classification, one set of retired aliases. Split across three
  files, those fields are either duplicated — and drift, so `vendor` reads `Anysphere` in one file
  and `Cursor` in another — or they move to a fourth shared file, at which point every
  contribution asks which of four files it belongs in.
- **The portable routes have no natural home.** `npm: ["@anthropic-ai/claude-code"]` is one
  identifier valid on all three platforms. Repeating it per file breaks
  `validate_catalog.py:84-91`'s global `(route, value)` uniqueness check — the check that exists
  because "the same identifier claimed by two agents means one of them is wrong, and both will
  fire." Relaxing it to accommodate the layout trades a real correctness guard for a filing
  convention.
- **The repo's own scaling axis is per-agent, not per-OS.** `docs/signature-lifecycle.md:255-260`
  mandates a split to `catalog/agents/<id>.yaml` past roughly a hundred agents, precisely so a
  contribution is a single-file diff. That delivers the ownership benefit of splitting — a Linux
  contributor touches one file — **without** fragmenting one agent across three. At 16 agents,
  neither split has earned its place yet.

**When per-OS catalogs would be right:** separate teams owning each platform on separate release
cadences, or a few hundred entries per platform. Neither is true today; revisit at the per-agent
split, not before.

---

## Step 2 — per-agent schema: `platforms`, `vendor`, `product`

```yaml
- id: cursor
  name: Cursor
  vendor: Anysphere            # NEW -- who publishes it
  product: cursor              # NEW -- canonical product slug
  classification: Coding agent
  platforms: [darwin, linux, windows]
  bundle_ids: [com.todesktop.230313mzl4w4u92]
  deb_packages: [cursor]
  programs: ["Cursor"]
  npm: [cursor-cli]
  state_dirs: ["~/.cursor"]
```

**`platforms:` is required, not optional.** On a multi-OS catalog an absent list is ambiguous
between "macOS only" and "nobody said", and this repo does not ship that ambiguity. Editing all 16
entries is mechanical and is a one-time honest declaration.

Validator rules:

| Rule | Why |
|---|---|
| every value ∈ `routes.yaml`'s `platforms` | a typo like `macos` must not pass |
| every declared route's platform ∈ the agent's `platforms` | declares `deb_packages` but not `linux` → copy-paste error |
| every declared platform has ≥1 route that can match there | otherwise the catalog claims "Cursor runs on Windows" and nothing can find it — a silent gap wearing a confident face |

That third rule needs an escape hatch, and one already exists: an agent that genuinely runs on a
platform we cannot yet detect is a **detection gap**, and `docs/blind-spots.yaml` already records
those and already renders into `docs/agents.md` as "What osquery cannot see" (14 rows today). Use
it. No new machinery, and the gap lands on the generated page instead of in a validator exemption.

### Vendor and product — the industry-standard reading

The user asked to conform to what major vendors practise. That standard is **CPE** (NIST, for
vendor:product:version triples, which is how NVD matches vulnerabilities) and **PURL** (for
package-manager coordinates, which is what SBOM/OSV tooling consumes).
`docs/signature-lifecycle.md:26-28` already observes "our identifiers are already PURL-shaped".

The important finding: **the standard separates the three, and in doing so it vindicates the
existing decision rather than overturning it.**

| Coordinate part | Where the standard puts it | Where it goes here |
|---|---|---|
| vendor, product | stable product identity | `catalog/agents.yaml` — new fields |
| version | a property of an **observed artifact** | the row's `ver`, emitted at match time |
| version *ranges* | the advisory's `configurations`, never the product dictionary | nowhere — not modelled |

So `docs/signature-lifecycle.md:129-143`'s rejection of version-keyed identifiers stands, and now
has an external justification to cite: NVD does not put applicability ranges in the CPE
dictionary either. **No document needs rewriting.** What the catalog captures is vendor, product,
and *what each route's version means*; what the output emits is a complete coordinate.

**`cpe:` is optional, and must never be invented.** A CPE that NVD does not recognise looks
authoritative and matches nothing — the `bot.molt.mac` failure in a new coordinate system, and it
would fail inside someone else's vulnerability pipeline where nobody here can see it. Ship a
`cpe:` only when read from the NVD dictionary; otherwise omit it and let the PURL stand alone. Add
this as a validator rule: `cpe:` must parse as `cpe:2.3:` and carry a `raised` date the way
`unverified:` does.

**Two real complications in the existing 16 entries, both of which prove vendor must be declared
rather than derived:**

- **ToDesktop-packaged apps.** `com.todesktop.230313mzl4w4u92` is Cursor's bundle id, and
  `todesktop` is the *packager*, not the vendor. A reverse-DNS prefix cannot be trusted to yield
  vendor. Record the discrepancy in a comment beside the entry, house style.
- **OpenClaw's rename.** `bot.molt.*` → `ai.openclaw.*` means vendor and product are not stable
  across an agent's life. `vendor`/`product` describe the **current** product; the retired aliases
  keep working through `retired:` exactly as now.

### Version semantics — the part that is genuinely catalog-shaped

`ver` means something different on every route and is often absent, and nothing in the tree says
so today. `routes.yaml`'s `version:` key above is the fix, with a closed vocabulary:

| value | meaning |
|---|---|
| `package` | a package-manager version — the trustworthy case |
| `bundle_short_version` | `CFBundleShortVersionString`; marketing version, not the build |
| `extension` | a Chrome extension version; one row per version left on disk |
| `tag` | **not a version.** An image tag list, and `docker tag` makes it attacker-choosable — the catalog header already records this |
| `none` | this route carries no version at all (every `home-glob` route) |

A consumer reading `ver` across findings today cannot tell which of those it holds. After this
change, every evidence row says.

---

## Step 3 — `~/` resolution per platform

The catalog value stays portable and unedited; the **matcher** learns the roots. This is where the
three hardcoded `/Users/[^/]+/` copies collapse into one exported helper.

```python
HOME_ROOTS = {
    "darwin":  [r"/Users/[^/]+/"],
    "linux":   [r"/home/[^/]+/", r"/root/"],       # root's home is not under /home
    "windows": [r"C:/Users/[^/]+/"],               # after separator normalisation
}
```

- **Windows separators**: normalise `\` → `/` on the row side before matching, once, at the edge.
  Do not teach every pattern both separators.
- **`%APPDATA%` / `%LOCALAPPDATA%`** cannot be expressed as `~/`. Rather than a new route, extend
  the path convention with two prefixes the matcher expands per platform —
  `%APPDATA%/Cursor` → `C:/Users/<u>/AppData/Roaming/Cursor`. Justified because it keeps one path
  vocabulary; a separate route would double every path route and the validator's
  `startswith("~/")` rule already shows how cheaply a prefix convention validates.
- **Add the missing `$` anchor.** Today `~/.claude` also matches `/Users/x/.claudefoo` — the glob
  is front-anchored only (`bin/classify:58`). Fix it with the rewrite, and assert the near-miss in
  `test_matcher.py`, since this is exactly the "must NOT match" shape the repo requires.

---

## Step 4 — per-platform coverage

Chosen over a large `untested:` list, because that list "may shrink silently and never grow
silently" and 12+ new entries would turn a work list into an excuse list.

- Route → platform now comes from `routes.yaml`, so every identifier has a platform for free.
- `observed.json` already records `os`/`arch` and merges per `(os, arch)`
  (`agent_status.py:181-189`). Add a `platform` field beside `os` — today `os` holds `14.8.7`,
  which identifies a macOS version but not a platform family.
- `ci_platforms()` derives which platforms CI actually runs from `scenarios.yml`'s matrix.
- New identifier state **`no-ci-platform`**: its platform is not in CI's matrix. Counted and
  named, never silently excused.
- `--gate` fails when an identifier's platform **is** in the CI matrix and it is uncovered. It
  does not fail for `no-ci-platform`.
- `badge_for()` becomes per-platform, and the report always prints the breakdown:
  `darwin 43/43 · linux 0/12 (no CI) · windows 0/8 (no CI)`.

**The trap to guard:** `no-ci-platform` is a new place a guess could hide. Two defences —
the per-platform breakdown is on the generated front page where an embarrassing zero is visible,
and the gate still fails the moment Linux enters the CI matrix with identifiers uncovered. Write
both into the comment above the state machine.

---

## Step 5 — the `kind` vocabulary, without editing 13 scenarios

`test/lint.sh:111`'s `KINDS` is pinned by every scenario with zero slack, so adding `deb` or
`prog` fails all 13 macOS scenarios. Fix: **scope kinds by platform.**

- Derive `KINDS` from `routes.yaml` (`kind` + `platform` per route).
- Each scenario declares its platform in `requires.json`; a scenario pins only the kinds whose
  route platform is `any` or its own. macOS scenarios keep pinning the same 8 — **no churn.**
- Generalise `requires.json` from `{min_macos, why}` to `{platform, min_os, why}`. Only two files
  use it (`11-perplexity-desktop`, `50-autonomous`), so migrate rather than dual-read.
- `image` and `scan` stay excluded with their existing argued comments.

---

## Step 6 — the `aidiscovery` package

```
aidiscovery/
  __init__.py   # public API re-exports, SCHEMA_VERSION
  catalog.py    # load agents.yaml + routes.yaml; the route registry
  match.py      # Index, image_repo/repos, TOOL_DIR, home roots, classify()
  report.py     # the versioned document + the human renderer
```

Four files, arguing against finer granularity: load → match → render is the real seam, and it is
the seam the multi-OS work needs (route registry in `catalog`, home roots in `match`).
`bin/classify`'s docstring calls it "the reference implementation of matching… deliberately small
and meant to be read", and that property must survive the split.

### The release-artifact tension

`bin/classify` ships as a standalone download. **Recommendation: ship the package directory
beside it**, and have `bin/classify` add its own parent to `sys.path` and fail loudly with a
readable message if `aidiscovery/` is missing.

- *Rejected — generate a stitched single file* (the `tools/build.py --check` pattern, which does
  exist here for `dist/`). It preserves the one-file download, but what ships stops being what a
  reader can read, and stitching Python has import-order pitfalls concatenating SQL does not.
- *Rejected — `zipapp`* (stdlib, would give one executable file from the package). Elegant, but a
  `.pyz` is opaque to the reader who wants to try `image_repo()`, which `.gitignore:12-14` records
  as a real use.

Edit `release.yml:86` and `.claude/skills/release/SKILL.md:180` together — they name the same set
and will disagree otherwise.

### Public API

```python
Index.build(catalog, routes) -> Index        # built ONCE, reusable across payloads
classify(rows, index) -> Result              # .findings .unmatched .gaps .scans
report(result, *, show_unmatched, now) -> dict
image_repo(tag) / image_repos(tags)
home_pattern(value, platform)                # the exported helper
SCHEMA_VERSION
```

Three current warts fixed by the signatures alone: `build_index` is no longer rebuilt on every
`classify()` call; `now` is injected so `report()` stops calling `time.time()` three times per
scan row and two rows can no longer straddle a second boundary; and `home_pattern` collapses the
duplicate glob construction at `agent_status.py:118`, which carries a comment claiming the two
"cannot disagree" while being a hand copy.

Dataclasses for `Result`/`Finding` (3.7 has them); the JSON document stays plain dicts built in
`report()`, so the conditional-emission rules live in one readable place. Keep `load_catalog`'s
lazy `yaml` import so `image_repo()` still works without PyYAML. Delete the unused `import os`.

---

## Step 7 — the versioned output contract

`schema_version: 2`. Version 1 is today's implicit shape, named retrospectively in the doc.

```json
{
  "schema_version": 2,
  "catalog_version": 2,
  "generated_at": 1757000000,
  "findings": [{
    "id": "cursor", "name": "Cursor", "classification": "Coding agent",
    "vendor": "Anysphere", "product": "cursor",
    "platforms": ["darwin", "linux", "windows"],
    "evidence": [{
      "kind": "app", "id": "com.todesktop.230313mzl4w4u92", "ver": "1.7.3",
      "loc": "/Applications/Cursor.app", "extra": "", "perms": "",
      "route": "bundle_ids", "platform": "darwin",
      "version_semantics": "bundle_short_version",
      "purl": null
    }]
  }],
  "gaps": [{"id": "containers", "reason": "timeout", "detail": "30",
            "loc": "/var/run/docker.sock", "message": "…"}],
  "scans": [{"id": "containers", "at": 0, "age_seconds": 0, "stale": false}]
}
```

What is new and why each is machine-friendly rather than decorative:

- **`route` + `platform` per evidence row.** Today a consumer cannot tell which signature fired.
- **`version_semantics`.** The vendor/product/version requirement, honest per route.
- **`purl`** where the route has a type; **`cpe`** only where a real one is declared.
- **`gaps` parsed into `{reason, detail}`** instead of a `timeout:30` string consumers
  substring-match. This closes two live gaps: `bin/classify:336-348` does not know the `error`
  reason that `bin/discover:189,198` really emits (it renders as
  `COULD NOT LOOK: apps -- the socket reported 'error'`, with "the socket" wrongly substituted
  because non-container branches write `loc: ""`), and `stale:<n>` is documented in `CLAUDE.md`,
  `docs/deployment.md` and checked by `ci.yml` while **being emitted by nothing**. Decide
  explicitly: emit it or delete it from all three.

### One output schema, on every platform

This is a hard requirement, not a consequence of the catalog layout, and it holds whatever the
catalog does later:

- **`platform` is a field *value*, never part of the document's *structure*.** No `darwin_findings`
  key, no per-OS envelope, no key that appears on one platform and not another. A client parses
  one shape and switches on data.
- **A macOS-only fleet and a mixed fleet produce the same document shape** — the same keys in the
  same nesting, differing only in values. A client written against a Mac fleet keeps working when
  Linux endpoints start reporting.
- **Route and platform names come from `routes.yaml`**, so the output's vocabulary is the
  registry's vocabulary and cannot drift from what the matcher used.
- `version_semantics` is what lets one uniform schema carry genuinely different version meanings
  without the client guessing per platform — the alternative to a uniform schema is a client that
  knows a macOS `ver` differs from a Debian one, which is exactly the knowledge this field moves
  out of the client.

This is also the second argument against per-OS catalogs: the more the input fragments, the more
reassembly `report()` does to present one identity, and reassembly is where drift surfaces as a
client-visible bug.

**Conditional emission is preserved exactly** — `unmatched` only under the flag (even when empty),
`gaps` only when non-empty and never behind a flag, `scans` only when non-empty. These are
load-bearing, not incidental. `schema_version` is the one unconditional addition.

**Compatibility rule** (document in `docs/output-contract.md`): adding a key or a new enum member
is additive and keeps the major; removing a key, retyping one, or changing what a key *means*
bumps it. Conditional-emission rules are part of the contract — making `gaps` unconditional would
be a bump, because a consumer treating `[]` as "no gaps" would then be wrong.

**Version skew.** A downloaded `bin/classify` may meet an older or newer `catalog/agents.yaml`.
Validate the catalog's `version` against what the matcher understands; if newer, **warn on stderr
and match what it can**. Refusing to run would turn a skew into "no agents found" — the one error
this repo exists to avoid. `catalog_version` in the output makes the pairing visible downstream.
This is also what makes `agents.yaml`'s dormant `version: 1` load-bearing at last; bump it to `2`.

---

## Verification

```console
$ test/lint.sh                          # contract, first-arm aliases, kind coverage, AST check
$ python3 tools/build.py --check
$ python3 tools/validate_catalog.py     # new: routes.yaml, platforms, vendor/product, cpe
$ python3 tools/check_no_catalog.py
$ python3 test/test_matcher.py
$ python3 test/test_schema.py           # NEW -- the output contract
$ python3 tools/agent_status.py --gate  # now per-platform
$ python3 tools/agent_status.py --check
$ sudo test/docker_states.sh            # ~31s, unchanged
$ sudo python3 tools/check_pack.py      # must now filter by platform
```

`test/test_schema.py` asserts a golden document against a fixture payload and fails when the shape
moves without `SCHEMA_VERSION` moving with it.

**Break it to prove it** — per the repo's rule that a test which stays green when you delete the
code proves nothing:

| Break | Must turn red |
|---|---|
| delete a key from `report()` | `test_schema.py` |
| add a route to `routes.yaml` with no `kind` | `validate_catalog.py` |
| remove `linux` from an agent that declares `deb_packages` | `validate_catalog.py` |
| point a `home-glob` at `~/.claudefoo` | `test_matcher.py` near-miss assertion |
| drop `aidiscovery/**` from `docs.yml`'s path trigger | doc regeneration stops firing — **nothing catches this**, so add a `check_workflows.py` rule |

That last row is the trap worth naming: a stale path trigger fails by going quiet, which is this
repo's signature failure mode. `tools/check_workflows.py` already exists to assert workflow facts.

## Migration, one line each

| Consumer | Change |
|---|---|
| `tools/agent_status.py:39-42` | `sys.path` + `import aidiscovery` instead of `SourceFileLoader`; delete the `:118` duplicate; take route→platform from `routes.yaml`; record `platform` |
| `test/test_matcher.py` | keeps subprocessing (it asserts the CLI too); add `schema_version` assertions |
| `test/lib/assert.sh`, `test/docker_states.sh` | unchanged — stdin + `--json` still work |
| `.github/workflows/ci.yml:150-156` | unchanged — positional arg and text output preserved |
| `.github/workflows/docs.yml:23` | **add `aidiscovery/**`** or doc regeneration silently stops |
| `release.yml:86` + `release/SKILL.md:180` | ship `aidiscovery/`; edit both together |
| `test/lint.sh:193-234` | extend the AST glob past `*/*.py` to cover `aidiscovery/*.py` |
| `.gitignore:12-14` | the comment describes `bin/classify` importability; update it |
| `tools/build.py:158` | **validate the frontmatter `platform` value** against `routes.yaml`'s vocabulary — today a typo like `macos` yields a query osqueryd silently never schedules |
| `tools/check_pack.py:33-47` | filter by `platform` or it fails on any cross-platform pack |
| `CONTRIBUTING.md:15` | still lists retired `model` as a valid kind and omits `scan`; derive the table from `routes.yaml` |

## What this plan has NOT verified

Recorded here rather than left implicit, because this repo's standing rule is that a catalog may
carry a guess but may not hide one — and the same standard applies to a plan.

**The eight new osquery table names are unverified.** `deb_packages`, `rpm_packages`,
`snap_packages`, `flatpak_packages`, `systemd_units`, `programs`, `chocolatey_packages`,
`appx_packages` were written from knowledge, not read off a running osquery. They **cannot** be
verified from a Mac: `SELECT name FROM osquery_registry WHERE registry='table'` on this machine
returns only the platform's own tables — `apps`, `chrome_extensions`, `docker_images`,
`homebrew_packages`, `launchd`, `npm_packages`. This is precisely the `bot.molt.mac` failure
shape: a name from documentation that matched nothing on any real machine.

`appx_packages` is the one I would bet against — Windows app inventory may only be reachable
through `programs`. `systemd_units` and `flatpak_packages` are the next least certain.

**First task before executing Step 1:** confirm each name and its `min-osquery` version against a
running osquery on each platform, or against the osquery schema for the pinned version. Every
query file carries `-- min-osquery:` frontmatter and none of these versions has been established.
A route whose table does not exist produces no rows, and a composed query naming a missing table
**returns `[\n\n]` and exits non-zero** — which happened during this very check when I queried a
non-existent `osquery_tables`: five bytes of valid, empty, entirely plausible JSON.

**The PURL type names need checking.** `deb`, `rpm`, `docker`, `npm`, `pypi` are official PURL
types. **`brew` and `chocolatey` are not** on the official list — they are candidate/other types.
A plan claiming industry-standard conformance should not ship a coordinate whose type an SBOM
consumer will reject; either confirm them against the PURL type spec or emit no `purl` for those
routes and let the CPE-style vendor/product stand alone.

**No adversarial review.** Both design subagents died on API 529s, so this design was written and
reviewed by the same author. Three decisions specifically deserve a second opinion before
execution: whether `catalog/routes.yaml` is over-engineering for a repo that prizes a small
readable reference implementation; whether `platforms:` should be required (16 mechanical edits)
or default to `[darwin]`; and whether the four-file package split beats staying single-file.

## Not in scope

The query layer, which is the larger job and independently riskier:

- **`dist/discovery.sql` is fundamentally single-platform.** Fed to Linux `osqueryi` it fails on
  `FROM apps` and returns `0 rows, exit 1, "[\n\n]"` — five bytes of valid empty JSON, this
  repo's canonical failure. Per-platform composed artifacts need new naming, new `--check`
  semantics, and a change to `bin/discover:36`'s hardcoded `BASE`.
- **The pack already supports this today.** `dist/ai-discovery.conf` carries a per-query
  `platform` osqueryd honours, and `tools/build.py:158` copies whatever frontmatter declares — so
  a mixed pack needs no build change, only new query files.
- `apps.sql` has no cross-OS analogue; `launchd` → `systemd_units`/`services`;
  `homebrew_packages` → `deb`/`rpm`/`chocolatey`.
- **The test harness is Tart/macOS end to end** (`test/lib/vm.sh`), every `setup.sh` is
  `#!/bin/zsh` sourcing a Homebrew bootstrap, and `bin/` is Bash 3.2 with macOS `osqueryi` and
  Docker Desktop socket paths. **Windows is a parallel PowerShell implementation, not a port** —
  there is no bash.

Landing Steps 1–7 first means that work arrives against a schema that can already express it.
