# The osquery binding

The queries, the artifacts composed and rendered from them, the two endpoint scripts and the
bundle. The repo-wide rules in [`../CLAUDE.md`](../CLAUDE.md) apply here too, starting with the
one rule: an empty result must never be indistinguishable from a clean machine.

**Paths in this directory are relative to `osquery/`** — `bin/`, `dist/`, `queries/`, `tools/`,
`test/` — because `bin/discover` resolves `dist/` against its own parent, in the repo and in the
release layout alike. `catalog/`, `bin/classify`, `test/scenarios/` and `docs/` are the
repository root's.

## Architecture

The endpoint **enumerates**; the enumeration queries hold no catalog and do no filtering.
Matching happens off the machine, in `bin/classify`, against `catalog/agents.yaml`. That is
what lets a new signature re-match evidence already collected, and it is why
`tools/check_no_catalog.py` fails the build if an agent identifier leaks into those queries.

**The second way to match is on the endpoint, and it is a peer, not a fallback.**
`tools/render_match.py` renders the catalog into `dist/signatures.sql`,
`dist/agents-<platform>.sql` and `dist/fleet-policies.yml`: a Jamf Extension Attribute
(`bin/discover --names`), a Fleet policy, or `osqueryi` with a question gets agent names
straight from SQL. Docs present the two ways side by side; neither is "when you cannot do
the other". The rules that keep the rendered family honest:

- The signature rows come out of `bin/classify`'s own `build_index`, and the SQL matches
  the same six-column rows the classifier does, so agreement is structural. Where the
  classifier uses a regex, the SQL uses `regex_match` with the classifier's pattern.
- `test/test_match_sql.py` holds the two to the **same evidence rows, per row**, on every
  fixture, on controls that must and must not match, and in every scenario on the rows a
  real install produced. It needs `osqueryi` and SKIPs loudly without one; the CI runtime
  jobs run it with `--require-osqueryi`.
- A route whose match mode the renderer cannot express **fails the build**; a value two
  agents both claim fails the build. A join reports every signature a row satisfies and
  the classifier picks one, so those are the two ways they could disagree.
- `check_no_catalog.py` exempts those four files **by name** and requires each to carry
  identifiers; every other file in `dist/` is still held to the rule.
- `regex_match` returns NULL on a miss, an invalid pattern aborts the whole statement, and
  `LIKE` is case-insensitive — so the join is a `CASE`, every regex is compiled before it is
  written, and a prefix is `substr`.
- A signature added to the catalog reaches the rendered files only by redeploying them. The
  payload still re-matches. The bundle carries `signatures.sql` for `--names` and nothing
  else that names an agent.


**`bin/discover` MAY NOT ADD A DEPENDENCY, and neither may `bin/container-scan`.** That is a
rule about what you are allowed to type in them, and it is the second property of the same
boundary as telemetry. What they are permitted is closed:

| allowed | why |
|---|---|
| **bash 3.2** | what a managed Mac has, and the shebang both scripts declare |
| **`osqueryi`** | the dependency this repo already is. Resolved through `osqueryi_path`, which states its failure rather than assuming a PATH |
| **`curl`** | the Docker `/_ping` probe in `bin/container-scan`, and nothing else. Ships with macOS and every Linux base image we have run on; the repository's `docs/deployment.md` says why it is not written up as a prerequisite |
| **the POSIX utilities already in use** | read off the two files, not from memory: `cat`, `chmod`, `date`, `dirname`, `mkdir`, `mktemp`, `mv`, `rm`, `sed`, `sleep`, `uname`. That is the whole list |

Anything else is a new dependency, **including one that is obviously installed on the machine
you are testing on.** No interpreter — no `python`, `perl`, `ruby`, `node`. No `jq`: it does
not ship with macOS at all, and every use it would have is one `osqueryi` already covers. No
GNU-only flag on a utility in that list, because BSD `sed` and `date` are what a Mac has.

**`tools/bundle.py` widens that list by exactly two, and it is the only thing allowed to.**
The one-file bundle it emits extracts a `tar` from `base64` before `bin/discover` starts, so
a machine running a bundle needs those two on top of the table above. They are stock
everywhere this repo runs and the cost is opt-in — a consumer who unpacks `bin/` and `dist/`
themselves pays neither — but it is a widening rather than a detail, and it is written down
in the repository's `docs/deployment.md`, where a deployer will meet it. Nothing else may add to the list: the
wrapper ships to the same machines the runner does, and `test/lint.sh` holds it to the same
deny-list.

**`osqueryi` is the JSON parser, and the shell is the serializer.** That is the whole toolkit
and it is enough: `json_str`/`json_row` build a six-column row with `printf`; `osq_run`,
`json_concat` and `merge_sql` read documents with the same SQLite that wrote them. If you are
reaching for a tool, you are reaching past one of those.

It was not always true, and the cost of it not being true was not an error. On a managed Mac
`/usr/bin/python3` is a **stub** — no Command Line Tools, so it prints an install prompt on
stderr and exits 1 with empty stdout — and the `no-cache` row that exists to say the writer
never ran was built by the interpreter that stopped the writer. It printed nothing, and
nothing reads as a clean machine. **A marker row may not depend on anything that could be the
thing it is reporting**, and neither may the guard that decides whether to emit one.

`test/lint.sh` greps both files for a deny-list — `python`, `jq`, `perl`, `ruby`, `node`,
`deno`, `php` — excluding comments so the explanation does not fail its own check. **That gate
is narrower than this rule**: it catches what people actually reach for, not every command,
so a new dependency can pass lint and still be wrong. The reviewer is the enforcement for the
rest. `bin/classify` is deliberately outside all of this, for the same reason telemetry is: it
runs off the machine, where a missing interpreter is one operator's problem rather than a
fleet-wide condition.

**The composed artifact is per platform, and there is no unqualified one.**

| artifact | what it is |
|---|---|
| `dist/discovery-darwin.sql` | the composed `fast` + `slow` queries for macOS |
| `dist/discovery-linux.sql` | the same for Linux. **Not a superset of anything** — a different set of tables |
| `dist/discovery-deep.sql` | the `expensive` queries — a **supplement, not a superset**. One file, because every expensive query is `posix`; `build.py` fails loudly if one stops being |
| `dist/ai-discovery.conf` | the pack, carrying every platform's queries with osqueryd's own per-query `platform` field |
| `bin/container-scan` | not a query. The only supported way to run the deep artifact, because that artifact can block forever and the bound lives in the runner |
| `dist/signatures.sql` | **rendered from the catalog**, not composed from `queries/`: the signature table and the match, as a fragment over an `ev` CTE the caller supplies. `bin/discover --names` feeds it the payload |
| `dist/agents-darwin.sql`, `dist/agents-linux.sql` | the enumeration wrapped in that match: one row per agent found. **Never sees image-only agents** — the container branch needs the bound, so it is not in here, and the header says so |
| `dist/fleet-policies.yml` | one Fleet policy per agent per platform, passing when absent. Each wraps only the branches its agent's routes need |

**`dist/discovery.sql` is gone.** It named one platform while claiming none, and fed to the wrong
`osqueryi` it returns `[\n\n]` — five bytes of valid, empty, plausible JSON. It does at least
exit 1, which is the only reason that state is recoverable; `bin/discover` picks by `uname -s`.

A query declares `-- platform: darwin | linux | posix`, where `posix` means both and is
osqueryd's own word for it. The value is **checked** against `catalog/routes.yaml` now: it never
was, so `-- platform: macos` built clean and shipped a pack query osqueryd silently never
scheduled.

`dist/` is **generated**. Edit `queries/`, then `python3 tools/build.py`; `--check` gates it,
in both directions — a stale artifact and an artifact nothing generates are the same drift.
The rendered match files come from `catalog/` through `tools/render_match.py`, which needs
PyYAML; `build.py` runs it when PyYAML is present and says so when it is not, and
`render_match.py --check` is its own gate. `build.py` knows the rendered names only so its
unknown-file check can tell "rendered" from "nothing generates it".

## Traps that have already cost a day

- **`UNION ALL` takes its column names from the first arm only.** An unaliased first arm inherits
  whatever precedes it, and composition is per platform now — so which file leads an artifact
  depends on the platform, and a file can lead one artifact and sit mid-way through another.
  This shipped: the pack's browser query returned columns named `'ext'` and
  `permissions || CASE WHEN…`. `check_pack.py` counted rows and passed it; `lint.sh` counted
  columns and passed it. Both now check names. **Alias every first arm.**
- **`CROSS JOIN` is mandatory** for user-scoped tables. A plain `JOIN … USING (uid)` returns zero
  rows, silently — osquery needs the uid constraint pushed in.
- **A single `%` matches one path component.** `Application Support/Google/Chrome/…` is two.
- **`/root` is not under `/home`,** so a Linux path glob needs its own branch for it. A
  `%`-component cannot reach it, and an agent installed from a root shell is exactly what that
  silence would hide.
- **Some tables fail SOFT, which is worse than failing.** `systemd_units` with no reachable
  system bus logs to stderr, returns **zero rows**, and lets the statement exit 0 with every
  other row intact. Nothing downstream reads stderr, so a container or a locked-down host
  reports "no agent units" in the shape a clean host does. `queries/runtime-linux.sql` pairs it
  with a `kind=scan` marker computed in SQL, and the marker reasons from the unit **count** —
  socket presence alone reports `ok` against a bound-but-dead socket, which is Docker's `wedge`
  state again.
- **`deb_packages` reports packages nobody has installed.** dpkg keeps a `deinstall ok
  config-files` record, with the version, for anything removed without `--purge`. Filter on
  `status LIKE '%ok installed'` or an uninstalled agent reads as an installed one. Test it with
  a package that has conffiles: `cowsay` has none, so its record vanishes on remove and a broken
  query looks correct.
- **Bash 3.2** is what a managed Mac has. No `timeout(1)`, and an empty array under `set -u` is an
  unbound-variable error: append with `+=` and expand as `${a[@]+"${a[@]}"}`. A heredoc inside
  `$( )` is scanned for the closing paren *without* respecting its quoted delimiter, so one
  apostrophe in a comment swallows the `)` and the file stops parsing — and `python3 - <<'X'`
  reads the **script** from stdin, so a pipe into it is discarded in silence. `bash -n` catches
  the first. Nothing catches the second: every assertion simply reads as failed.
- **A parse failure prints `[\n\n]` too.** Fed malformed JSON, `osqueryi` writes
  `Error: malformed JSON` to stderr, exits 1, and **still prints five bytes of valid, empty
  JSON on stdout**. The kill decides, not the child — and neither does the parser. Every
  `osqueryi` call that parses a document goes through `osq_run`, which prints nothing on a
  non-zero exit, because that guard belongs in one place rather than at every call site.
- **`identifier` is derived from the manifest `key`.** That is why a planted or unpacked
  extension reports an EMPTY one — it has no key. The consequence is not that ids are
  untestable: the Web Store's signed CRX *does* carry the key, so unpacking one into a real
  profile yields the real id, and `45-claude-extension` does exactly that. Chromium ids are
  key-derived, so they are identical across all 11 `browser_type`s osquery enumerates.
