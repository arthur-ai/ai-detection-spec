# The osquery binding

The queries, the artifacts composed and rendered from them, the two endpoint scripts and the
bundle. The repo-wide rules in [`../CLAUDE.md`](../CLAUDE.md) apply here too, including why
the endpoint enumerates and where telemetry may live.

## Paths

- **Code and comments inside `osquery/` name the binding's own files from `osquery/`**:
  `bin/`, `dist/`, `queries/`, `tools/`, `test/`, `docs/`. `bin/discover` resolves `dist/`
  against its own parent, in a clone and in the release layout alike.
- **They name any other file from the repository root**: `catalog/`, `bin/classify`,
  `SPEC.md`, `docs/blind-spots.yaml`, `test/run-gce.sh`. Three paths exist at both,
  `test/lint.sh`, `README.md` and `CLAUDE.md`; unqualified they mean the binding's own, and
  the root's is written "the root `test/lint.sh`".
- **Markdown names paths from the repository root**, as this file does. An operator page
  may instead declare the release layout (`bin/`, `dist/`, `catalog/` side by side) and say
  so at the top, as `osquery/docs/deployment.md` does.
- **An error message, or a generated file's banner, names the path to type from the
  repository root**: `osquery/tools/build.py`. Only a clone can act on it, and a release
  ships no `tools/` at all.

## Matching on the endpoint

The second way to match is a **peer, not a fallback**. `osquery/tools/render_match.py`
renders the catalog into `osquery/dist/signatures.sql`, `osquery/dist/agents-<platform>.sql`
and `osquery/dist/fleet-policies.yml`, for a Jamf Extension Attribute
(`osquery/bin/discover --names`), a Fleet policy or `osqueryi`. Docs present the two ways
side by side. What keeps the rendered files honest:

- The signature rows come from `bin/classify`'s own `build_index`, and the SQL matches the
  same six-column rows, so agreement is structural. Where the classifier uses a regex, the
  SQL uses `regex_match` with the classifier's pattern.
- `osquery/test/test_match_sql.py` holds the two to the same rows, per row: on every
  fixture, on controls that must and must not match, on the conformance vectors, and on what
  every scenario's real install produced. It needs `osqueryi` and SKIPs loudly without one;
  the CI runtime jobs pass `--require-osqueryi`.
- A route whose match mode the renderer cannot express **fails the build**, and so does a
  value two agents claim, because those are the two ways the SQL and the classifier could
  disagree.
- `osquery/tools/check_no_catalog.py` exempts those four files **by name** and requires each
  to carry identifiers; every other file in `osquery/dist/` must carry none.
- `regex_match` returns NULL on a miss, an invalid pattern aborts the statement, and `LIKE` is
  case-insensitive, so the join is a `CASE`, every regex is compiled before it is written,
  and a prefix is `substr`.
- **On Windows `^` and `$` match at every line break** (osquery's regex there is MSVC's
  `std::regex`, measured on windows-2025). So the end is `(?![\s\S])`, and the start is checked
  as `instr(x, regex_match(x, p, 0)) = 1`: the leftmost match begins at the start exactly when
  instr() finds it there. The conformance vectors' line-break rows hold both, on every
  platform's osqueryi.
- A new signature reaches the rendered files only when they are redeployed. The payload
  re-matches without that. The bundle carries `signatures.sql` for `--names` and nothing
  else that names an agent.

## What the endpoint scripts may call

`osquery/bin/discover` and `osquery/bin/container-scan` run as root on machines whose owners
did not choose this tool, so **they may not add a dependency**. The list is closed:

| allowed | why |
|---|---|
| **bash 3.2** | what a managed Mac has, and the shebang both scripts declare |
| **`osqueryi`** | the dependency this binding already is, resolved through `osqueryi_path`, which states its failure rather than assuming a PATH |
| **`curl`** | the Docker `/_ping` probe in `container-scan`, and nothing else. Stock on macOS and every Linux base image this repo has run on |
| **the POSIX utilities already in use** | `cat`, `chmod`, `date`, `dirname`, `mkdir`, `mktemp`, `mv`, `rm`, `sed`, `sleep`, `uname` |

Anything else is a new dependency, **including one obviously installed on the machine you
test on**: no `python`, `perl`, `ruby`, `node`, and no `jq`, which macOS does not ship. No
GNU-only flag either, because a Mac has BSD `sed` and `date`. `osqueryi` is the JSON parser
and the shell is the serializer: `json_str`/`json_row` build a row with `printf`, and
`osq_run`, `json_concat` and `merge_sql` read documents with the SQLite that wrote them.

**A marker row may not depend on anything that could be the thing it reports.** The
`no-cache` row was once built by `python3`, which on a Mac without Command Line Tools is a
stub that exits 1 with empty stdout, so the row saying the writer never ran was never
written either, and nothing reads as a clean machine.

`osquery/tools/bundle.py` alone widens the list, by `base64` and `tar`, which its extraction
preamble needs; `osquery/docs/deployment.md` tells deployers. `osquery/test/lint.sh` greps
both scripts and the bundle wrapper for `python`, `jq`, `perl`, `ruby`, `node`, `deno` and
`php`, outside comments. That gate is narrower than the rule, so a reviewer enforces the rest.

## The artifacts

`osquery/dist/` is **generated**: edit `osquery/queries/`, then run
`python3 osquery/tools/build.py`. `--check` gates both directions, because a stale artifact
and one nothing generates are the same drift. `build.py` runs `render_match.py` when PyYAML
is present and says so when it is not; `render_match.py --check` is its own gate.

| artifact | what it is |
|---|---|
| `osquery/dist/discovery-darwin.sql` | the `fast` and `slow` queries for macOS, composed |
| `osquery/dist/discovery-linux.sql` | the same for Linux: a different set of tables, not a superset |
| `osquery/dist/discovery-windows.sql` | the same for Windows, which `osquery/bin/discover` does not run: it is bash |
| `osquery/dist/discovery-deep.sql` | the `expensive` queries, a supplement. One file because every expensive query is `posix`; `build.py` fails if one stops being |
| `osquery/dist/ai-detection-spec.conf` | the osqueryd pack, every platform's queries with osqueryd's per-query `platform` field |
| `osquery/dist/signatures.sql` | **rendered from the catalog**: the signature table and the match, as a fragment over an `ev` CTE the caller supplies |
| `osquery/dist/agents-<platform>.sql` | the enumeration wrapped in that match, one row per agent, for each platform. They never see image-only agents, because the container branch needs a bound |
| `osquery/dist/fleet-policies.yml` | one Fleet policy per agent per platform, passing when absent, each wrapping only the branches its agent's routes need |

**There is no unqualified `discovery.sql`.** Fed to the wrong platform's `osqueryi`, an
artifact prints `[\n\n]`, valid empty JSON, and exits 1. `osquery/bin/discover` picks by
`uname -s`. The deep artifact can block forever, so `osquery/bin/container-scan` is the only
supported way to run it.

A query declares `-- platform: darwin | linux | windows | posix | all`; `posix` is darwin and
linux, `all` every platform, both osqueryd's own words. **A group in `catalog/routes.yaml` must
be a word osqueryd schedules**, because `build.py` writes a query's word into the pack
verbatim, and it checks the value against that file, because `macos` once built clean and
shipped a pack query osqueryd never scheduled. A tool that runs queries here asks
`build.runs_on`, never a literal `posix`.

## Traps

- **`UNION ALL` takes its column names from the first arm only.** Composition is per
  platform, so which file leads an artifact varies. **Alias every first arm**: the pack once
  shipped a browser query whose columns were named `'ext'` and `permissions || CASE WHEN…`,
  and row-count and column-count checks both passed it. They check names now.
- **`CROSS JOIN` is mandatory** for user-scoped tables. A plain `JOIN … USING (uid)` returns
  zero rows, silently, because osquery needs the uid constraint pushed in.
- **A single `%` matches one path component.** `Application Support/Google/Chrome/…` is two.
- **`/root` is not under `/home`**, so a Linux path glob needs its own branch for it.
- **Some tables fail soft.** `systemd_units` with no reachable bus returns zero rows and lets
  the statement exit 0, so `osquery/queries/runtime-linux.sql` pairs it with a `kind=scan`
  marker reasoned from the unit **count**, not the socket.
- **`deb_packages` reports removed packages** (`deinstall ok config-files`).
  `osquery/queries/packages-linux.sql` filters on status, and testing that needs a package
  with conffiles.
- **Bash 3.2** has no `timeout(1)`, and an empty array under `set -u` is an unbound variable:
  append with `+=` and expand as `${a[@]+"${a[@]}"}`. The heredoc traps are in the root
  `CLAUDE.md`.
- **A parse failure prints `[\n\n]` too.** Fed malformed JSON, `osqueryi` exits 1 and still
  prints valid empty JSON, so every call that parses a document goes through `osq_run`,
  which prints nothing on a non-zero exit.
- **A Chromium extension `identifier` is derived from the manifest `key`**, so a planted or
  unpacked extension reports an empty one. The Web Store's signed CRX carries the key, and
  unpacking one into a real profile yields the real id, as `45-claude-extension` does. The id
  is the same across every Chromium browser.

**On Windows**, each measured on a windows-2025 runner (survey runs 40393754308 and
40396366136):

- **A glob echoes its own pattern's case** in the literal part of a path: `c:\users\%` comes
  back as `c:\users\...`. Write `C:\Users\` as SPEC.md 6.4.7 compares it. A directory comes
  back with a trailing `\` either way, and never as `.` or `..`.
- **Take homes from `users`, not a `C:\Users\%` glob.** `f.path LIKE u.directory || '\...'`
  pushes down per home, reaches a profile on any drive and skips the Default template.
- **`HKEY_USERS` holds signed-in users' hives only**, so a per-user registry or MSIX row
  disappears when its user signs out; their files do not.
- **osqueryi refuses a flag for a table it lacks**: `--docker_socket` exits 1 with nothing on
  stdout. `osquery/tools/measure.py` passes it only where the docker tables exist.
- **osqueryi writes CRLF**, and PowerShell 5.1's `>` writes UTF-16, which nothing here reads.
  Redirect from `cmd` or Git Bash.
