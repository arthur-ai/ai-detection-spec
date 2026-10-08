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
def _git(d, *a):
    return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True,
                          check=True).stdout.strip()


def _commit(d, path, msg):
    (pathlib.Path(d) / path).write_text(msg)
    _git(d, "add", path)
    _git(d, "commit", "-qm", msg)
    return _git(d, "rev-parse", "HEAD")


with tempfile.TemporaryDirectory() as d:
    _git(d, "init", "-q", "-b", "main")
    _git(d, "config", "user.email", "t@example.com")
    _git(d, "config", "user.name", "t")
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
    here = os.getcwd()
    os.chdir(d)
    try:
        stale = ci_scope.changed(cut, merge)
        fixed = ci_scope.changed(f"{merge}^1", merge)
        fixed_code = ci_scope.changed(f"{merge2}^1", merge2)
    finally:
        os.chdir(here)
check("the branch point counts main's own commits as the PR's (the bug)",
      "observed.json" in (stale or []), f"got {stale}")
check("the merge's first parent sees only the PR's change", fixed == ["notes.md"],
      f"got {fixed}")
check("so a docs-only PR stays docs-only", not runs(fixed))
check("and a PR that touches code still runs", runs(fixed_code), f"got {fixed_code}")

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

print()
print("the command line, as the workflow actually calls it")
out = subprocess.run([sys.executable, str(ROOT / "tools" / "ci_scope.py"),
                      "--paths", "README.md"], capture_output=True, text=True)
check("stdout is GITHUB_OUTPUT form and nothing else",
      out.stdout == "runtime=false\n", repr(out.stdout))
check("the reason goes to stderr, where a log shows it", "documentation" in out.stderr,
      repr(out.stderr))
check("it exits 0 either way", out.returncode == 0, str(out.returncode))

print()
if failures:
    print(f"ci_scope: FAIL ({len(failures)})")
    sys.exit(1)
print("ci_scope: PASS")
