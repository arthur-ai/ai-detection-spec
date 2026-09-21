#!/usr/bin/env bash
# Static checks on the query and scenarios. No VM, and no network beyond a loopback socket
# the telemetry suite binds for itself — 11.4s measured here, so CI can gate on it and a VM
# run never burns 20 minutes on a typo. It was about one second before test_telemetry.py
# joined it, and most of the difference is that suite waiting out a sender it has pointed
# at an endpoint which never answers. That wait is the assertion: shortening it would mean
# not proving the bound.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
# A TEST RUN IS NOT A USE, and bin/classify sends one usage event per run. `CI` already
# suppresses it on a runner, but a scenario guest is a fresh VM or container that inherits
# nothing, and a maintainer's own machine has no CI set at all -- so the suite would post
# an event for every fixture it classifies and the field data would be mostly us. Set
# explicitly rather than relied upon: see docs/telemetry.md.
export AI_DISCOVERY_TELEMETRY=0

for q in "$HERE"/../queries/*.sql; do
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
python3 - "$HERE/../queries" <<'ALIASES' || fail=1
import glob, os, re, sys
COLS = ["kind", "id", "ver", "loc", "extra", "perms"]
bad = False
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.sql"))):
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

python3 - "$HERE" <<'PY' || fail=1
import glob, json, os, re, sys
here = sys.argv[1]
root = os.path.dirname(here)

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
QUERY_DIR = os.path.join(root, "queries")
EMITTED = {}          # platform -> kinds its fast/slow queries emit
EMITTED_DEEP = {}     # platform -> kinds only the `expensive` queries emit
PRODUCERS = {}        # kind -> set of query files emitting it
for q in sorted(glob.glob(os.path.join(QUERY_DIR, "*.sql"))):
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
for f in sorted(glob.glob(os.path.join(here, "scenarios/*/expected.json"))):
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
        if k not in want:
            print(f"FAIL: {name} ({platform}) pins {k!r}, which no {platform} route "
                  f"produces"); bad = True
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

# THE CHECKER IS CHOSEN BY THE SHEBANG, not by one rule for every scenario.
#
# The macOS scenarios are zsh because that is macOS's default shell; the Linux ones are
# bash because that is what a Linux runner and a container both have. Checking a bash
# script with `zsh -n` mostly works, which is the problem -- it would pass until someone
# used a bash-only construct, and then report a syntax error in the wrong dialect.
#
# zsh is still REQUIRED rather than skipped when missing: letting the check dissolve into
# "command not found" would leave every macOS scenario unchecked while the suite stayed
# green. The linter runs on ubuntu in CI, which is why ci.yml apt-installs zsh.
if ! command -v zsh >/dev/null; then
  echo "FAIL: zsh not found. It is needed to syntax-check the macOS scenario scripts."
  echo "      macOS ships it; on Debian/Ubuntu: sudo apt-get install -y zsh"
  fail=1
else
  for f in "$HERE"/scenarios/*/setup.sh "$HERE"/lib/guest.sh "$HERE"/lib/guest-linux.sh; do
    case "$(head -1 "$f")" in
      *zsh*)  zsh -n  "$f" || { echo "FAIL: zsh syntax in $f";  fail=1; } ;;
      *bash*) bash -n "$f" || { echo "FAIL: bash syntax in $f"; fail=1; } ;;
      *) echo "FAIL: $f has no zsh or bash shebang, so nothing can syntax-check it"
         fail=1 ;;
    esac
  done
fi
for f in "$HERE"/run.sh "$HERE"/lib/vm.sh "$HERE"/lib/assert.sh \
         "$HERE"/docker_states.sh "$HERE"/../bin/container-scan "$HERE"/../bin/discover ; do
  bash -n "$f" || { echo "FAIL: bash syntax in $f"; fail=1; }
done

# ONE WAY TO BECOME THE SCENARIO USER, and only one.
#
# test/lib/guest-linux.sh had two: as_user, which scrubs the environment with `env -i`, and
# try_user, which had grown its own `su - "$user" -c`. Fixing one and not the other cost
# three CI rounds, because the scenarios that used the wrong one failed with an error
# (EACCES on $XDG_CONFIG_HOME) that pointed at the tool rather than at the helper. Any new
# `su` in that file is that mistake again.
# CODE ONLY, not the comments that explain the mistake -- two of the three matches were
# the note describing the wrong form, and a check that counts its own documentation is a
# check nobody can satisfy.
_su_count=$(grep -vE '^\s*#' "$HERE/lib/guest-linux.sh" \
            | grep -cE '(^|[^a-z_-])su ' || true)
if [ "${_su_count:-0}" -gt 1 ]; then
  echo "FAIL: guest-linux.sh invokes \`su\` $_su_count times. as_user is the only place"
  echo "      that should: it is what scrubs the environment, and a second copy leaks the"
  echo "      caller's XDG_* to the scenario user. Route it through as_user."
  fail=1
else
  echo "guest-linux.sh: one way to become the scenario user"
fi

# bin/container-scan is SOURCED by test/docker_states.sh and by bin/discover, so that it
# lends out the guard and the bound rather than having them copied. Two things can break
# that silently: deleting the `(return 0 2>/dev/null) && return 0` line, after which
# sourcing runs a live scan; and renaming a function the callers use.
bash -c '. "'"$HERE"'/../bin/container-scan" && type -t run_bounded docker_healthy docker_socket_path marker json_str json_row osq_run json_concat pack_branches merge_sql merge_branches >/dev/null' \
  || { echo "FAIL: bin/container-scan is no longer safely sourceable, or a shared function was renamed"; fail=1; }

# NOTHING ON THE ENDPOINT IS PYTHON, AND THE FAILURE IT PREVENTS IS SILENCE RATHER THAN AN
# ERROR. These two scripts run on managed Macs where /usr/bin/python3 is a STUB -- no Command
# Line Tools, so it prints an install prompt on stderr and exits 1 with empty stdout. That
# took the no-cache marker with it: the one row whose whole job is to say the writer never
# ran was built by the interpreter that stopped the writer, so a collector saw nothing, and
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
for _f in "$HERE/../bin/discover" "$HERE/../bin/container-scan"; do
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

# ONE expensive query, and the check exists because the second one is a trap.
# dist/discovery-deep.sql is run by bin/container-scan behind a guard that is specific to
# Docker: a round trip to /_ping demanding HTTP 200. A second expensive branch composed
# into the same artifact would inherit that guard, which says nothing whatsoever about
# whatever daemon or directory the new branch blocks on -- and it would be bounded by a
# wall clock sized for this one. When that day comes, split the artifact per branch and
# give each its own guard. Do not delete this check to make the build pass.
python3 - "$HERE/.." <<'PY' || fail=1
import glob, os, re, sys
root = sys.argv[1]
expensive = [os.path.basename(f) for f in sorted(glob.glob(os.path.join(root, "queries/*.sql")))
             if re.search(r"^--\s*cost:\s*expensive", open(f).read(), re.M)]
if len(expensive) > 1:
    print(f"FAIL: {len(expensive)} expensive queries ({', '.join(expensive)}), and they would "
          "share one wall clock and one Docker-specific health guard in "
          "dist/discovery-deep.sql. Split the artifact per branch first; see the comment "
          "above this check in test/lint.sh.")
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
python3 - "$HERE/../dist/ai-discovery.conf" <<'PY' || fail=1
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
python3 "$HERE/../tools/validate_catalog.py" || fail=1
python3 "$HERE/../tools/build.py" --check || fail=1
python3 "$HERE/../test/test_matcher.py" >/dev/null || { echo "FAIL: matcher tests"; fail=1; }
python3 "$HERE/../test/test_telemetry.py" >/dev/null || { echo "FAIL: telemetry tests"; fail=1; }
python3 "$HERE/../tools/check_workflows.py" || fail=1
python3 "$HERE/../tools/check_no_catalog.py" || fail=1
# docs/agents.md is generated from the catalog and its coverage, exactly as dist/ is
# generated from queries/. Gated here so a contributor sees it locally in seconds rather
# than finding out from a red PR -- and so the doc cannot quietly describe a catalog that
# has moved on without it, which is the same failure this repo keeps having in other forms.
# A SUBMODULE YOU DID NOT IMPORT. `import importlib.util` leaves importlib.machinery
# resolvable on a developer Mac -- something in site-packages has already imported it -- and
# raises AttributeError on a clean interpreter. Verified: `python3 -S -c "import
# importlib.util; importlib.machinery.SourceFileLoader"` fails here, plain python3 does not.
#
# It cost every scenario job in one CI run, in the step that records coverage, and no gate
# could have caught it because the local interpreter resolves the name perfectly.
python3 - "$HERE/.." <<'PYEOF' || fail=1
import ast, pathlib, sys

# Submodules that are NOT loaded by importing the parent package. os.path is absent from
# this list on purpose: it is bound as an attribute of os at interpreter start.
LAZY = {"importlib": {"machinery", "util", "resources", "metadata", "abc"},
        "concurrent": {"futures"},
        "xml": {"etree", "dom", "sax"},
        "collections": {"abc"}}
bad = []
for path in sorted(pathlib.Path(sys.argv[1]).glob("*/*.py")):
    if ".git" in path.parts:
        continue
    tree = ast.parse(path.read_text())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                imported.add(a.name)
                imported.add(a.name.split(".")[0])
    for node in ast.walk(tree):
        # Match the shape `parent.child.something`, i.e. Attribute(Attribute(Name)).
        if not (isinstance(node, ast.Attribute)
                and isinstance(node.value, ast.Attribute)
                and isinstance(node.value.value, ast.Name)):
            continue
        parent, child = node.value.value.id, node.value.attr
        if child in LAZY.get(parent, ()) and f"{parent}.{child}" not in imported:
            bad.append(f"{path}:{node.lineno}: uses {parent}.{child} but never "
                       f"imports it. Resolvable here, AttributeError on a clean "
                       f"interpreter -- add `import {parent}.{child}`.")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PYEOF

# --pending-ok ON BOTH, AND IT IS NOT A WEAKENING. This file is static: it reads the
# observations committed to the tree, and those are written by scenarios.yml's `collect`
# job, which is main-only so that a pull request cannot move recorded coverage. On the PR
# that ADDS a signature the observations therefore predate it, and a correctly covered
# identifier is indistinguishable here from one a scenario ran and failed to produce.
#
# Left strict, that made every signature PR red by construction, and the only available
# fix was to merge it anyway -- which teaches people that this red means nothing, and the
# next red is read the same way.
#
# What lint still refuses is the part it CAN answer: an identifier no CI scenario even
# claims. What it defers is whether a claimed one appeared, which is settled by the
# `coverage` job in scenarios.yml against that run's own observations. Both halves are
# gates, neither is advisory, and tools/agent_status.py's _pending() carries the argument.
python3 "$HERE/../tools/agent_status.py" --check --pending-ok || fail=1
# Nothing ships in the catalog without a real test.
python3 "$HERE/../tools/agent_status.py" --gate --pending-ok || fail=1
# Prose goes stale silently; generated pages cannot. This checks the numbers a human wrote.
python3 "$HERE/../tools/check_doc_numbers.py" || fail=1
# --json separately, because it exercises a code path --check does not. An unquoted
# YYYY-MM-DD in the catalog resolves to a datetime.date, which json.dumps cannot
# serialise -- so --json died while --check and --write, which never read the field,
# both passed clean. One gate per output format, or a format breaks unobserved.
python3 "$HERE/../tools/agent_status.py" --json >/dev/null \
  || { echo "FAIL: agent_status.py --json does not serialise"; fail=1; }

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
  python3 "$HERE/../tools/bundle.py" --platform "$_p" --out "$_bundle_tmp/$_p.sh" >/dev/null \
    || { echo "FAIL: tools/bundle.py --platform $_p did not build"; fail=1; _bundle_ok=0; continue; }
  # GENERATED SHELL IS EXACTLY THE SHELL NOBODY READS. A wrapper edit in bundle.py produces
  # this file unexamined, and bash reports a syntax error only when a fleet runs it.
  bash -n "$_bundle_tmp/$_p.sh" \
    || { echo "FAIL: bash syntax in the $_p bundle"; fail=1; _bundle_ok=0; }
  # The check mode is what a consumer committing a bundle depends on, so it is exercised
  # rather than assumed -- a --check that cannot fail is worse than no --check.
  python3 "$HERE/../tools/bundle.py" --platform "$_p" --check "$_bundle_tmp/$_p.sh" >/dev/null \
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
      *"runs on"*only*) : ;;
      *) echo "FAIL: the $_other bundle refused without naming the cause: $_out"; fail=1 ;;
    esac
  fi
fi

python3 - "$HERE/.." "$_bundle_tmp" <<'BUNDLE' || fail=1
import base64, gzip, io, pathlib, re, sys, tarfile
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

    # THE ENDPOINT HOLDS NO CATALOG, and this is the check that survives someone adding a
    # file to the list for a good-sounding reason. A machine carrying the signatures it is
    # supposed to enumerate past is the one outcome the architecture exists to prevent.
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

for b in bad:
    print(f"FAIL: bundle: {b}")
if bad:
    sys.exit(1)
print("bundle: ok, both platforms build, carry only endpoint material and clean up after "
      "themselves")
BUNDLE

[ "$fail" -eq 0 ] && echo "lint: PASS" || echo "lint: FAIL"
exit "$fail"
