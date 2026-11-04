#!/usr/bin/env python3
"""Regression tests for tools/ci_scope.py, the gate that decides whether a diff pays for
a runner.

THE ASSERTIONS THAT MATTER ARE THE ONES IN THE EXPENSIVE DIRECTION. A wrong `false` here
does not fail: it skips the scenario matrix on a change that needed it, the pull request
goes green on lint alone, and a signature lands on the strength of a static check --
which is exactly how `bot.molt.mac` got in. A wrong `true` costs runner minutes and
nothing else. So every ambiguous case below is asserted to RUN, and the cheap direction
is asserted only for inputs that are unambiguously prose or that the reachability
analysis at the end proves no gated job can read.
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
import scenarios as scenarios_lib  # noqa: E402  (this file's scenarios() is the selection)

failures = []


def check(label, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}")
    if not ok:
        failures.append(label)
        if detail:
            print(f"        {detail}")


def runs(paths):
    return ci_scope.decide(paths)[0]


print("the cheap direction -- prose, and the paths no runtime job is proven to reach")
check("a README-only diff skips the runners", not runs(["README.md"]))
check("several docs still skip", not runs(["README.md", "osquery/docs/deployment.md", "CLAUDE.md"]))
check("a skill's prose skips", not runs([".claude/skills/release/SKILL.md"]))
check("LICENSE skips", not runs(["LICENSE"]))
# EACH OF THESE IS PROVEN AT THE END of this file against what ci.yml's runtime jobs run;
# here, only that the rule reads them as the proof says. On 2026-11-03 a one-file change
# to a Windows scenario's setup.ps1 booted all three runtime VMs, twice, and a change to
# the recorder that only lint and the scenario jobs run did the same.
check("a scenario's own files skip the runtime jobs; scenarios.yml runs the scenario",
      not runs(["test/scenarios/00-baseline/expected.json",
                "test/scenarios/104-windows-browser/setup.ps1"]))
check("a recorder skips", not runs(["tools/merge_observations.py", "tools/agent_status.py"]))
check("scenarios.yml skips: ci.yml's jobs are its own", not runs([".github/workflows/scenarios.yml"]))
# docs/ IS NOT A DOCUMENTATION DIRECTORY: blind-spots.yaml is data. It skips because
# tools/agent_status.py, which reads it, runs under lint, and lint is not gated.
check("docs/blind-spots.yaml skips, as a proven RUNTIME_INERT member and not as docs/",
      not runs(["docs/blind-spots.yaml"]) and "docs/blind-spots.yaml" in ci_scope.RUNTIME_INERT)

print()
print("the expensive direction -- anything that is not plainly prose or proven unreached")
check("one query beside a doc runs", runs(["README.md", "osquery/queries/browser.sql"]))
check("the catalog runs", runs(["catalog/agents.yaml"]))
check("a matcher fixture runs: osquery/test/test_match_sql.py reads them on a runner",
      runs(["test/fixtures/known-agents.json"]))
check("ci.yml itself runs", runs([".github/workflows/ci.yml"]))
check("a scenario file beside an artifact runs",
      runs(["test/scenarios/00-baseline/setup.sh", "osquery/dist/discovery-darwin.sql"]))
check("a scenario-shaped path outside test/scenarios/ runs", runs(["scenarios/00-baseline/setup.sh"]))
check("a dotfile nobody listed runs", runs([".gitignore"]))
check("an extension this file has never heard of runs", runs(["osquery/queries/new.rq"]))

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
_JOBS = ci_scope.job_scenarios(_WF)
_HARNESS = ci_scope.harness_jobs(_WF)
_LISTED = set().union(*_JOBS.values())
_PLAT = {n: json.loads((ROOT / "test" / "scenarios" / n / "expected.json").read_text())
         .get("platform") for n in _LISTED}
DARWIN = {n for n, p in _PLAT.items() if p == "darwin"}
LINUX = {n for n, p in _PLAT.items() if p == "linux"}
WINDOWS = {n for n, p in _PLAT.items() if p == "windows"}


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
        if job in _HARNESS:
            keep = o[ci_scope.output_key("run", job)].split()
        else:
            drop = {d["scenario"] for d in json.loads(o[ci_scope.output_key("exclude", job)])
                    if "scenario" in d}
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
# A RECORDER RUNS ONE SCENARIO PER JOB, not every scenario: it runs after the assertion
# and decides what the run records, so one scenario per job proves it end to end. The
# expensive direction holds inside the rule: every job still runs something, and what it
# runs names agents, so --record meets real identifiers rather than a baseline's none.
_rec = scenarios(["tools/agent_status.py"])
check("a recorder runs a scenario in every job",
      all(set(names) & _rec for names in _JOBS.values()), str(sorted(_rec)))
check("and no more than one per job", len(_rec) <= len(_JOBS), str(sorted(_rec)))
check("and each one names agents, so --record has identifiers to write",
      all((_expected(n).get("classified") or {}).get("must_find") for n in _rec),
      str(sorted(_rec)))
check("tools/merge_observations.py and tools/observations.py scope the same way",
      scenarios(["tools/merge_observations.py"]) == _rec
      and scenarios(["tools/observations.py"]) == _rec)
# THE SCOPER RUNS NOTHING. No scenario calls it, this file proves it under lint, and a
# matrix spent on a change to it proves nothing about it.
check("tools/ci_scope.py runs nothing", scenarios(["tools/ci_scope.py"]) == set())
check("a recorder beside a catalog edit adds to it, never narrows it",
      scenarios(["tools/agent_status.py", ci_scope.CATALOG],
                head=_with_agent("claude-code", name="edited"))
      == _rec | _edit("claude-code"))
check("a catalog that does not parse runs every scenario",
      scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: "agents: ["}) == _LISTED)
check("a catalog with no base runs every scenario",
      scenarios([ci_scope.CATALOG], base={ci_scope.CATALOG: None}) == _LISTED)
check("a catalog edit outside `agents:` runs every scenario",
      scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: _replaced(
          _cat, "\nversion: 4\n", "\nversion: 5\n")}) == _LISTED)
_out, _ = ci_scope.scenarios_outputs(None, _reader())
check("and every scenario means every exclusion is empty, the direction that runs more",
      all(line.endswith("=[]") for line in _out if line.startswith("exclude_")), str(_out))

print()
print("a pull request runs one macOS label; everything else runs every label")
_os = [str(l) for l in _WF["jobs"]["scenario"]["strategy"]["matrix"]["os"] if "macos" in str(l)]
check("the macOS matrix lists at least two labels, or there is nothing to spare", len(_os) >= 2)


def _os_excluded(paths, event):
    out, report = ci_scope.scenarios_outputs(paths, _reader(), event=event)
    ex = json.loads(dict(l.split("=", 1) for l in out)[ci_scope.output_key("exclude", "scenario")])
    return [d["os"] for d in ex if "os" in d], report


_ex, _rep = _os_excluded(["test/scenarios/00-baseline/setup.sh"], "pull_request")
check("a pull request excludes every macOS label but the first", _ex == _os[1:], str(_ex))
check("and its summary says which label runs and where the rest run",
      any("one macOS label" in r and _os[0] in r for r in _rep), str(_rep))
check("a push keeps every label", _os_excluded(["test/scenarios/00-baseline/setup.sh"], "push")[0] == [])
check("so does a run with no event", _os_excluded(["test/scenarios/00-baseline/setup.sh"], None)[0] == [])
check("a pull request that runs no scenario spares no label: an empty matrix needs none",
      _os_excluded(["README.md"], "pull_request")[0] == [])
check("the scenario exclusions are unchanged beside the label",
      scenarios(["test/scenarios/00-baseline/setup.sh"]) == {"00-baseline"})

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
            {"description": _n, "platform": "darwin", "why": _n, "counts": {"app": ">=0"},
             "classified": {"must_find": [_agent]}}))
    (pathlib.Path(d) / ".github" / "workflows").mkdir(parents=True)
    (pathlib.Path(d) / ci_scope.SCENARIOS_WORKFLOW).write_text(_mini_wf)
    (pathlib.Path(d) / "catalog").mkdir()
    (pathlib.Path(d) / "catalog" / "routes.yaml").write_text(
        "platforms: [darwin]\nroutes:\n  npm: {platform: darwin, kind: npm}\n")
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
# A forbid names a lookalike the scenario holds, which a changed signature may now claim.
check("a scenario that only FORBIDS an agent runs when it changes",
      {"70-linux-baseline", "71-linux-cli-agents"} <= _edit("cursor"))
_controls = {n for n in _LISTED if _expected(n).get("control")}
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
    _darwin_seen |= scenarios_lib.must_find(_n, _expected, _catdoc["agents"])
    _darwin_seen |= set(_c.get("forbid", []))
    _darwin_seen |= {r["agent"] for r in _o.get("identifiers", []) + _o.get("archived", [])}
_unseen = sorted(a["id"] for a in _catdoc["agents"] if a["id"] not in _darwin_seen)
check("an edit to an agent no macOS scenario names or observed runs none of them but a control",
      bool(_unseen) and not (_edit(_unseen[0]) & DARWIN - _controls),
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
# must_find as tools/scenarios.py derives it. A new extension agent is named by no scenario
# and observed by none, so only the derivation from every_extension can select 45.
_ran_ext = _order(_A + [{"id": "zz-ext", "name": "Ext", "classification": "Browser agent",
                         "platforms": ["darwin"], "extension_ids": ["z" * 32]}])
check("a new extension agent runs the scenarios that find it through every_extension",
      "45-claude-extension" in _ran_ext, str(sorted(_ran_ext)))
_ctl = lambda plats: {n for n in _controls if _PLAT[n] in plats}  # noqa: E731


def _added(**agent):
    """The controls an agent appended to the catalog reruns. Appended, so nothing reorders."""
    return _controls & _order(_catdoc["agents"] + [dict(
        {"id": "zz-new", "name": "New", "classification": "Coding agent"}, **agent)])


# Where a ROUTE fires, not the `platforms` an agent declares: the classifier matches wherever
# the route can, and 75-linux-browser finds a macOS-and-Windows agent on Linux that way.
check("a control reruns on the platform of a route the changed agent has a value on",
      _ctl({"linux"}) and _added(platforms=["linux"], deb_packages=["zz"]) == _ctl({"linux"}),
      str(sorted(_added(platforms=["linux"], deb_packages=["zz"]))))
check("...on every platform for a route that fires on all of them",
      _added(platforms=["darwin"], npm=["zz"]) == _controls,
      str(sorted(_added(platforms=["darwin"], npm=["zz"]))))
check("...and on none for an agent with no route value, which can match nowhere",
      not _added(platforms=["darwin", "linux", "windows"]))
check("a catalog comment runs nothing",
      scenarios([ci_scope.CATALOG], head={ci_scope.CATALOG: _cat + "\n# a note\n"}) == set())
check("the rendered files add nothing beside a catalog edit",
      scenarios([ci_scope.CATALOG, "osquery/dist/signatures.sql", "osquery/dist/agents-darwin.sql"],
                head=_with_agent("pi", name="edited")) == _edit("pi"))
check("but without one, osquery/dist/signatures.sql runs every scenario",
      scenarios(["osquery/dist/signatures.sql"]) == _LISTED)
check("and osquery/dist/agents-linux.sql runs the Linux ones", scenarios(["osquery/dist/agents-linux.sql"]) == LINUX)
check("and osquery/dist/agents-windows.sql the Windows ones",
      bool(WINDOWS) and scenarios(["osquery/dist/agents-windows.sql"]) == WINDOWS)

print()
print("which scenarios -- by platform")
check("osquery/dist/discovery-darwin.sql runs exactly the macOS scenarios",
      scenarios(["osquery/dist/discovery-darwin.sql"]) == DARWIN)
check("osquery/dist/discovery-linux.sql runs exactly the Linux scenarios",
      scenarios(["osquery/dist/discovery-linux.sql"]) == LINUX)
check("osquery/dist/discovery-windows.sql runs exactly the Windows scenarios",
      scenarios(["osquery/dist/discovery-windows.sql"]) == WINDOWS)
DEEP = {n for n in _LISTED if _expected(n).get("deep")}
check("the deep artifact runs the deep scenarios, the only ones that run osquery/bin/discover",
      bool(DEEP) and scenarios(["osquery/dist/discovery-deep.sql"]) == DEEP, str(sorted(DEEP)))
check("so do the scanner and what it calls",
      scenarios(["osquery/bin/discover", "osquery/bin/container-scan"]) == DEEP)
check("so does the pack", scenarios(["osquery/dist/ai-detection-spec.conf"]) == DEEP)
# What a darwin query edit actually touches, so the platform rule is seen to save something.
_dq = scenarios(["osquery/queries/runtime.sql", "osquery/dist/discovery-darwin.sql", "osquery/dist/agents-darwin.sql",
                 "osquery/dist/ai-detection-spec.conf"])
check("a darwin query PR, with its generated files, runs no Linux scenario but the deep one",
      _dq == DARWIN | DEEP, str(sorted(_dq - DARWIN)))
# A scenario whose own facts cannot be read is run by every rule that consults them.
check("an unreadable expected.json is run by a rule for the other platform",
      "00-baseline" in scenarios(["osquery/dist/discovery-linux.sql"], head={
          "test/scenarios/00-baseline/expected.json": "{not json"}))
check("an unreadable setup.sh is run by a setup-library rule",
      "00-baseline" in scenarios(["test/lib/guest-linux.sh"], head={
          "test/scenarios/00-baseline/setup.sh": None}))
_q = {re.search(r"^-- platform:\s*(\w+)", p.read_text(), re.M).group(1): p
      for p in sorted((ROOT / "osquery" / "queries").glob("*.sql"))}
# A `posix` query is macOS and Linux, read through catalog/routes.yaml's groups: once Windows
# has scenarios it is not every scenario, and running Windows ones for it buys nothing.
for _p, _want in (("linux", LINUX), ("darwin", DARWIN), ("windows", WINDOWS),
                  ("posix", DARWIN | LINUX)):
    _path = str(_q[_p].relative_to(ROOT))
    check(f"a {_p} query ({_path}) runs the {_p} scenarios", scenarios([_path]) == _want,
          str(sorted(scenarios([_path]) ^ _want)))
_gl = scenarios(["test/lib/guest-linux.sh"])
check("guest-linux.sh runs Linux scenarios that source it, and no macOS one",
      bool(_gl) and _gl <= LINUX, str(sorted(_gl)))
_gm = scenarios(["test/lib/guest.sh"])
check("guest.sh runs macOS scenarios that source it, and no Linux one",
      bool(_gm) and _gm <= DARWIN, str(sorted(_gm)))
_gw = scenarios(["test/lib/guest-windows.ps1"])
check("guest-windows.ps1 runs Windows scenarios that source it, and no other",
      bool(_gw) and _gw <= WINDOWS, str(sorted(_gw)))
check("an unreadable setup.ps1 is run by a setup-library rule",
      "101-windows-cli-agents" in scenarios(["test/lib/guest-windows.ps1"], head={
          "test/scenarios/101-windows-cli-agents/setup.ps1": None}))

print()
print("the harness job, which lists no scenarios and runs its platform's whole tree")
check("scenarios.yml has a Linux harness job", "linux" in _HARNESS.values(), str(_HARNESS))
_tree = ci_scope.tree_scenarios("linux")
check("the Linux tree is exactly the Linux scenarios, 76 and 79 included",
      set(_tree) == LINUX and {"76-linux-systemd", "79-linux-image"} <= set(_tree),
      str(sorted(set(_tree) ^ LINUX)))
_hl = subprocess.run(["bash", str(ROOT / ci_scope.HARNESS["linux"]), "--list"],
                     capture_output=True, text=True)
check("test/run-linux.sh --list enumerates exactly what ci_scope hands the harness job",
      _hl.returncode == 0 and _hl.stdout.split() == _tree,
      f"rc {_hl.returncode}: {_hl.stdout.split()} vs {_tree}; {_hl.stderr.strip()[:200]}")
check("an edit to the Linux harness runs every Linux scenario and no macOS one",
      scenarios([ci_scope.HARNESS["linux"]]) == LINUX)
_ho, _ = ci_scope.scenarios_outputs(["test/scenarios/73-linux-deb/setup.sh"], _reader())
_hd = dict(line.split("=", 1) for line in _ho)
for _job, _plat in sorted(_HARNESS.items()):
    check(f"{_job} is handed the one scenario by name",
          _hd.get(ci_scope.output_key("run", _job)) == "73-linux-deb", str(_hd))
    check(f"{_job} gets no exclude list, which it could not read",
          ci_scope.output_key("exclude", _job) not in _hd)

print()
print("a dispatch that names scenarios runs exactly those")
_no, _nr = ci_scope.scenarios_outputs(None, _reader(), only=["73-linux-deb", "00-baseline"])
_nd = dict(line.split("=", 1) for line in _no)


def _named_ran(outputs):
    ran = set()
    for job, names in _JOBS.items():
        if job in _HARNESS:
            ran |= set(outputs[ci_scope.output_key("run", job)].split())
        else:
            drop = {d["scenario"] for d in json.loads(outputs[ci_scope.output_key("exclude", job)])}
            ran |= set(names) - drop
    return ran


check("the named scenarios run and nothing else",
      _named_ran(_nd) == {"73-linux-deb", "00-baseline"}, str(sorted(_named_ran(_nd))))
check("a job listing neither is skipped",
      all(_nd[ci_scope.output_key("skip", j)] == "true" for j, n in _JOBS.items()
          if not ({"73-linux-deb", "00-baseline"} & set(n))))
check("the report says the names were given", any("dispatched with names" in l for l in _nr))
try:
    ci_scope.scenarios_outputs(None, _reader(), only=["99-no-such-scenario"])
    check("a name no job lists is an error, not a run of nothing", False)
except SystemExit as _exc:
    check("a name no job lists is an error, not a run of nothing",
          "99-no-such-scenario" in str(_exc), str(_exc))

print()
print("which scenarios -- the cheap direction, where it is unambiguous")
check("a scenario's own file runs that scenario alone",
      scenarios(["test/scenarios/00-baseline/setup.sh"]) == {"00-baseline"})
check("a scenario no job lists runs nothing", scenarios(["test/scenarios/90-demo-fleet/setup.sh"])
      == set())
check("docs only runs nothing", scenarios(["README.md", "docs/agents.md"]) == set())
check("another workflow runs nothing", scenarios([".github/workflows/docs.yml"]) == set())
check("osquery/dist/fleet-policies.yml runs nothing: no scenario reads it",
      scenarios(["osquery/dist/fleet-policies.yml"]) == set())
check("an INERT check runs nothing", scenarios(["test/lint.sh", "tools/validate_catalog.py"])
      == set())
check("the conformance vectors run nothing: lint holds bin/classify to them",
      scenarios(["conformance/vectors.json"]) == set())
check("docs/blind-spots.yaml runs nothing", scenarios(["docs/blind-spots.yaml"]) == set())

_wft = (ROOT / ci_scope.SCENARIOS_WORKFLOW).read_text()
_W = ci_scope.SCENARIOS_WORKFLOW
check("a comment in scenarios.yml runs nothing",
      scenarios([_W], base={_W: _replaced(_wft, "\non:\n", "\n# a note\non:\n")}) == set())
check("a scenario added to a matrix runs that scenario alone",
      scenarios([_W], base={_W: _replaced(_wft, "          - 57-clawdbot-era\n", "")})
      == {"57-clawdbot-era"})
# JOB BY JOB. The Provision bound is the macOS job's, so its scenarios run and no other's.
check("an edit to a scenario job runs that job's scenarios",
      scenarios([_W], base={_W: _replaced(_wft, "timeout-minutes: 50", "timeout-minutes: 49")})
      == DARWIN)
# collect needs every scenario job and runs none: it consumes their uploads, so one
# scenario per job proves a change to it, the same set a recorder runs.
check("an edit to collect runs one scenario per job",
      scenarios([_W], base={_W: _replaced(_wft, "timeout-minutes: 15", "timeout-minutes: 14")})
      == _rec)
check("an edit to the scope job runs every scenario",
      scenarios([_W], base={_W: _replaced(_wft, "timeout-minutes: 10", "timeout-minutes: 9")})
      == _LISTED)
check("an edit outside the jobs runs every scenario",
      scenarios([_W], base={_W: _replaced(_wft, "OSQUERY_VERSION: 5.23.1", "OSQUERY_VERSION: 5.23.0")})
      == _LISTED)
check("a job added runs every scenario",
      scenarios([_W], head={_W: _wft + "  extra:\n    runs-on: ubuntu-latest\n    steps: []\n"})
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
def reachable(through_scenarios=True, seed=None,
              roots=("osquery", "test", "tools", "bin", "catalog", "schema")):
    """Every tracked file a scenarios.yml job can reach: what its steps name, then whatever
    a reached SCRIPT names -- an import, a string constant, a non-comment line. Data files
    are read rather than followed. Generous on purpose: a false reach only keeps a file
    out of INERT, which costs minutes, never a skipped scenario. `seed` is a (path, text)
    to start from instead of the workflow's steps; `roots` the top-level directories whose
    files are candidates."""
    files = [p for p in _git(str(ROOT), "ls-files").split()
             if p.split("/")[0] in roots
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
        # `(ROOT / "tools").glob("check_*.py")` names no file and runs several. Not one
        # escaped by a backslash: a regex's `\s*` is no glob of every file named s-anything.
        globs = {w.rsplit("/", 1)[-1] for w in re.findall(r"(?<![\\\w.*/-])[\w.*/-]*\*[\w.*-]*", blob)}
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

    if seed is None:
        seed = ("scenarios.yml", "\n".join(str(s.get("run", "")) for j in _WF["jobs"].values()
                                          for s in j.get("steps", [])))
    seen = hits(*seed)
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
for _f in ("bin/classify", "tools/agent_status.py", "osquery/test/test_match_sql.py",
           "osquery/tools/build.py", "test/lib/guest-linux.sh"):
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
# A RECORDER IS NOT ON THE ASSERTION PATH. The same analysis, seeded from the two assert
# scripts instead of the workflow, must not reach one: if it did, a change there could
# change whether a scenario passes, and one scenario per job would be too few. NOT THROUGH
# SCENARIO SETUP SCRIPTS: those run in Provision, before the assertion, and nothing in the
# assertion can run one -- while the generous analysis reaches one from a glob in
# osquery/tools/render_match.py and, from there, the Linux harness and its recorder.
_assert_reach = reachable(through_scenarios=False, seed=("test/assert.sh", "\n".join(
    (ROOT / p).read_text() for p in ("test/assert.sh", "test/lib/assert.sh"))))
check("the assertion path reaches bin/classify", "bin/classify" in _assert_reach)
check("every RECORDER path is a tracked file", set(ci_scope.RECORDERS) <= _tracked,
      str(sorted(set(ci_scope.RECORDERS) - _tracked)))
check("the scenario jobs reach every RECORDER", set(ci_scope.RECORDERS) <= _reach,
      f"not reached, so not a recorder: {sorted(set(ci_scope.RECORDERS) - _reach)}")
check("no RECORDER is on the assertion path", not (set(ci_scope.RECORDERS) & _assert_reach),
      f"remove from RECORDERS: {sorted(set(ci_scope.RECORDERS) & _assert_reach)}")

print()
print("RUNTIME_INERT, against what ci.yml's runtime jobs can actually reach")
# THE SAME ANALYSIS, seeded from the runtime jobs: the ones ci.yml gates on the scope
# verdict, found by that `if` rather than by name. Wider roots, so the proof can speak
# about docs/, .github/ and the spec's own files. NOT THROUGH SCENARIO FILES as
# candidates: osquery/test/test_match_sql.py globs `*.json` under test/fixtures/, and the
# generous analysis cannot see the directory, so every expected.json would read as
# reached. Instead, nothing a runtime job runs may name the scenario tree at all.
import yaml  # noqa: E402
_CI = yaml.safe_load((ROOT / ci_scope.CI_WORKFLOW).read_text())
_RUNTIME_JOBS = {n: j for n, j in _CI["jobs"].items()
                 if "outputs.runtime" in str(j.get("if", ""))}
check("ci.yml gates at least three jobs on the scope verdict", len(_RUNTIME_JOBS) >= 3,
      str(sorted(_RUNTIME_JOBS)))
_ci_seed = ("ci.yml", "\n".join(str(s.get("run", "")) for j in _RUNTIME_JOBS.values()
                                 for s in j.get("steps", [])))
_ci_reach = reachable(through_scenarios=False, seed=_ci_seed,
                      roots=("osquery", "test", "tools", "bin", "catalog", "docs",
                             "conformance", "schema"))
for _f in ("bin/classify", "osquery/bin/discover", "osquery/tools/measure.py",
           "osquery/test/test_match_sql.py", "test/fixtures/known-agents.json",
           "catalog/routes.yaml"):
    check(f"the runtime jobs reach {_f}", _f in _ci_reach)
check("every RUNTIME_INERT path is a tracked file", ci_scope.RUNTIME_INERT <= _tracked,
      str(sorted(ci_scope.RUNTIME_INERT - _tracked)))
check("no runtime job can reach a RUNTIME_INERT path", not (ci_scope.RUNTIME_INERT & _ci_reach),
      f"remove from RUNTIME_INERT: {sorted(ci_scope.RUNTIME_INERT & _ci_reach)}")
def _script_text(f):
    """A reached SCRIPT's text, less comments: the thing that could open a file. A data
    file or a doc the analysis reached is read rather than run, so it is not scanned."""
    if f == _ci_seed[0]:
        return _ci_seed[1]
    text = (ROOT / f).read_text(errors="replace")
    if not (f.endswith((".py", ".sh", ".ps1")) or text.startswith("#!")):
        return ""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


_names_tree = [f for f in [_ci_seed[0]] + sorted(_ci_reach)
               if re.search(r"(^|[\s\"'/(])scenarios(/|[\"'\s)]|$)", _script_text(f))]
check("no script a runtime job runs names the scenario tree", not _names_tree, str(_names_tree))
# THE OTHER WORKFLOWS ARE EXCUSED THE SAME WAY: a script opens one only by naming its
# directory. Not by reach, which a `s*` the analysis lifts out of a format string in
# osquery/tools/measure.py would match to scenarios.yml.
_names_wf = [f for f in [_ci_seed[0]] + sorted(_ci_reach)
             if re.search(r"\.github\b|workflows/", _script_text(f))]
check("no script a runtime job runs names the workflows directory", not _names_wf, str(_names_wf))

print()
print("the command line, as the workflow actually calls it")
out = subprocess.run([sys.executable, str(ROOT / "tools" / "ci_scope.py"),
                      "--paths", "README.md"], capture_output=True, text=True)
check("stdout is GITHUB_OUTPUT form and nothing else",
      out.stdout == "runtime=false\n", repr(out.stdout))
check("the reason goes to stderr, where a log shows it", "lint still runs" in out.stderr,
      repr(out.stderr))
check("it exits 0 either way", out.returncode == 0, str(out.returncode))
# From the repository root, as the workflow runs it: --paths reads the working tree.
out = subprocess.run([sys.executable, "tools/ci_scope.py", "--scenarios", "--paths",
                      "test/scenarios/00-baseline/setup.sh"],
                     capture_output=True, text=True, cwd=ROOT)
_lines = out.stdout.splitlines()
check("--scenarios writes only GITHUB_OUTPUT lines",
      out.returncode == 0 and _lines[0] == "runtime=true"
      and all(re.fullmatch(r"(skip|exclude|run)_\w+=.*", l) for l in _lines[1:]), out.stdout)
check("one skip and one exclude or run list per scenario job", len(_lines) == 1 + 2 * len(_JOBS),
      str(len(_lines)))

print()
if failures:
    print(f"ci_scope: FAIL ({len(failures)})")
    sys.exit(1)
print("ci_scope: PASS")
