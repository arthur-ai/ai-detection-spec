#!/usr/bin/env python3
"""Regression tests for tools/ci_scope.py, the gate that decides whether a diff pays for
a runner.

THE ASSERTIONS THAT MATTER ARE THE ONES IN THE EXPENSIVE DIRECTION. A wrong `false` here
does not fail: it skips the scenario matrix on a change that needed it, the pull request
goes green on lint alone, and a signature lands on the strength of a static check --
which is exactly how `bot.molt.mac` got in. A wrong `true` costs runner minutes and
nothing else. So every ambiguous case below is asserted to RUN, and the cheap direction
is asserted only for inputs that are unambiguously prose.
"""
import contextlib
import io
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ci_scope  # noqa: E402

failures = []


def check(label, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}")
    if not ok:
        failures.append(label)
        if detail:
            print(f"        {detail}")


def runs(paths):
    return ci_scope.decide(paths)[0]


print("the cheap direction -- prose only, and nothing else")
check("a README-only diff skips the runners", not runs(["README.md"]))
check("several docs still skip", not runs(["README.md", "docs/deployment.md", "CLAUDE.md"]))
check("a skill's prose skips", not runs([".claude/skills/release/SKILL.md"]))
check("LICENSE skips", not runs(["LICENSE"]))

print()
print("the expensive direction -- anything that is not plainly prose")
check("one query beside a doc runs", runs(["README.md", "queries/browser.sql"]))
check("the catalog runs", runs(["catalog/agents.yaml"]))
# docs/ IS NOT A DOCUMENTATION DIRECTORY. blind-spots.yaml lives there and
# tools/agent_status.py reads it, so the coverage gate -- which runs on a runner --
# depends on it. A rule keyed on the directory rather than the extension would have
# skipped it.
check("docs/blind-spots.yaml runs, despite living under docs/",
      runs(["docs/blind-spots.yaml"]))
check("a workflow edit runs", runs([".github/workflows/scenarios.yml"]))
check("a scenario's expected.json runs", runs(["test/scenarios/00-baseline/expected.json"]))
check("a dotfile nobody listed runs", runs([".gitignore"]))
check("an extension this file has never heard of runs", runs(["queries/new.rq"]))

print()
print("the fail-safe -- a diff nobody could compute is not an empty diff")
check("no computable diff runs everything", runs(None))
check("an empty diff runs everything", runs([]))
check("an all-zero base reports no diff", ci_scope.changed("0" * 40, "HEAD") is None)
# git's complaint about the bad object is the POINT of this case, and it is captured
# rather than shown: lint runs this file with stdout muted, so a stray "fatal:" on
# stderr would read as a failure in a run that passed.
with contextlib.redirect_stderr(io.StringIO()) as _err:
    _missing = ci_scope.changed("dead" * 10, "HEAD")
check("a base that does not exist reports no diff, rather than nothing changed",
      _missing is None)
check("and it says on stderr why it could not tell", "cannot diff" in _err.getvalue(),
      repr(_err.getvalue()))

print()
print("a pull request's merge commit, after main has moved")
# GitHub builds the merge onto main's CURRENT tip, so its first parent is that tip, while
# pull_request.base.sha can still name where the branch was cut. Diffing from there counts
# main's own new commits as the PR's -- run 37833949373 did, and ran the runtime suite for
# a docs-only change. Rebuilt here: main moves under a branch, then GitHub's merge.
#
# THE FIXTURE MUST NOT REACH THE CALLER'S REPOSITORY. Run from a git hook, GIT_DIR and its
# siblings point at the checkout under test, and `git -C <tmp>` still obeys them: measured,
# this block then wrote six commits and a branch into that repository and passed. So every
# variable git itself clears for a submodule is stripped, and the block runs once with a
# hostile GIT_DIR aimed at a sentinel repository that must come out untouched.
_LOCAL_VARS = subprocess.run(["git", "rev-parse", "--local-env-vars"], capture_output=True,
                             text=True, check=True).stdout.split()


def _git(d, *a):
    env = {k: v for k, v in os.environ.items() if k not in _LOCAL_VARS}
    return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True,
                          check=True, env=env).stdout.strip()


def _commit(d, path, msg):
    (pathlib.Path(d) / path).write_text(msg)
    _git(d, "add", path)
    _git(d, "commit", "-qm", msg)
    return _git(d, "rev-parse", "HEAD")


def _new_repo(d):
    _git(d, "init", "-q", "-b", "main")
    _git(d, "config", "user.email", "t@example.com")
    _git(d, "config", "user.name", "t")
    _git(d, "config", "commit.gpgsign", "false")


def _merge_scenario(d):
    _new_repo(d)
    cut = _commit(d, "code.py", "base")
    _git(d, "checkout", "-qb", "pr")
    _commit(d, "notes.md", "docs only")
    _git(d, "checkout", "-q", "main")
    _commit(d, "observed.json", "main moves")
    _git(d, "merge", "-q", "--no-ff", "pr", "-m", "merge")
    merge = _git(d, "rev-parse", "HEAD")
    _git(d, "checkout", "-q", "pr")
    _commit(d, "code.py", "the PR touches code")
    _git(d, "checkout", "-q", "main")
    _git(d, "merge", "-q", "--no-ff", "pr", "-m", "merge again")
    merge2 = _git(d, "rev-parse", "HEAD")
    # ci_scope runs git in the working directory with the inherited environment, so the
    # same variables leave os.environ for these calls and come back afterwards.
    here, saved = os.getcwd(), {k: os.environ.pop(k) for k in _LOCAL_VARS if k in os.environ}
    os.chdir(d)
    try:
        return (ci_scope.changed(cut, merge), ci_scope.changed(f"{merge}^1", merge),
                ci_scope.changed(f"{merge2}^1", merge2))
    finally:
        os.chdir(here)
        os.environ.update(saved)


with tempfile.TemporaryDirectory() as sentinel, tempfile.TemporaryDirectory() as d:
    _new_repo(sentinel)
    _commit(sentinel, "keep", "sentinel")
    _state = lambda: _git(sentinel, "for-each-ref", "--format=%(refname) %(objectname)")
    _before = _state()
    _prior = os.environ.get("GIT_DIR")
    os.environ["GIT_DIR"] = str(pathlib.Path(sentinel) / ".git")
    try:
        stale, fixed, fixed_code = _merge_scenario(d)
    finally:
        if _prior is None:
            del os.environ["GIT_DIR"]
        else:
            os.environ["GIT_DIR"] = _prior
    _after = _state()
check("an inherited GIT_DIR's repository comes out untouched", _after == _before,
      f"before {_before!r}, after {_after!r}")
check("the branch point counts main's own commits as the PR's (the bug)",
      "observed.json" in (stale or []), f"got {stale}")
check("the merge's first parent sees only the PR's change", fixed == ["notes.md"],
      f"got {fixed}")
check("so a docs-only PR stays docs-only", not runs(fixed))
check("and a PR that touches code still runs", runs(fixed_code), f"got {fixed_code}")


def _in(d, fn):
    """Run fn() in repository d, with git's local variables out of the environment."""
    here, saved = os.getcwd(), {k: os.environ.pop(k) for k in _LOCAL_VARS if k in os.environ}
    os.chdir(d)
    try:
        return fn()
    finally:
        os.chdir(here)
        os.environ.update(saved)


# A RENAME IS TWO PATHS. git lists it by its destination alone unless told not to, and the
# source is the one a rule needs: a shared file moved to a `.md` name, or into one
# scenario's directory, would otherwise be scoped by where it went.
with tempfile.TemporaryDirectory() as d:
    _new_repo(d)
    _before = _commit(d, "code.py", "base")
    _git(d, "mv", "code.py", "notes.md")
    _git(d, "commit", "-qm", "rename")
    _moved = _in(d, lambda: ci_scope.changed(_before, "HEAD"))
check("a rename lists the path it left as well as the one it took",
      sorted(_moved or []) == ["code.py", "notes.md"], f"got {_moved}")
check("so code renamed to a .md name still runs", runs(_moved))

# The base is chosen in YAML, so the workflows are checked too: every one that calls
# ci_scope.py on a pull request must pass the merge's first parent.
for _wf in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
    _text = _wf.read_text()
    if "ci_scope.py" not in _text:
        continue
    _base = re.search(r"BASE: \$\{\{(.*?)\}\}", _text, re.S)
    _expr = " ".join(_base.group(1).split()) if _base else ""
    check(f"{_wf.name} scopes a pull request against the merge's first parent",
          "format('{0}^1', github.sha)" in _expr and "base.sha" not in _expr,
          f"BASE is {_expr!r}")

# --- which scenarios ----------------------------------------------------------------------
# The same rule as above: a scenario wrongly excluded is the failure, so each rule is
# asserted first on what it must NOT drop. The cheap direction is asserted only where the
# tree makes it unambiguous.
import copy  # noqa: E402
import json  # noqa: E402
import yaml  # noqa: E402

_WF = yaml.safe_load((ROOT / ci_scope.SCENARIOS_WORKFLOW).read_text())
_JOBS = ci_scope.matrix_lists(_WF)
_LISTED = set().union(*_JOBS.values())
_PLAT = {n: json.loads((ROOT / "test" / "scenarios" / n / "expected.json").read_text())
         .get("platform") for n in _LISTED}
DARWIN = {n for n, p in _PLAT.items() if p == "darwin"}
LINUX = {n for n, p in _PLAT.items() if p == "linux"}


def _replaced(text, old, new):
    """A fixture edit that must actually edit. A no-op replace leaves base == head, and a
    scoping test then fails for a stale literal while reading as a scoping bug."""
    assert text.count(old) == 1, f"fixture literal {old!r} is stale: found {text.count(old)}"
    return text.replace(old, new)


def _reader(base=None, head=None):
    """The working tree on both sides, with per-side overrides; None deletes a file."""
    def read(side, path):
        over = (base if side == "base" else head) or {}
        if path in over:
            return over[path]
        p = ROOT / path
        return p.read_text() if p.exists() else None
    return read


def scenarios(paths, base=None, head=None):
    """The set of scenarios the outputs run, checked for self-consistency on the way."""
    out, _ = ci_scope.scenarios_outputs(paths, _reader(base, head))
    o = dict(line.split("=", 1) for line in out)
    ran = set()
    for job, names in _JOBS.items():
        drop = {d["scenario"] for d in json.loads(o[ci_scope.output_key("exclude", job)])}
        keep = [n for n in names if n not in drop]
        if (o[ci_scope.output_key("skip", job)] == "true") != (not keep):
            check(f"skip_{job} agrees with its exclusion for {paths}", False)
        ran |= set(keep)
    if (o["runtime"] == "true") != bool(ran):
        check(f"runtime agrees with the selection for {paths}", False)
    return ran


_cat = (ROOT / ci_scope.CATALOG).read_text()
_catdoc = yaml.safe_load(_cat)


def _expected(name):
    return json.loads((ROOT / "test" / "scenarios" / name / "expected.json").read_text())


def _observed(name):
    p = ROOT / "test" / "scenarios" / name / "observed.json"
    return json.loads(p.read_text()) if p.exists() else {}


def _with_agent(agent, **change):
    doc = copy.deepcopy(_catdoc)  # not a JSON round trip: superseded records carry dates
    for a in doc["agents"]:
        if a["id"] == agent:
            a.update(change)
    return {ci_scope.CATALOG: yaml.safe_dump(doc)}


def _edit(agent):
    """The catalog with one agent's entry changed, and nothing else."""
    return scenarios([ci_scope.CATALOG], head=_with_agent(agent, name="edited"))


print()
print("which scenarios -- a diff that cannot be read runs every one")
check("no computable diff runs every scenario", scenarios(None) == _LISTED)
check("an empty diff runs every scenario", scenarios([]) == _LISTED)
check("an unrecognised path runs every scenario", scenarios(["new/thing.txt"]) == _LISTED)
check("bin/classify runs every scenario", scenarios(["bin/classify"]) == _LISTED)
check("tools/agent_status.py runs every scenario, since every job records through it",
      scenarios(["tools/agent_status.py"]) == _LISTED)
check("a catalog that does not parse runs every scenario",
      scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: "agents: ["}) == _LISTED)
check("a catalog with no base runs every scenario",
      scenarios([ci_scope.CATALOG], base={ci_scope.CATALOG: None}) == _LISTED)
check("a catalog edit outside `agents:` runs every scenario",
      scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: _replaced(
          _cat, "\nversion: 2\n", "\nversion: 3\n")}) == _LISTED)
_out, _ = ci_scope.scenarios_outputs(None, _reader())
check("and every scenario means every exclusion is empty, the direction that runs more",
      all(line.endswith("=[]") for line in _out if line.startswith("exclude_")), str(_out))

print()
print("which scenarios -- as the workflow calls it, reading both sides through git")
# Every case above reads the working tree. This is the path CI takes: `git show rev:path`
# on each side of a real diff, in a repository built to hold two scenarios and one change.
_mini_wf = ("name: s\njobs:\n  scenario:\n    strategy:\n      matrix:\n"
            "        scenario: [a, b]\n")
with tempfile.TemporaryDirectory() as d:
    _new_repo(d)
    for _n, _agent in (("a", "x"), ("b", "y")):
        (pathlib.Path(d) / "test" / "scenarios" / _n).mkdir(parents=True)
        (pathlib.Path(d) / "test" / "scenarios" / _n / "expected.json").write_text(json.dumps(
            {"platform": "darwin", "classified": {"must_find": [_agent]}}))
    (pathlib.Path(d) / ".github" / "workflows").mkdir(parents=True)
    (pathlib.Path(d) / ci_scope.SCENARIOS_WORKFLOW).write_text(_mini_wf)
    (pathlib.Path(d) / "catalog").mkdir()
    _commit(d, ci_scope.CATALOG, "agents:\n  - {id: x, name: X}\n  - {id: y, name: Y}\n")
    _git(d, "add", "-A")
    _git(d, "commit", "-qm", "scenarios")
    _b = _git(d, "rev-parse", "HEAD")
    _h = _commit(d, ci_scope.CATALOG, "agents:\n  - {id: x, name: X2}\n  - {id: y, name: Y}\n")
    _o, _ = _in(d, lambda: ci_scope.scenarios_outputs(ci_scope.changed(_b, _h),
                                                       ci_scope.git_reader(_b, _h)))
    _r = _in(d, lambda: ci_scope.git_reader(_b, _h))
    _base_x = _in(d, lambda: _r("base", ci_scope.CATALOG))
check("an edit to agent x, read through git, runs a and excludes b",
      _o == ["runtime=true", "skip_scenario=false",
             'exclude_scenario=[{"scenario":"b"}]'], str(_o))
check("the base side reads the base commit", "X2" not in (_base_x or "X2"), repr(_base_x))
check("an all-zero base reads as absent, never as the head",
      ci_scope.git_reader("0" * 40, "HEAD")("base", "README.md") is None)

print()
print("which scenarios -- a catalog edit runs every scenario that can see it")
check("the scenarios that must find an agent run when it changes",
      {"87-linux-pi", "88-linux-pi-legacy"} <= _edit("pi"), str(sorted(_edit("pi"))))
# A forbid is the over-matching guard, so it is the link most worth keeping.
check("a scenario that only FORBIDS an agent runs when it changes",
      {"70-linux-baseline", "71-linux-cli-agents"} <= _edit("cursor"))
_fe = {n for n in _LISTED if (_expected(n).get("classified") or {}).get("forbid_evidence")}
check("forbid_evidence names no agent, so its scenarios run on any agent edit",
      bool(_fe) and _fe <= _edit("pi"), f"{sorted(_fe)}")
# A scenario with forbid_evidence would run anyway, so it cannot show the observed link.
_obs = []
for _n in sorted(_LISTED - _fe):
    _c = _expected(_n).get("classified") or {}
    _named = set(_c.get("must_find", [])) | set(_c.get("forbid", []))
    _obs += [(_n, r["agent"]) for r in _observed(_n).get("identifiers", [])
             if r["agent"] not in _named]
check("an agent a scenario only OBSERVED runs that scenario",
      bool(_obs) and _obs[0][0] in _edit(_obs[0][1]), f"{_obs[:1]}")
# Chosen from the tree, not by name: pi was the fixture until 20-cli-agents installed it.
_darwin_seen = set()
for _n in DARWIN:
    _c, _o = _expected(_n).get("classified") or {}, _observed(_n)
    _darwin_seen |= set(_c.get("must_find", [])) | set(_c.get("forbid", []))
    _darwin_seen |= {r["agent"] for r in _o.get("identifiers", []) + _o.get("archived", [])}
_unseen = sorted(a["id"] for a in _catdoc["agents"] if a["id"] not in _darwin_seen)
check("an edit to an agent no macOS scenario names or observed runs none of them",
      bool(_unseen) and not (_edit(_unseen[0]) & DARWIN),
      f"{_unseen[:1]}: {sorted(_edit(_unseen[0]) & DARWIN)}" if _unseen else "no such agent")


def _order(agents):
    doc = copy.deepcopy(_catdoc)
    doc["agents"] = agents
    return scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: yaml.safe_dump(doc)})


# Order decides which of two agents claims a row both match, so a flipped pair is two
# changed agents -- and no more than that.
_A = _catdoc["agents"]
_ids = [a["id"] for a in _A]
check("swapping two agents runs what editing either would",
      _order([_A[1], _A[0]] + _A[2:]) == _edit(_ids[0]) | _edit(_ids[1]))
_moved3 = _order(_A[1:4] + [_A[0]] + _A[4:])
check("moving one agent past three others runs what editing all four would",
      _moved3 == _edit(_ids[0]) | _edit(_ids[1]) | _edit(_ids[2]) | _edit(_ids[3]),
      str(sorted(_moved3)))
check("and runs less than every scenario", _moved3 != _LISTED)
check("an agent added mid-list reorders nobody", _order(
    _A[:5] + [{"id": "zz-new", "name": "New", "classification": "Coding agent",
               "platforms": ["linux"]}] + _A[5:]) == _fe)
check("a catalog comment runs nothing",
      scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: _cat + "\n# a note\n"}) == set())
check("the rendered files add nothing beside a catalog edit",
      scenarios([ci_scope.CATALOG, "dist/signatures.sql", "dist/agents-darwin.sql"],
                head=_with_agent("pi", name="edited")) == _edit("pi"))
check("but without one, dist/signatures.sql runs every scenario",
      scenarios(["dist/signatures.sql"]) == _LISTED)
check("and dist/agents-linux.sql runs the Linux ones", scenarios(["dist/agents-linux.sql"]) == LINUX)

print()
print("which scenarios -- by platform")
check("dist/discovery-darwin.sql runs exactly the macOS scenarios",
      scenarios(["dist/discovery-darwin.sql"]) == DARWIN)
check("dist/discovery-linux.sql runs exactly the Linux scenarios",
      scenarios(["dist/discovery-linux.sql"]) == LINUX)
DEEP = {n for n in _LISTED if _expected(n).get("deep")}
check("the deep artifact runs the deep scenarios, the only ones that run bin/discover",
      bool(DEEP) and scenarios(["dist/discovery-deep.sql"]) == DEEP, str(sorted(DEEP)))
check("so does the pack", scenarios(["dist/ai-discovery.conf"]) == DEEP)
# What a darwin query edit actually touches, so the platform rule is seen to save something.
_dq = scenarios(["queries/runtime.sql", "dist/discovery-darwin.sql", "dist/agents-darwin.sql",
                 "dist/ai-discovery.conf"])
check("a darwin query PR, with its generated files, runs no Linux scenario but the deep one",
      _dq == DARWIN | DEEP, str(sorted(_dq - DARWIN)))
# A scenario whose own facts cannot be read is run by every rule that consults them.
check("an unreadable expected.json is run by a rule for the other platform",
      "00-baseline" in scenarios(["dist/discovery-linux.sql"], head={
          "test/scenarios/00-baseline/expected.json": "{not json"}))
check("an unreadable setup.sh is run by a setup-library rule",
      "00-baseline" in scenarios(["test/lib/guest-linux.sh"], head={
          "test/scenarios/00-baseline/setup.sh": None}))
_q = {re.search(r"^-- platform:\s*(\w+)", p.read_text(), re.M).group(1): p
      for p in sorted((ROOT / "queries").glob("*.sql"))}
for _p, _want in (("linux", LINUX), ("darwin", DARWIN), ("posix", _LISTED)):
    _path = str(_q[_p].relative_to(ROOT))
    check(f"a {_p} query ({_path}) runs {'every scenario' if _p == 'posix' else _p}",
          scenarios([_path]) == _want)
_gl = scenarios(["test/lib/guest-linux.sh"])
check("guest-linux.sh runs Linux scenarios that source it, and no macOS one",
      bool(_gl) and _gl <= LINUX, str(sorted(_gl)))
_gm = scenarios(["test/lib/guest.sh"])
check("guest.sh runs macOS scenarios that source it, and no Linux one",
      bool(_gm) and _gm <= DARWIN, str(sorted(_gm)))

print()
print("which scenarios -- the cheap direction, where it is unambiguous")
check("a scenario's own file runs that scenario alone",
      scenarios(["test/scenarios/00-baseline/setup.sh"]) == {"00-baseline"})
check("a scenario no job lists runs nothing", scenarios(["test/scenarios/90-demo-fleet/setup.sh"])
      == set())
check("docs only runs nothing", scenarios(["README.md", "docs/agents.md"]) == set())
check("another workflow runs nothing", scenarios([".github/workflows/docs.yml"]) == set())
check("dist/fleet-policies.yml runs nothing: no scenario reads it",
      scenarios(["dist/fleet-policies.yml"]) == set())
check("an INERT check runs nothing", scenarios(["test/lint.sh", "tools/validate_catalog.py"])
      == set())
check("docs/blind-spots.yaml runs nothing", scenarios(["docs/blind-spots.yaml"]) == set())

_wft = (ROOT / ci_scope.SCENARIOS_WORKFLOW).read_text()
_W = ci_scope.SCENARIOS_WORKFLOW
check("a comment in scenarios.yml runs nothing",
      scenarios([_W], base={_W: _replaced(_wft, "\non:\n", "\n# a note\non:\n")}) == set())
check("a scenario added to a matrix runs that scenario alone",
      scenarios([_W], base={_W: _replaced(_wft, "          - 57-clawdbot-era\n", "")})
      == {"57-clawdbot-era"})
check("any other edit to scenarios.yml runs every scenario",
      scenarios([_W], base={_W: _replaced(_wft, "timeout-minutes: 50", "timeout-minutes: 49")})
      == _LISTED)
check("scenarios.yml with no base runs every scenario",
      scenarios([_W], base={_W: None}) == _LISTED)
# When a run starts and what it is called are not what a job does.
check("a cron edit to scenarios.yml runs nothing",
      scenarios([_W], base={_W: _replaced(_wft, 'cron: "0 6 * * 1"', 'cron: "0 7 * * 1"')})
      == set())
check("a concurrency edit to scenarios.yml runs nothing",
      scenarios([_W], base={_W: _replaced(
          _wft, "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
          "cancel-in-progress: false")}) == set())

# ci.yml reaches a scenario through its lint job alone, which runs the gates the catalog
# and rendered-SQL rules lean on. Its other jobs are one runner each and define only
# themselves.
_cit = (ROOT / ci_scope.CI_WORKFLOW).read_text()
_C = ci_scope.CI_WORKFLOW
check("an edit to ci.yml's lint job runs every scenario",
      scenarios([_C], base={_C: _replaced(_cit, "run: test/lint.sh", "run: test/lint.sh -v")})
      == _LISTED)
check("an edit to ci.yml outside its lint job runs nothing",
      scenarios([_C], base={_C: _replaced(_cit, "QUERY_FAIL_S: 60", "QUERY_FAIL_S: 61")})
      == set())
check("ci.yml with no base runs every scenario", scenarios([_C], base={_C: None}) == _LISTED)


# --- INERT is checked, not trusted -------------------------------------------------------
def reachable(through_scenarios=True):
    """Every tracked file a scenarios.yml job can reach: what its steps name, then whatever
    a reached SCRIPT names -- an import, a string constant, a non-comment line. Data files
    are read rather than followed. Generous on purpose: a false reach only keeps a file
    out of INERT, which costs minutes, never a skipped scenario."""
    files = [p for p in _git(str(ROOT), "ls-files").split()
             if p.split("/")[0] in ("test", "tools", "bin", "dist", "queries", "catalog")
             and (through_scenarios or not p.startswith("test/scenarios/"))]

    def names(path, text):
        if path.endswith(".py") or text.startswith("#!/usr/bin/env python"):
            import ast
            try:
                tree = ast.parse(text)
            except SyntaxError:
                return set(), text
            mods = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import)
                    for a in n.names}
            mods |= {n.module.split(".")[0] for n in ast.walk(tree)
                     if isinstance(n, ast.ImportFrom) and n.module}
            # Every string but a docstring, which is prose: a multi-line string can hold a
            # shell command as easily as a sentence.
            docs = {id(n.body[0].value) for n in ast.walk(tree)
                    if isinstance(n, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                      ast.AsyncFunctionDef))
                    and n.body and isinstance(n.body[0], ast.Expr)
                    and isinstance(n.body[0].value, ast.Constant)}
            return mods, "\n".join(n.value for n in ast.walk(tree)
                                   if isinstance(n, ast.Constant) and isinstance(n.value, str)
                                   and id(n) not in docs)
        return set(), "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

    def hits(path, text):
        import fnmatch
        mods, blob = names(path, text)
        # A glob reaches every file whose name it matches, wherever it is rooted --
        # `(ROOT / "tools").glob("check_*.py")` names no file and runs several.
        globs = {w.rsplit("/", 1)[-1] for w in re.findall(r"[\w.*/-]*\*[\w.*-]*", blob)}
        out = set()
        for f in files:
            base = f.rsplit("/", 1)[-1]
            if f in blob or base in blob or base.removesuffix(".py") in mods \
                    or any(fnmatch.fnmatch(base, g) for g in globs if g.strip("*")):
                out.add(f)
            # A directory named alone is globbed, file by file -- `ROOT / "queries"`. Not
            # for the roots: every script names those to build any path at all.
            parent = f.split("/")[-2]
            if parent not in ("test", "tools", "bin", "dist", "catalog") and \
                    re.search(rf"^{re.escape(parent)}$", blob, re.M):
                out.add(f)
        return out

    seed = "\n".join(str(s.get("run", "")) for j in _WF["jobs"].values()
                     for s in j.get("steps", []))
    seen = hits("scenarios.yml", seed)
    todo = list(seen)
    while todo:
        f = todo.pop()
        text = (ROOT / f).read_text(errors="replace")
        if not (f.endswith((".py", ".sh")) or text.startswith("#!")):
            continue
        # ci_scope.py names INERT and SETUP_LIBS in order to classify them, and runs none.
        if f == "tools/ci_scope.py":
            continue
        for g in hits(f, text) - seen:
            seen.add(g)
            todo.append(g)
    return seen


print()
print("INERT and SETUP_LIBS, against what the scenario jobs can actually reach")
_reach = reachable()
# The positive controls: without them a broken analysis that reached nothing would pass
# the INERT check below by having looked at nothing.
for _f in ("bin/classify", "tools/agent_status.py", "test/test_match_sql.py",
           "tools/build.py", "test/lib/guest-linux.sh"):
    check(f"the analysis reaches {_f}", _f in _reach)
_tracked = set(_git(str(ROOT), "ls-files").split())
check("every INERT path is a tracked file", ci_scope.INERT <= _tracked,
      str(sorted(ci_scope.INERT - _tracked)))
check("no scenario job can reach an INERT path", not (ci_scope.INERT & _reach),
      f"remove from INERT: {sorted(ci_scope.INERT & _reach)}")
_shared = reachable(through_scenarios=False)
check("SETUP_LIBS are reached only through scenario setup scripts",
      not (set(ci_scope.SETUP_LIBS) & _shared),
      f"reached otherwise: {sorted(set(ci_scope.SETUP_LIBS) & _shared)}")

print()
print("the command line, as the workflow actually calls it")
out = subprocess.run([sys.executable, str(ROOT / "tools" / "ci_scope.py"),
                      "--paths", "README.md"], capture_output=True, text=True)
check("stdout is GITHUB_OUTPUT form and nothing else",
      out.stdout == "runtime=false\n", repr(out.stdout))
check("the reason goes to stderr, where a log shows it", "documentation" in out.stderr,
      repr(out.stderr))
check("it exits 0 either way", out.returncode == 0, str(out.returncode))
# From the repository root, as the workflow runs it: --paths reads the working tree.
out = subprocess.run([sys.executable, "tools/ci_scope.py", "--scenarios", "--paths",
                      "test/scenarios/00-baseline/setup.sh"],
                     capture_output=True, text=True, cwd=ROOT)
_lines = out.stdout.splitlines()
check("--scenarios writes only GITHUB_OUTPUT lines",
      out.returncode == 0 and _lines[0] == "runtime=true"
      and all(re.fullmatch(r"(skip|exclude)_\w+=.+", l) for l in _lines[1:]), out.stdout)
check("one skip and one exclude per matrix job", len(_lines) == 1 + 2 * len(_JOBS),
      str(len(_lines)))

print()
if failures:
    print(f"ci_scope: FAIL ({len(failures)})")
    sys.exit(1)
print("ci_scope: PASS")
