#!/usr/bin/env bash
# Static checks on the osquery binding: the queries, the composed and rendered artifacts, the
# two endpoint scripts and the bundle. No VM and no osquery needed. The repository's
# test/lint.sh runs this file, so every caller of that one still runs it.
#
# EVERY GLOB HERE MUST MATCH SOMETHING. These checks moved from test/lint.sh when osquery/ was
# split out, and a path left behind by a move does not fail a glob: it matches nothing, the loop
# body never runs, and the check prints its `ok` line. need() turns that into a failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSQ="$(cd "$HERE/.." && pwd)"        # osquery/, the binding
REPO="$(cd "$OSQ/.." && pwd)"        # the catalog, bin/classify and the scenarios
fail=0
export AI_DETECTION_SPEC_TELEMETRY=0      # see the root test/lint.sh

need() {  # need <description> <path>... : every path must exist
  local what="$1"; shift
  local p
  for p in "$@"; do
    [ -e "$p" ] || { echo "FAIL: $what: $p does not exist, so the check would read nothing"; fail=1; }
  done
}
need "query contract" "$OSQ"/queries/*.sql
need "endpoint scripts" "$OSQ/bin/discover" "$OSQ/bin/container-scan"
need "artifacts" "$OSQ"/dist/*.sql "$OSQ"/dist/*.conf "$OSQ"/dist/*.yml

for q in "$OSQ"/queries/*.sql; do
python3 - "$q" <<'PY' || fail=1
import re, sys
raw = open(sys.argv[1]).read()
sql = "\n".join(l for l in raw.splitlines() if not l.strip().startswith("--"))

if ";" in sql:
    print(f"FAIL: {sys.argv[1].split('/')[-1]}: a query fragment must not contain a semicolon. "
          "The build joins files with UNION ALL; a stray semicolon ends the composed "
          "query early and silently turns the rest into a second statement."); sys.exit(1)
stmts = [sql]

# A UNION ALL arm with the wrong column count is the failure mode this guards. osqueryi
# does reject it, but only after a VM boot and an osquery install — about twenty minutes
# later than here.
widths = []
for part in re.split(r"\bUNION ALL\b", stmts[0]):
    if "SELECT" not in part.upper(): continue
    frag = part[part.upper().index("SELECT"):]
    frag = frag[:re.search(r"\bFROM\b", frag, re.I).start()]
    # Commas inside string literals are not column separators. Counting them is how
    # this check first reported a false positive on `CASE WHEN .. THEN ',<all_urls>'`.
    depth = 0; n = 1; instr = False
    for ch in frag:
        if ch == "'": instr = not instr
        elif instr: continue
        elif ch == "(": depth += 1
        elif ch == ")": depth -= 1
        elif ch == "," and depth == 0: n += 1
    widths.append((re.search(r"'(\w+)'", frag).group(1), n))

bad = [(k, v) for k, v in widths if v != 6]
if bad:
    print(f"FAIL: {sys.argv[1].split('/')[-1]}: wrong column count (want 6): {bad}"); sys.exit(1)
print(f"ok: {sys.argv[1].split('/')[-1]}: {len(widths)} branches, 6 columns each")

# Two UNION ALLs with nothing between them. Removing a branch and leaving its keyword
# behind is a syntax error osqueryi only reports at runtime -- and the failing query then
# returns instantly, which reads as a SPEEDUP if you happen to be timing it.
if re.search(r"UNION\s+ALL\s+UNION\s+ALL", sql, re.I):
    print("FAIL: two consecutive UNION ALL - a branch was removed without its keyword"); sys.exit(1)
if re.search(r"UNION\s+ALL\s*;?\s*$", sql.strip(), re.I):
    print("FAIL: trailing UNION ALL with no branch after it"); sys.exit(1)

# Semicolons inside comments break naive statement splitting in the EA wrapper.
for i, l in enumerate(raw.splitlines(), 1):
    if l.strip().startswith("--") and ";" in l:
        print(f"FAIL: semicolon in comment at line {i}"); sys.exit(1)
PY
done

# THE FIRST ARM OF EVERY FILE MUST ALIAS ALL SIX COLUMNS, IN ORDER.
#
# A UNION ALL takes its column NAMES from its first arm alone. So an unaliased first arm
# silently inherits names from whatever happens to precede it -- apps.sql, inside
# a composed artifact, because it sorts first -- and gets nothing at all when the file runs
# on its own. browser.sql shipped that way: the pack's browser query returned 74 rows keyed
# 'ext', identifier, browser_type and "permissions || CASE WHEN manifest_json LIKE ...",
# which no consumer of the six-column contract can read. Row counts were correct throughout,
# so check_pack.py passed it and the column-count check below passed it too.
#
# This matters more now than it did: bin/discover --write runs each branch in its own
# process precisely so one failure cannot take the rest down, and a branch running alone is
# exactly the case an unaliased first arm gets wrong.
python3 - "$OSQ/queries" <<'ALIASES' || fail=1
import glob, os, re, sys
COLS = ["kind", "id", "ver", "loc", "extra", "perms"]
bad = False
paths = sorted(glob.glob(os.path.join(sys.argv[1], "*.sql")))
if not paths:
    print(f"FAIL: no queries under {sys.argv[1]}"); sys.exit(1)
for path in paths:
    name = os.path.basename(path)
    body = "\n".join(l for l in open(path).read().splitlines()
                     if not l.strip().startswith("--"))
    head = body.split("FROM", 1)[0]
    found = re.findall(r"\bAS\s+([a-z_]+)", head)
    if found[:6] != COLS:
        print(f"FAIL: {name}: first arm must alias all six columns in order "
              f"(kind, id, ver, loc, extra, perms); found {found[:6] or 'none'}. "
              f"Without it the file is only well-formed inside a composed artifact.")
        bad = True
if bad:
    sys.exit(1)
print("first-arm aliases: ok, every query names its own columns")
ALIASES

python3 - "$OSQ" "$REPO" <<'PY' || fail=1
import glob, json, os, re, sys
osq, root = sys.argv[1], sys.argv[2]

# THE KIND VOCABULARY IS DERIVED FROM catalog/routes.yaml, not written out here.
#
# It used to be a hardcoded set, and it was one of five copies that had to agree -- the
# same drift that let kind='ext' go missing from bin/classify for months, dropping every
# browser-extension row in silence. Deriving it means adding a route to the registry is
# the whole edit.
#
# AND IT IS SCOPED BY PLATFORM, which is what stops a Linux route breaking every macOS
# scenario. A scenario pins the kinds its own platform can produce: `deb` is meaningless
# on a Mac, and demanding it there would have forced a `"deb": 0` line into all thirteen
# macOS scenarios to say nothing.
reg = open(os.path.join(root, "catalog", "routes.yaml")).read()
_plats = re.search(r"^platforms:\s*\[(.+?)\]\s*$", reg, re.M).group(1)
PLATFORMS = [x.strip() for x in _plats.split(",")]
_groups = dict(re.findall(r"^  ([a-z]+):\s*\[(.+?)\]\s*$",
                          reg.split("platform_groups:", 1)[-1], re.M))
GROUPS = {g: [x.strip() for x in v.split(",")] for g, v in _groups.items()}
ROUTE_KIND, ROUTE_PLAT = {}, {}
for block in re.finditer(r"^  ([a-z_]+):\s*$", reg, re.M):
    name = block.group(1)
    tail = reg[block.end():]
    nxt = re.search(r"^  [a-z_]+:\s*$", tail, re.M)
    body = tail[:nxt.start()] if nxt else tail
    kind = re.search(r"^    kind:\s*(\S+)", body, re.M)
    plat = re.search(r"^    platform:\s*(\S+)", body, re.M)
    if kind and plat:
        ROUTE_KIND[name] = kind.group(1)
        ROUTE_PLAT[name] = GROUPS.get(plat.group(1), [plat.group(1)])

# WHAT A SCENARIO MUST PIN IS WHAT ITS PLATFORM'S QUERIES ACTUALLY EMIT, read off the
# query files rather than off the registry alone. The registry says which kinds a route
# can be reached through; the queries say which kinds a composed artifact will contain,
# and a scenario asserts on the artifact.
#
# The two differ in both directions, and each direction is a real check:
#
#   * `image` is a registry kind NO COMPOSED ARTIFACT carries. containers.sql is
#     `expensive`, so it reaches nobody through dist/discovery-<platform>.sql -- which is
#     why only a `deep: true` scenario may pin it, and why every other scenario must not.
#   * `scan` is emitted by a QUERY and is not a route kind at all. queries/runtime-linux.sql
#     emits one on every run, because systemd_units fails soft -- zero rows, exit 0 -- and
#     the marker is the only thing that separates "no agent units" from "we could not read
#     the unit list". A Linux scenario pins it, and pinning it is worth doing: it asserts
#     the marker is present rather than assuming it.
#
# `scan` was previously excluded on the grounds that a scenario pinning it would be
# "pinning its own failure". That was right about the CONTAINER marker, which
# bin/container-scan emits INSTEAD of rows. It is not right about a marker emitted
# alongside rows on every run, and the distinction is the reason this is derived now
# rather than listed.
bad_registry = False
QUERY_DIR = os.path.join(osq, "queries")
EMITTED = {}          # platform -> kinds its fast/slow queries emit
EMITTED_DEEP = {}     # platform -> kinds only the `expensive` queries emit
PRODUCERS = {}        # kind -> set of query files emitting it
QUERIES = sorted(glob.glob(os.path.join(QUERY_DIR, "*.sql")))
if not QUERIES:
    print(f"FAIL: no queries under {QUERY_DIR}"); sys.exit(1)
for q in QUERIES:
    text = open(q).read()
    head = []
    for line in text.splitlines():
        if line.strip() and not line.lstrip().startswith("--"):
            break
        head.append(line)
    fm = dict(re.findall(r"^--\s*([a-z-]+):\s*(.+?)\s*$", "\n".join(head), re.M))
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--"))
    kinds = set(re.findall(r"SELECT\s+'(\w+)'", body, re.I))
    # THE EXPENSIVE QUERIES GO IN THEIR OWN BUCKET rather than being skipped. They used to
    # be `continue`d, which is why `image` needed a hardcoded exception two checks below:
    # with no record that containers.sql emits it, a registry kind nothing produced looked
    # like a route that could never match. Tracked separately, the exception is derived.
    target = EMITTED_DEEP if fm.get("cost") == "expensive" else EMITTED
    for plat in GROUPS.get(fm["platform"], [fm["platform"]]):
        target.setdefault(plat, set()).update(kinds)
    for k in kinds:
        PRODUCERS.setdefault(k, set()).add(os.path.basename(q))

# EVERY ROUTE'S KIND MUST HAVE A PRODUCER, on every platform the route claims. This is
# the direction that fails silently: a route in the registry whose kind no query emits is
# a signature nothing can ever feed, and it reads as coverage on the generated page.
for r, k in sorted(ROUTE_KIND.items()):
    for plat in ROUTE_PLAT[r]:
        if plat not in EMITTED:            # no queries for that platform at all yet
            continue
        if k not in EMITTED[plat] | EMITTED_DEEP.get(plat, set()):
            print(f"FAIL: route {r!r} needs kind {k!r} on {plat}, and no {plat} query "
                  f"emits it -- the route could never match")
            bad_registry = True

def kinds_for(platform):
    return set(EMITTED.get(platform, set()))

# WHAT A DEEP SCENARIO PINS IS MORE, because it runs more. `deep: true` in expected.json
# means the scenario asserts against `bin/discover --deep`, which is the composed artifact
# PLUS dist/discovery-deep.sql -- so `image` becomes a kind it can and must pin. Nothing
# else may pin it, and that asymmetry is the check: pinning `image` without `deep` fails
# here rather than failing on a runner with no daemon.
def deep_kinds_for(platform):
    return set(EMITTED_DEEP.get(platform, set()))


covered, bad = set(), False
bad = bad or bool(globals().get("bad_registry"))
seen_platforms, deep_platforms = set(), set()
SCENARIOS = sorted(glob.glob(os.path.join(root, "test", "scenarios", "*", "expected.json")))
if not SCENARIOS:
    print("FAIL: no test/scenarios/*/expected.json to check kinds against"); sys.exit(1)
for f in SCENARIOS:
    name = os.path.basename(os.path.dirname(f))
    d = json.load(open(f))
    # REQUIRED, and it lives in expected.json rather than requires.json because every
    # scenario already has one of these. An absent platform is the same ambiguity the
    # catalog refuses for agents: "macOS" or "nobody said" are different claims.
    platform = d.get("platform")
    if platform not in PLATFORMS:
        print(f"FAIL: {name} declares platform {platform!r}, want one of {PLATFORMS}")
        bad = True
        continue
    seen_platforms.add(platform)
    want = kinds_for(platform)
    if d.get("deep"):
        want |= deep_kinds_for(platform)
        deep_platforms.add(platform)
    counts = d.get("counts", {})
    missing = want - set(counts)
    if missing:
        print(f"FAIL: {name} ({platform}) does not pin {sorted(missing)}")
        bad = True
    for k, v in counts.items():
        # A `+` KEY SUMS KINDS -- test/lib/assert.sh reads it -- and every part of it
        # must be a kind this platform emits. It proves the SUM, so it covers neither
        # part below: `deb+rpm >= 1` says the package branch ran, not that either
        # family was installed.
        for part in k.split("+"):
            if part not in want:
                print(f"FAIL: {name} ({platform}) pins {part!r}, which no {platform} "
                      f"route produces"); bad = True
        if "+" in k:
            continue
        if isinstance(v, str) and not v.startswith(">="):
            print(f"FAIL: {name}.{k} = {v!r}, want an int or '>=N'"); bad = True
        # A FLOOR OF ZERO IS NOT EVIDENCE. `">=0"` used to count a kind as exercised,
        # so a kind pinned `>=0` by every scenario satisfied the "every kind is
        # exercised somewhere" check while nothing installed anything that produces it
        # -- the check read as coverage and was a tautology. Only a positive floor
        # counts now.
        floor = v if isinstance(v, int) else int(v[2:] or 0)
        if floor > 0:
            covered.add(k)
    if not os.access(os.path.join(os.path.dirname(f), "setup.sh"), os.X_OK):
        print(f"FAIL: {name}/setup.sh is not executable"); bad = True

# Every kind must be exercised somewhere, or a branch ships untested -- which is the exact
# state four of these were in before this harness existed. Only kinds belonging to a
# platform some scenario actually covers are demanded: a Windows kind cannot be exercised
# by a suite that has no Windows scenario, and failing for that would be noise.
# `image` is demanded only of a platform that HAS a deep scenario -- the same reason a
# Windows kind is not demanded of a suite with no Windows scenario.
demanded = set().union(*(kinds_for(p) for p in seen_platforms)) if seen_platforms else set()
demanded |= set().union(*(deep_kinds_for(p) for p in deep_platforms)) if deep_platforms else set()
never = demanded - covered
if never:
    print(f"FAIL: no scenario exercises {sorted(never)}"); bad = True
if bad: sys.exit(1)
print(f"ok: {len(demanded)} kinds across {len(seen_platforms)} platform(s) "
      f"({', '.join(sorted(seen_platforms))}), every one exercised")
PY

# EVERY "$ROOT/..." AND "$REPO/..." A SCRIPT NAMES MUST EXIST. Each of these scripts sets ROOT
# to osquery/, and the move into osquery/ left docker_states.sh calling "$ROOT/bin/classify",
# which is at the repository root: the call failed into 2>/dev/null and the suite reported
# "finds aider" failed with no findings, on a runner, minutes later. bash -n cannot see it.
python3 - "$OSQ" "$HERE/docker_states.sh" "$OSQ/bin/discover" "$OSQ/bin/container-scan" <<'ROOTS' || fail=1
import pathlib, re, sys
osq = pathlib.Path(sys.argv[1])
bases = {"ROOT": osq, "REPO": osq.parent}
bad, seen = [], 0
for name in sys.argv[2:]:
    for n, line in enumerate(pathlib.Path(name).read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for var, rel in re.findall(r'\$\{?(ROOT|REPO)\}?/([\w.-]+(?:/[\w.-]+)*)(?![\w.$-])', line):
            seen += 1
            if not (bases[var] / rel).exists():
                bad.append(f"{pathlib.Path(name).name}:{n}: ${var}/{rel} does not exist "
                           f"(${var} is {bases[var].relative_to(osq.parent) or '.'}/)")
for b in bad:
    print(f"FAIL: {b}")
if bad:
    sys.exit(1)
print(f"script paths: ok, {seen} $ROOT and $REPO paths in the binding's scripts exist")
ROOTS

for f in "$HERE"/docker_states.sh "$OSQ"/bin/container-scan "$OSQ"/bin/discover; do
  bash -n "$f" || { echo "FAIL: bash syntax in $f"; fail=1; }
done

# bin/container-scan is SOURCED by test/docker_states.sh and by bin/discover, so that it
# lends out the guard and the bound rather than having them copied. Two things can break
# that silently: deleting the `(return 0 2>/dev/null) && return 0` line, after which
# sourcing runs a live scan; and renaming a function the callers use.
bash -c '. "'"$OSQ"'/bin/container-scan" && type -t own_run_dir run_bounded docker_healthy docker_socket_path marker json_str json_row osq_run json_concat pack_branches merge_sql merge_branches >/dev/null' \
  || { echo "FAIL: bin/container-scan is no longer safely sourceable, or a shared function was renamed"; fail=1; }

# ONE NAMESPACE, TWO FILES. bin/discover sources bin/container-scan, so a global or function
# either assigns overwrites the other's in silence -- DEEP and CACHE both collided that way.
# bin/discover's header lists what each file defines, for the next addition to be checked
# against; this derives the same sets from the code, because that list went stale without
# anything failing. The files may share ROOT and nothing else: both set it to one directory.
python3 - "$OSQ" <<'NAMES' || fail=1
import re, sys
root = sys.argv[1]
SHARED = {"ROOT"}

def defined(path):
    code = "\n".join(l for l in open(path).read().splitlines() if not l.lstrip().startswith("#"))
    fns = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", code, re.M))
    # Upper case is a global: every local in both files is lower case. IFS is only ever a
    # prefix on one `read`, which scopes it to that command.
    glb = set(re.findall(r"(?<![A-Za-z0-9_$])([A-Z][A-Z0-9_]*)\+?=", code)) - {"IFS"}
    return glb, fns

def documented(path):
    lists, cur = [], None
    for line in open(path).read().splitlines():
        m = re.match(r"#\s{3}(globals|functions)\s+(\S.*)$", line)
        if m:
            cur = set(m.group(2).split())
            lists.append(cur)
            continue
        m = re.match(r"#\s{10,}(\S.*)$", line)
        if cur is not None and m:
            cur.update(m.group(1).split())
        else:
            cur = None
    return lists

cs_g, cs_f = defined(f"{root}/bin/container-scan")
d_g, d_f = defined(f"{root}/bin/discover")
lists = documented(f"{root}/bin/discover")
bad = []
if len(lists) != 4:
    bad.append(f"bin/discover's header should hold four lists, and holds {len(lists)}")
else:
    for label, doc, code in (("container-scan globals", lists[0], cs_g),
                             ("container-scan functions", lists[1], cs_f),
                             ("discover globals", lists[2], d_g - SHARED),
                             ("discover functions", lists[3], d_f)):
        if doc != code:
            bad.append(f"{label}: listed and not defined {sorted(doc - code)}; "
                       f"defined and not listed {sorted(code - doc)}")
clash = ((cs_g & d_g) | (cs_f & d_f)) - SHARED
if clash:
    bad.append(f"both files define {sorted(clash)}, and sourcing makes them one name")
for b in bad:
    print(f"FAIL: namespace -- {b}")
if bad:
    sys.exit(1)
print("namespace: ok, bin/discover lists what both files define, and they share only ROOT")
NAMES

# NOTHING ON THE ENDPOINT IS PYTHON, AND THE FAILURE IT PREVENTS IS SILENCE RATHER THAN AN
# ERROR. These two scripts run on managed Macs where /usr/bin/python3 is a STUB -- no Command
# Line Tools, so it prints an install prompt on stderr and exits 1 with empty stdout. That
# took the no-cache marker with it: the one row whose whole job is to say the writer never
# ran was built by the interpreter that stopped the writer, so a consumer saw nothing, and
# nothing reads as a machine with nothing on it. docs/deployment.md has the history.
#
# `python` rather than `python3`, and no path anchor, so `/usr/bin/python3` and `env python`
# fail here too. COMMENTS ARE EXCLUDED -- shell `#` and SQL `--` alike -- because the
# comments in both files are what explain the removal, and a check that counts its own
# documentation is one nobody can satisfy. bin/classify is the python half and is off the
# endpoint by design, so it is not in this list and must not be added to it.
#
# A DENY-LIST, AND IT IS HONEST ABOUT BEING ONE. These seven are what someone reaches for when
# they need to read JSON in a shell script, which is the only reason this rule has ever been
# broken; `jq` in particular is the obvious next one and does not ship with macOS at all. It
# does NOT enumerate every command these scripts may call, so it cannot enforce the whole rule
# in CLAUDE.md -- an allow-list over two files this size is mostly shell builtins and control
# flow, and one tuned to pass today would go stale as noise. What it catches is the failure
# that has actually happened. Read the rule, not just the gate.
#
# `|| true` on the greps, because this file runs under `set -e` and a grep that matches
# NOTHING exits 1 -- which is the passing case here. Without it lint stops dead at the first
# clean file and every check below this line silently stops running.
_endpoint_clean=1
for _f in "$OSQ/bin/discover" "$OSQ/bin/container-scan"; do
  [ -f "$_f" ] || { _endpoint_clean=0; continue; }   # need() has already said why
  _hits="$( { grep -nE '(^|[^a-zA-Z_.-])(python|jq|perl|ruby|node|deno|php)([^a-zA-Z0-9_-]|$)' \
              "$_f" || true; } \
            | { grep -vE '^[0-9]+:[[:space:]]*(#|--)' || true; } )"
  if [ -n "$_hits" ]; then
    echo "FAIL: $(basename "$_f") reaches for an interpreter or a JSON tool:"
    printf '%s\n' "$_hits" | sed 's/^/      /'
    echo "      The endpoint is bash 3.2, osqueryi and curl, and osqueryi is the JSON parser:"
    echo "      json_str/json_row build rows, osq_run/json_concat/merge_sql read them."
    echo "      bin/classify is the python half, and it runs off the machine."
    fail=1; _endpoint_clean=0
  fi
done
# Guarded, or the summary line prints `ok` directly underneath its own FAIL -- which is how
# a reader skimming for the last line concludes the check passed.
[ "$_endpoint_clean" = 1 ] &&
  echo "endpoint: ok, bin/discover and bin/container-scan reach for no interpreter or JSON tool"

# NO QUERY MAY NAME A CONTAINER'S ENVIRONMENT. `docker_containers.env_variables` and the
# whole `docker_container_envs` table hold ANTHROPIC_API_KEY, OPENAI_API_KEY, model
# endpoints and session tokens. Every other hazard in this repo is a wrong answer; this one
# is an employee's credentials in a Jamf inventory record, and it cannot be walked back
# once a recon has run.
#
# FILTERING DOWNSTREAM IS TOO LATE, which is why the gate is here and not in bin/classify.
# The six-column contract is written ON the endpoint: by the time a consumer could drop
# the column, the row has already left the machine. The column must never be selected.
#
# NOTHING ELSE CATCHES IT, and that was measured rather than assumed. Injecting
# `c.command || ' ' || c.env_variables AS extra` into the docker_containers branch produces
# a query that is six columns wide, correctly aliased in its first arm, on a registered
# kind, inside the one expensive file -- and lint, tools/build.py --check,
# check_no_catalog.py, validate_catalog.py and test/test_matcher.py ALL PASSED. The
# contract checks count and name columns; they cannot know what is inside one.
#
# A DENY-LIST OF TWO NAMES, and an allow-list was rejected rather than overlooked: it would
# have to enumerate every column of nineteen docker tables plus everything else these
# queries touch, and one tuned to pass today goes stale as noise. These two are different
# from the rest because they are the only columns here whose CONTENTS are structurally
# guaranteed to be secrets -- not "might contain a path", but "holds the API key". The
# neighbouring hazard, docker_container_processes.cmdline, is NOT on this list: it *can*
# carry `--api-key`, so it wants redaction rather than prohibition, and it is unreachable
# today because no query selects the table at all. UP-5025 owns that; do not fold it in
# here, because a name on a deny-list is a decision not to have the column, and that is the
# wrong decision for cmdline.
#
# dist/ IS GENERATED AND IS CHECKED ANYWAY. tools/build.py --check gates drift both ways,
# so a leak in queries/ is the only way one reaches an artifact today -- but the artifacts
# are what ship, the pack embeds its SQL as JSON strings, and a check that reads the thing
# that leaves the machine costs one glob. COMMENTS ARE EXCLUDED, shell `#` and SQL `--`
# alike: queries/containers.sql explains this rule in a comment and dist/discovery-deep.sql
# carries the copy, so a check counting its own documentation is one nobody can satisfy.
_envs_clean=1
for _f in "$OSQ"/queries/*.sql "$OSQ"/dist/*.sql "$OSQ"/dist/*.conf \
          "$OSQ"/dist/*.yml "$OSQ/bin/discover" "$OSQ/bin/container-scan"; do
  [ -f "$_f" ] || { _envs_clean=0; continue; }      # need() has already said why
  _hits="$( { grep -nE '(^|[^a-zA-Z0-9_])(env_variables|docker_container_envs)([^a-zA-Z0-9_]|$)' \
              "$_f" || true; } \
            | { grep -vE '^[0-9]+:[[:space:]]*(#|--)' || true; } )"
  if [ -n "$_hits" ]; then
    echo "FAIL: $(basename "$_f") names a container's environment:"
    printf '%s\n' "$_hits" | sed 's/^/      /'
    echo "      env_variables and docker_container_envs hold ANTHROPIC_API_KEY and its like,"
    echo "      and this payload leaves the machine. The column is never selected -- not"
    echo "      selected-and-filtered, because the row is written on the endpoint."
    fail=1; _envs_clean=0
  fi
done
[ "$_envs_clean" = 1 ] &&
  echo "container envs: ok, no query or artifact names env_variables or docker_container_envs"

# ONE expensive query, and the check exists because the second one is a trap.
# dist/discovery-deep.sql is run by bin/container-scan behind a guard that is specific to
# Docker: a round trip to /_ping demanding HTTP 200. A second expensive branch composed
# into the same artifact would inherit that guard, which says nothing whatsoever about
# whatever daemon or directory the new branch blocks on -- and it would be bounded by a
# wall clock sized for this one. When that day comes, split the artifact per branch and
# give each its own guard. Do not delete this check to make the build pass.
python3 - "$OSQ" <<'PY' || fail=1
import glob, os, re, sys
root = sys.argv[1]
expensive = [os.path.basename(f) for f in sorted(glob.glob(os.path.join(root, "queries/*.sql")))
             if re.search(r"^--\s*cost:\s*expensive", open(f).read(), re.M)]
if not glob.glob(os.path.join(root, "queries/*.sql")):
    print("FAIL: no queries to count"); sys.exit(1)
if len(expensive) > 1:
    print(f"FAIL: {len(expensive)} expensive queries ({', '.join(expensive)}), and they would "
          "share one wall clock and one Docker-specific health guard in "
          "dist/discovery-deep.sql. Split the artifact per branch first; see the comment "
          "above this check in osquery/test/lint.sh.")
    sys.exit(1)
print(f"expensive queries: {len(expensive)} ({expensive[0] if expensive else 'none'})")
PY
# THE PACK'S NAME AND QUERY CROSS ONE osqueryi IN ONE COLUMN, joined by a tab and split back
# in the shell. bin/discover --write reads the branch list and every branch's SQL in a single
# call that way, and the separator is safe because tools/build.py's flatten() is
# `" ".join(text.split())` -- a property of the BUILDER, so it is asserted against the FILE.
#
# MEASURED, because the two characters do not fail the same way. A tab survives: `read -r
# name qtext` hands the remainder to the last variable with its tabs intact. A newline does
# not, and it does not fail loudly either -- the loop reads the second half as a fresh
# record, so `SELECT 'app'\nAS kind FROM apps;` becomes a branch named `AS kind FROM apps;`
# and a truncated `apps`. Both are rejected anyway: the tab is only harmless while qtext is
# the last field, and a third column would make today's safe case tomorrow's silent one.
python3 - "$OSQ/dist/ai-detection-spec.conf" <<'PY' || fail=1
import json, sys
pack = json.load(open(sys.argv[1]))["queries"]
bad = [n for n, q in pack.items() if "\t" in q["query"] or "\n" in q["query"]]
if bad:
    print("FAIL: pack queries contain a tab or newline: " + ", ".join(sorted(bad)))
    print("      bin/discover --write joins name and query with a tab and splits them back.")
    print("      A newline there invents a branch out of the second half. Keep build.py's")
    print("      flatten() collapsing whitespace, or give --write another separator.")
    sys.exit(1)
print(f"pack: ok, {len(pack)} queries, none carrying the separator --write splits on")
PY

# test/docker_states.sh HARDCODES THE AGENTS its image fixture must resolve to, and it needs
# sudo, so it does not run in the fast loop -- a catalog change that breaks it surfaces minutes
# later on someone's machine instead of here. Removing `litellm` did exactly that. It lived in
# tools/validate_catalog.py, which made a catalog tool read an osquery test, and it skipped
# itself when the file or the pattern was missing; both are failures now.
python3 - "$HERE/docker_states.sh" "$REPO/catalog/agents.yaml" <<'SUITE' || fail=1
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"sorted\(f\['id'\] for f in d\['findings'\]\) == \['([a-z0-9,'-]+)'\] else 0", text)
if not m:
    print("FAIL: docker_states.sh no longer names the findings its image fixture expects in "
          "the `== ['...'] else 0` form, so nothing checks those ids against the catalog")
    sys.exit(1)
import yaml
known = {a["id"] for a in yaml.safe_load(open(sys.argv[2]))["agents"]}
named = [x.strip("'") for x in m.group(1).split("','")]
missing = [a for a in named if a not in known]
if missing:
    print(f"FAIL: docker_states.sh expects findings {named}, but {missing} are not ids in "
          f"catalog/agents.yaml. That suite needs sudo and does not run in the fast loop.")
    sys.exit(1)
print(f"docker_states: ok, the findings it expects ({', '.join(named)}) are catalog ids")
SUITE

# EVERY OUTCOME THIS BINDING WRITES IS ONE THE SPEC ALLOWS. The evidence schema once took
# `unhealthy:` with three digits while runtime-linux.sql wrote `unhealthy:no-units`, on a host
# CI never is: a bus socket and no units. So the outcomes are read off the source -- each
# `marker` and `json_row scan` call, its shell expansions replaced by the values they can
# hold, and each SQL literal shaped like an outcome -- and held to schema/evidence.schema.json.
python3 - "$OSQ" "$REPO" <<'OUTCOMES' || fail=1
import itertools, pathlib, re, sys
osq, repo = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(repo / "test"))
from conformance import scan_outcome_ok, scan_outcomes

def code(path):
    return "\n".join(l for l in path.read_text().splitlines()
                     if not l.lstrip().startswith(("#", "--")))

scripts = {n: code(osq / "bin" / n) for n in ("discover", "container-scan")}
# What each expansion can hold. One with no entry fails below until it has one.
EXAMPLES = {"$RUNTIME_NAME": re.findall(r"_runtime_seen\s+([a-z0-9-]+)", scripts["container-scan"]),
            "${DOCKER_CODE:-000}": ["000", "503"], "${SCAN_TIMEOUT}": ["6"]}
ARG = r'("[^"]*"|[^\s"]+)'
found = []                                   # (where, outcome as written)
for name, text in scripts.items():
    for m in re.finditer(r"(?m)(?:^\s*|\$\(\s*)marker\s+" + ARG, text):
        found.append((f"bin/{name}", m.group(1).strip('"')))
    for m in re.finditer(r"\$\(\s*json_row scan\s+" + r"\s+".join([ARG] * 4), text):
        found.append((f"bin/{name}", m.group(4).strip('"')))
words, patterns = scan_outcomes()
prefixes = [re.match(r"\^([a-z-]+):", p).group(1) for p in patterns]
literal = re.compile(r"'((?:%s)|(?:%s):[^']*)'" % ("|".join(map(re.escape, words)),
                                                    "|".join(map(re.escape, prefixes))))
sources = {**{f"bin/{n}": t for n, t in scripts.items()},
           **{f"queries/{q.name}": code(q) for q in sorted((osq / "queries").glob("*.sql"))}}
for where, text in sources.items():
    found += [(where, m.group(1)) for m in literal.finditer(text)]

bad, checked = [], set()
for where, written in found:
    exps = re.findall(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9]", written)
    if any(re.fullmatch(r"\$[0-9]", e) for e in exps):
        continue                             # marker() itself; its callers are read above
    missing = [e for e in exps if not EXAMPLES.get(e)]
    if missing:
        bad.append(f"{where}: {written!r} -- no example values for {missing}; add them here")
        continue
    for combo in itertools.product(*(EXAMPLES[e] for e in exps)):
        value = written
        for e, v in zip(exps, combo):
            value = value.replace(e, v)
        checked.add(value)
        if not scan_outcome_ok(value):
            bad.append(f"{where}: writes {value!r} (as {written!r})")
for where in ("bin/discover", "bin/container-scan", "queries/runtime-linux.sql"):
    if not any(w == where for w, _ in found):
        bad.append(f"{where}: no outcome found, so this check reads nothing there")
if bad:
    print("FAIL: scan outcomes the spec does not allow (SPEC.md 5.2):\n  " + "\n  ".join(bad))
    sys.exit(1)
print(f"outcomes: ok, {', '.join(sorted(checked))}")
OUTCOMES

# bin/classify READS THE PROVENANCE TOKENS browser.sql appends to `extra`, by name. A token
# added to the query and not to PROVENANCE would go unreported.
python3 - "$OSQ/queries/browser.sql" "$OSQ/tools" <<'PROV' || fail=1
import re, sys
sys.path.insert(0, sys.argv[2])
import render_match
cl = render_match.load_classify()
emitted = set(re.findall(r"THEN ',([^'<][^']*)'", open(sys.argv[1]).read()))
if not emitted or emitted != set(cl.PROVENANCE):
    print(f"FAIL: browser.sql appends {sorted(emitted)} to extra, and bin/classify's "
          f"PROVENANCE names {sorted(cl.PROVENANCE)}")
    sys.exit(1)
print(f"extension provenance: ok, browser.sql and bin/classify agree on {sorted(emitted)}")
PROV

python3 "$OSQ/tools/build.py" --check || fail=1
# THE BINDING CHECK REFUSES WHAT IT EXISTS TO REFUSE. build.py runs it on the real registry
# above; these feed it a broken one, so a check that stopped looking would go red here.
python3 - "$OSQ/tools" "$REPO/catalog/routes.yaml" <<'BINDING' || fail=1
import sys
sys.path.insert(0, sys.argv[1])
import build
text = open(sys.argv[2]).read()
qs = build.queries()
cases = {
    "a floor above every feeding query": text.replace(
        "{table: jetbrains_plugins, min_osquery: 5.18.0}", "{table: jetbrains_plugins, min_osquery: 5.99.0}"),
    "a table no query names": text.replace(
        "{table: homebrew_packages, min_osquery: 5.10.0}", "{table: brew_packages, min_osquery: 5.10.0}"),
    "a binding it cannot read": text.replace(
        "    osquery: {table: apps, min_osquery: 5.10.0}", "    osquery: {table: apps}"),
    # A route whose name has a digit is parsed and checked, not folded into the one above.
    "an unfed route named with a digit": text.rstrip("\n") + "\n  npm2:\n    platform: posix\n"
        "    kind: npm\n    match: exact\n    osquery: {table: no_such_table, min_osquery: 5.10.0}\n",
    "a route name the parser cannot read": text.rstrip("\n") + "\n  Bad-Route:\n"
        "    platform: posix\n    kind: npm\n    match: exact\n"
        "    osquery: {table: npm_packages, min_osquery: 5.10.0}\n",
}
bad = [name for name, mutated in cases.items()
       if mutated == text or not build.binding_errors(qs, mutated)]
if build.binding_errors(qs, text):
    bad.append("the real registry")
# AND IT READS EVERY FORM validate_catalog ACCEPTS. PyYAML takes the binding inline or one key
# per line, in any order, quoted or not; a catalog it accepts has to build.
_inline = "    osquery: {table: apps, min_osquery: 5.10.0}"
for name, form in (
        ("one key per line", "    osquery:\n      table: apps\n      min_osquery: 5.10.0"),
        ("keys reversed", "    osquery: {min_osquery: 5.10.0, table: apps}"),
        ("values quoted", "    osquery:\n      min_osquery: '5.10.0'\n      table: \"apps\""),
):
    if build.binding_errors(qs, text.replace(_inline, form)):
        bad.append(f"a valid binding written {name}")
if bad:
    print(f"FAIL: binding check: wrong answer for {bad}")
    sys.exit(1)
print(f"binding check: ok, refuses {len(cases)} broken registries, reads every binding form "
      f"validate_catalog accepts, and passes the real one")
BINDING
# The rendered match SQL is generated from the catalog the way dist/ is from queries/, and
# gated the same way. The parity test needs osqueryi and SKIPs without one, which is what
# lets this file stay runnable on a runner with no osquery; ci.yml's runtime jobs run it
# with --require-osqueryi.
python3 "$OSQ/tools/render_match.py" --check || fail=1
# SKIPs without osqueryi, and the SKIP is printed: discarded, it read as a pass.
if _out=$(python3 "$HERE/test_match_sql.py" 2>&1); then
  printf '%s\n' "$_out" | grep '^SKIP' || true
else
  echo "FAIL: match-SQL tests"
  { printf '%s\n' "$_out" | grep -E '^ *FAIL' || printf '%s\n' "$_out" | tail -5; } | sed 's/^/      /' || true
  fail=1
fi
python3 "$OSQ/tools/check_no_catalog.py" || fail=1

# --- the one-file bundle -----------------------------------------------------------------
# tools/bundle.py packs bin/ and dist/ into one self-extracting script, for a management
# platform that can host a script and cannot place files on disk. Everything it produces is
# invisible afterwards: the payload is base64, so which files went in, and whether the
# shell around them is sound, cannot be read off the artifact by eye. Checked here instead.
#
# Built into a temp directory rather than artifacts/, so a lint run never leaves a stale
# bundle somewhere a release might pick it up.
_bundle_tmp="$(mktemp -d "${TMPDIR:-/tmp}/lint-bundle.XXXXXX")"
trap 'rm -rf "$_bundle_tmp"' EXIT HUP INT TERM
_bundle_ok=1
for _p in darwin linux; do
  python3 "$OSQ/tools/bundle.py" --platform "$_p" --out "$_bundle_tmp/$_p.sh" >/dev/null \
    || { echo "FAIL: tools/bundle.py --platform $_p did not build"; fail=1; _bundle_ok=0; continue; }
  # GENERATED SHELL IS EXACTLY THE SHELL NOBODY READS. A wrapper edit in bundle.py produces
  # this file unexamined, and bash reports a syntax error only when a fleet runs it.
  bash -n "$_bundle_tmp/$_p.sh" \
    || { echo "FAIL: bash syntax in the $_p bundle"; fail=1; _bundle_ok=0; }
  # The check mode is what a consumer committing a bundle depends on, so it is exercised
  # rather than assumed -- a --check that cannot fail is worse than no --check.
  python3 "$OSQ/tools/bundle.py" --platform "$_p" --check "$_bundle_tmp/$_p.sh" >/dev/null \
    || { echo "FAIL: a freshly built $_p bundle does not pass --check"; fail=1; _bundle_ok=0; }
done

# THE BUNDLE REFUSES THE OTHER PLATFORM BY NAME. The composed artifacts name disjoint sets
# of tables, so the wrong bundle would die on a missing path and report a file when the
# truth is about the build. Run here because the guard is the first thing in the script and
# costs nothing: it fires before mktemp, before base64, before anything is unpacked.
case "$(uname -s)" in Darwin) _other=linux ;; *) _other=darwin ;; esac
if [ "$_bundle_ok" = 1 ]; then
  if _out="$("$_bundle_tmp/$_other.sh" 2>&1)"; then
    echo "FAIL: the $_other bundle ran on $(uname -s) instead of refusing"; fail=1
  else
    case "$_out" in
      # AND THE COMMAND IT PRINTS MUST RUN. `--platform` takes a value; the message omitted
      # it, so following the advice exited with an argument error. It must also name the
      # OTHER platform -- this bundle's own is the one the reader is already holding.
      *"runs on"*only*"--platform $(uname -s | tr 'A-Z' 'a-z')."*) : ;;
      *"runs on"*only*) echo "FAIL: the $_other bundle's refusal does not name the platform "\
                             "to build: $_out"; fail=1 ;;
      *) echo "FAIL: the $_other bundle refused without naming the cause: $_out"; fail=1 ;;
    esac
  fi
fi

python3 - "$OSQ" "$_bundle_tmp" <<'BUNDLE' || fail=1
import base64, gzip, io, os, pathlib, re, sys, tarfile
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(root / "tools"))
import bundle as B
bad = []

for plat in ("darwin", "linux"):
    path = tmp / f"{plat}.sh"
    if not path.exists():
        bad.append(f"{plat}: not built"); continue
    text = path.read_text()
    head, body, tail = B._split(text)

    # WHAT IS ACTUALLY IN THE PAYLOAD, read out of the payload. A list of filenames in
    # bundle.py is a statement of intent; the tar is the artifact, and inside 37KB of
    # base64 the difference between them is not something a reviewer can see.
    names = sorted(tarfile.open(fileobj=io.BytesIO(
        gzip.decompress(base64.b64decode(body))), mode="r").getnames())
    want = sorted(B.payload_files(plat))
    if names != want:
        bad.append(f"{plat}: payload is {names}, declared {want}")

    # THE ENDPOINT HOLDS NO CATALOG FILE AND NO CLASSIFIER, and this is the check that
    # survives someone adding one to the list for a good-sounding reason. It DOES carry
    # dist/signatures.sql, the catalog rendered into SQL for `--names` -- a deliberate
    # exception tools/bundle.py's header argues, and one this check cannot see: the
    # payload-vs-declared comparison above reads the same payload_files tuple, so
    # dropping that file from the tuple passes here. ci.yml running `--names` through the
    # bundle is the gate for that.
    for leak in B.FORBIDDEN:
        if any(leak in n for n in names) or leak in text:
            bad.append(f"{plat}: the bundle carries or names {leak!r}")

    # THE WRAPPER SHIPS TO THE SAME MACHINES bin/discover DOES, so it lives under the same
    # rule: no interpreter, no JSON tool. On a managed Mac /usr/bin/python3 is a stub that
    # prints an install prompt and exits 1, and a wrapper built on it would fail before the
    # runner it was written to protect ever started.
    wrapper = head[:head.index("<<")] + tail
    code = "\n".join(l for l in wrapper.splitlines() if not l.strip().startswith("#"))
    hit = re.search(r"(?:^|[|;&(`]|\$\(|\s)(python3?|jq|perl|ruby|node|deno|php)\b", code)
    if hit:
        bad.append(f"{plat}: the wrapper reaches for {hit.group(1)}")

    # RUN, NOT exec. A shell replaced by exec does not run its EXIT trap, so the extracted
    # tree stays in TMPDIR -- one copy per run on a schedule, surfacing months later as a
    # full volume and looking like anything but this script. Verified behaviour, not a
    # style preference, which is why it is a gate.
    if re.search(r"^\s*exec\s", code, re.M):
        bad.append(f"{plat}: the wrapper execs the runner, which skips the cleanup trap")
    if "trap " not in code or "rm -rf" not in code:
        bad.append(f"{plat}: the wrapper does not remove its working directory")

# --driver IS THE ONE THING A CONSUMER BUILDS ON, AND IT SHIPPED WITH NO TEST AT ALL.
# release.yml names it in a comment; nothing exercised it. The first repo to adopt it made
# its entire deployable out of it -- a wrapper around its own script -- so a --driver that
# quietly stopped embedding, or a --check that ignored the driver and blessed a stale
# bundle, would be someone's fleet.
_drv = tmp / "driver.sh"
_drv.write_text("#!/bin/bash\necho marker-in-driver\n")
_wrapped = B.build(root, "darwin", driver=str(_drv), label="lint")

if B.read_member(_wrapped, "driver") != _drv.read_bytes():
    bad.append("--driver did not put the driver in the payload byte for byte")
if "AI_DETECTION_SPEC_ROOT" not in _wrapped:
    bad.append("a --driver bundle does not set AI_DETECTION_SPEC_ROOT, which is the whole "
               "interface the driver is handed")
# CHECK MUST BE DRIVER-SENSITIVE. Comparing only the wrapper would pass a bundle carrying
# somebody else's driver, which is the one substitution this hook makes possible.
if not B.matches(_wrapped, root, "darwin", driver=str(_drv), label="lint"):
    bad.append("--check rejects a bundle it has just built with a driver")
if B.matches(_wrapped, root, "darwin", label="lint"):
    bad.append("--check accepts a driver bundle as a plain one -- it is not reading the "
               "payload, so any driver would pass")
# The default bundle must NOT carry one, or every consumer ships a file it did not ask for.
try:
    B.read_member(B.build(root, "darwin", label="lint"), "driver")
    bad.append("a bundle built without --driver carries a driver anyway")
except KeyError:
    pass

# A CORRUPT PAYLOAD IS AN ANSWER, NOT A TRACEBACK. matches() is what --check calls and what
# a consumer's own gate calls, so it must say "this bundle does not carry the tree" rather
# than raise -- a crashed gate reports nothing about the artifact it was asked about. Three
# ways a payload goes wrong, and EOFError (a truncated bundle: half-written, half-copied)
# was the one that got through: base64 raises ValueError, gzip raises OSError on bad magic
# but EOFError on truncation, and tarfile raises TarError on a blob that ungzips to
# something else.
_head, _body, _tail = B._split(_wrapped)
def _corrupt(raw):
    b = base64.b64encode(raw).decode()
    return _head + "\n".join(b[i:i + 76] for i in range(0, len(b), 76)) + _tail
_gz = gzip.compress(os.urandom(4000))          # incompressible: a long DEFLATE stream
for _what, _text in (
        ("a truncated payload", _corrupt(_gz[:20])),
        # MALFORMED DEFLATE IS ITS OWN FAILURE and was the third type this list was short
        # of: zlib.error inherits straight from Exception, and three of four ways of
        # corrupting a stream produce it rather than a gzip or tar error.
        ("malformed DEFLATE", _corrupt(_gz[:10] + bytes(x ^ 0xFF for x in _gz[10:14]) + _gz[14:])),
        ("a failed CRC", _corrupt(_gz[:100] + bytes([_gz[100] ^ 0xFF]) + _gz[101:])),
        ("gzip that is not a tar", _corrupt(gzip.compress(b"not a tar"))),
        ("a body that is not base64", _head + "!!!! not base64 !!!!" + _tail),
        # NOT A BUNDLE AT ALL is the same answer and used to arrive differently: _split()
        # sat outside the wrapped region, so a missing marker came back as a bare
        # ValueError while every other failure came back as CorruptBundle. A caller cannot
        # be asked to catch two things to learn one thing, and this is the commonest
        # mistake there is -- the wrong path.
        ("a file with no payload marker", "#!/bin/bash\nnot a bundle\n"),
        ("an empty file", "")):
    try:
        if B.matches(_text, root, "darwin", driver=str(_drv), label="lint"):
            bad.append(f"matches() accepted {_what}")
    except Exception as exc:
        bad.append(f"matches() raised {type(exc).__name__} on {_what} instead of "
                   f"answering False -- this is what --check calls")
    # And the reader turns every one of them into the SAME exception, so a caller has one
    # thing to catch rather than a list that has now been short three times.
    try:
        B.read_member(_text, "driver")
        bad.append(f"read_member() returned a member out of {_what}")
    except B.CorruptBundle:
        pass
    except Exception as exc:
        bad.append(f"read_member() raised {type(exc).__name__} on {_what}; every decode "
                   f"failure must arrive as CorruptBundle")

# A LABEL IS THE ONLY CALLER TEXT THAT REACHES THE GENERATED SHELL, and it lands in a
# comment line. A newline in it ends the comment and the rest becomes shell, in a file
# that still looks exactly like a bundle. The refusal lives in wrapper(), so --check is
# covered too; asserted here because a guard nothing exercises is a guard that can be
# removed without anything going red.
try:
    B.wrapper("darwin", list(B.payload_files("darwin")), None, "v1\necho pwned")
    bad.append("a --label containing a newline was accepted")
except SystemExit:
    pass

for b in bad:
    print(f"FAIL: bundle: {b}")
if bad:
    sys.exit(1)
print("bundle: ok, both platforms build, carry only endpoint material, embed and compare a "
      "--driver, refuse a label that would escape the banner, and clean up after themselves")
BUNDLE

[ "$fail" -eq 0 ] && echo "osquery lint: PASS" || echo "osquery lint: FAIL"
exit "$fail"
